//
//  MLModelDownloadService.swift
//  roboscope2
//
//  Downloads and activates a CoreML model from a remote ZIP URL (Space.ml_model_url).
//  Once installed the model path is persisted in AppSettings so LaserMLDetectionService
//  picks it up automatically on the next `ensureRequest()` call.
//

import Foundation
import Combine
import CoreML
import ZIPFoundation

// MARK: - Download state

enum MLModelDownloadState: Equatable {
    /// No remote model configured / nothing started yet.
    case idle
    /// Actively downloading; `progress` is 0–1 (indeterminate when -1).
    case downloading(progress: Double)
    /// Unzipping + compiling.
    case installing
    /// A remote model is installed and active.
    case ready(displayName: String, sourceURL: String)
    /// Terminal error.
    case error(String)

    var isInProgress: Bool {
        switch self {
        case .downloading, .installing: return true
        default: return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let msg) = self { return msg }
        return nil
    }
}

// MARK: - Service

/// Singleton responsible for downloading, installing, and lifecycle management of a
/// remotely-served CoreML model ZIP. Integrates with `AppSettings` so that
/// `LaserMLDetectionService` picks up the new model path automatically.
@MainActor
final class MLModelDownloadService: ObservableObject {

    static let shared = MLModelDownloadService()

    // MARK: Published state

    @Published private(set) var downloadState: MLModelDownloadState = .idle

    // MARK: Private

    private var currentDownloadTask: Task<Void, Never>?

    private init() {
        // Restore state from persisted settings on cold launch.
        // Use laserGuideMLModelURL (not the raw path) so stale container UUIDs are recovered.
        let settings = AppSettings.shared
        if let sourceURL = settings.laserGuideMLModelSourceURL,
           settings.laserGuideMLModelURL != nil {
            downloadState = .ready(
                displayName: settings.laserGuideMLModelDisplayName ?? "Remote Model",
                sourceURL: sourceURL
            )
        }
    }

    // MARK: - Public API

    /// Called whenever a Space is opened (e.g. SpaceARView.onAppear).
    /// Downloads and activates the model if `space.mlModelUrl` is non-nil and
    /// differs from what is already installed.
    func syncModelForSpace(_ space: Space) {
        guard let urlString = space.mlModelUrl, !urlString.isEmpty else { return }

        let settings = AppSettings.shared

        // Already have this exact version installed.
        if settings.laserGuideMLModelSourceURL == urlString,
           settings.laserGuideMLModelURL != nil {
            downloadState = .ready(
                displayName: settings.laserGuideMLModelDisplayName ?? "Remote Model",
                sourceURL: urlString
            )
            return
        }

        let displayName = "\(space.name) Model"
        startDownload(from: urlString, displayName: displayName)
    }

    /// Manually trigger a download from an arbitrary URL (e.g. from the Settings UI).
    func downloadAndInstall(from urlString: String, displayName: String = "Remote Model") {
        startDownload(from: urlString, displayName: displayName)
    }

    /// Re-download the model from the currently stored source URL, for forced refresh.
    func redownload() {
        guard let urlString = AppSettings.shared.laserGuideMLModelSourceURL else { return }
        let name = AppSettings.shared.laserGuideMLModelDisplayName ?? "Remote Model"
        startDownload(from: urlString, displayName: name)
    }

    /// Discard the downloaded model and revert to the bundled `laser-pens` model.
    func resetToBundled() {
        currentDownloadTask?.cancel()
        currentDownloadTask = nil

        // Remove the compiled model file from disk.
        let settings = AppSettings.shared
        if let path = settings.laserGuideMLModelLocalPath {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
        }

        settings.laserGuideMLModelLocalPath = nil
        settings.laserGuideMLModelDisplayName = nil
        settings.laserGuideMLModelSourceURL = nil

        downloadState = .idle
    }

    // MARK: - Private helpers

    private func startDownload(from urlString: String, displayName: String) {
        guard !downloadState.isInProgress else { return }

        guard let url = URL(string: urlString) else {
            downloadState = .error("Invalid model URL: \(urlString)")
            return
        }

        currentDownloadTask?.cancel()
        downloadState = .downloading(progress: -1) // indeterminate

        currentDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                // ── 1. Download to temp file ────────────────────────────────
                let (tempFileURL, _) = try await URLSession.shared.download(from: url)

                guard !Task.isCancelled else { return }

                // Rename to .zip so our install helper can unzip it reliably.
                let zipURL = tempFileURL.deletingLastPathComponent()
                    .appendingPathComponent(tempFileURL.lastPathComponent + ".zip")
                try? FileManager.default.moveItem(at: tempFileURL, to: zipURL)
                let resolvedZipURL = FileManager.default.fileExists(atPath: zipURL.path) ? zipURL : tempFileURL

                // ── 2. Install (background thread) ────────────────────────────
                await MainActor.run { self.downloadState = .installing }

                let (compiledURL, modelName) = try await Task.detached(priority: .userInitiated) {
                    try MLModelDownloadService.install(zipURL: resolvedZipURL, candidateName: displayName)
                }.value

                guard !Task.isCancelled else { return }

                // ── 3. Persist to AppSettings ─────────────────────────────────
                let settings = AppSettings.shared
                settings.laserGuideMLModelLocalPath = compiledURL.path
                settings.laserGuideMLModelDisplayName = modelName
                settings.laserGuideMLModelSourceURL = urlString

                self.downloadState = .ready(displayName: modelName, sourceURL: urlString)
            } catch is CancellationError {
                self.downloadState = .idle
            } catch {
                self.downloadState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Static install helpers

    /// Unzips the archive at `zipURL`, finds the first CoreML artefact, compiles if
    /// necessary, and copies the result to the app's Application Support directory.
    private nonisolated static func install(zipURL: URL, candidateName: String) throws -> (URL, String) {
        let fm = FileManager.default

        // ── Prepare destination directory ────────────────────────────────────
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsDir = appSupport
            .appendingPathComponent("MLModels/LaserGuide", isDirectory: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let dest = modelsDir.appendingPathComponent("laser_guide_remote.mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        // ── Unzip ────────────────────────────────────────────────────────────
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ml_model_unzip_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        defer { try? fm.removeItem(at: zipURL) }

        do {
            try fm.unzipItem(at: zipURL, to: tempRoot)
        } catch {
            throw NSError(
                domain: "MLModelDownloadService",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to unzip model archive: \(error.localizedDescription)"]
            )
        }

        // ── Find and install CoreML artefact ─────────────────────────────────
        if let modelc = findFirst(in: tempRoot, extension: "mlmodelc") {
            let name = modelc.deletingPathExtension().lastPathComponent
            try fm.copyItem(at: modelc, to: dest)
            return (dest, name)
        }

        if let mlpackage = findFirst(in: tempRoot, extension: "mlpackage") {
            let name = mlpackage.deletingPathExtension().lastPathComponent
            let compiled = try MLModel.compileModel(at: mlpackage)
            try fm.copyItem(at: compiled, to: dest)
            try? fm.removeItem(at: compiled)
            return (dest, name)
        }

        if let mlmodel = findFirst(in: tempRoot, extension: "mlmodel") {
            let name = mlmodel.deletingPathExtension().lastPathComponent
            let compiled = try MLModel.compileModel(at: mlmodel)
            try fm.copyItem(at: compiled, to: dest)
            try? fm.removeItem(at: compiled)
            return (dest, name)
        }

        throw NSError(
            domain: "MLModelDownloadService",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "The ZIP archive does not contain a CoreML model (.mlmodelc, .mlpackage, or .mlmodel)."]
        )
    }

    private nonisolated static func findFirst(in folder: URL, extension ext: String) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            // Skip macOS resource-fork metadata directories (__MACOSX)
            guard !url.pathComponents.contains("__MACOSX") else { continue }
            if url.pathExtension.lowercased() == ext.lowercased() { return url }
        }
        return nil
    }
}
