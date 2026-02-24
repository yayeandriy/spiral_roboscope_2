//
//  MLModelDownloadService.swift
//  roboscope2
//
//  Manages per-space CoreML model downloads.
//  No global "current model" — each Space has its own downloaded model entry
//  stored in SpaceMLModelStore.  Models are never deleted automatically so
//  history is preserved; a new download simply overwrites the compiled artefact
//  for that space.
//

import Foundation
import Combine
import CoreML
import ZIPFoundation

// MARK: - Download state

enum MLModelDownloadState: Equatable {
    /// No download activity for this space.
    case idle
    /// Downloading the model ZIP; `progress` is 0–1 (or -1 when indeterminate).
    case downloading(progress: Double)
    /// Unzipping and compiling the model.
    case installing
    /// A model is stored and ready.
    case ready(modelName: String, downloadedAt: Date)
    /// Terminal error.
    case error(String)

    var isInProgress: Bool {
        switch self { case .downloading, .installing: return true; default: return false }
    }

    var errorMessage: String? {
        if case .error(let m) = self { return m }; return nil
    }
}

// MARK: - Service

/// Singleton that downloads, installs, and caches CoreML models on a per-space basis.
/// Call `ensureModelForSpace(_:)` at session start to get a ready-to-use model URL.
@MainActor
final class MLModelDownloadService: ObservableObject {

    static let shared = MLModelDownloadService()

    // MARK: Published

    /// Per-space download states keyed by spaceId. Observe to drive loading UI.
    @Published private(set) var downloadStates: [String: MLModelDownloadState] = [:]

    // MARK: Private

    private let store = SpaceMLModelStore.shared
    /// Active download tasks keyed by spaceId — joining avoids duplicate downloads.
    private var activeTasks: [String: Task<URL, Error>] = [:]

    private init() {}

    // MARK: - Public API

    /// Returns the current download state for a space (idle when unknown).
    func state(for spaceId: String) -> MLModelDownloadState {
        downloadStates[spaceId] ?? .idle
    }

    /// Ensures the correct ML model for `space` is downloaded and compiled.
    ///
    /// Behaviour:
    ///  - Throws if `space.mlModelUrl` is nil/empty.
    ///  - Returns immediately if a stored model for this space matches the current URL.
    ///  - Downloads, installs, and persists otherwise.
    ///  - If a download is already in flight for this space, awaits it instead of re-starting.
    func ensureModelForSpace(_ space: Space) async throws -> URL {
        let spaceIdStr = space.id.uuidString
        guard let urlString = space.mlModelUrl, !urlString.isEmpty else {
            let msg = "Space \"\(space.name)\" has no ML model configured."
            downloadStates[spaceIdStr] = .error(msg)
            throw NSError(domain: "MLModelDownloadService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }

        // Already have a valid local copy — check both URL match and freshness.
        if let entry = store.find(spaceId: spaceIdStr),
           entry.sourceURL == urlString,
           let url = store.modelURL(for: spaceIdStr) {
            // Re-download if the Space was updated after we last downloaded the model.
            let needsRefresh = space.updatedAt.map { $0 > entry.downloadedAt } ?? false
            if !needsRefresh {
                downloadStates[spaceIdStr] = .ready(modelName: entry.modelName, downloadedAt: entry.downloadedAt)
                return url
            }
        }

        // Join an in-flight task for the same space to avoid duplicate downloads.
        if let existing = activeTasks[spaceIdStr] {
            return try await existing.value
        }

        // Kick off a new download task.
        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performDownload(space: space, urlString: urlString)
        }
        activeTasks[spaceIdStr] = task
        defer { activeTasks.removeValue(forKey: spaceIdStr) }

        return try await task.value
    }

    // MARK: - Private helpers

    private func performDownload(space: Space, urlString: String) async throws -> URL {
        let spaceIdStr = space.id.uuidString
        guard let url = URL(string: urlString) else {
            let msg = "Invalid model URL: \(urlString)"
            downloadStates[spaceIdStr] = .error(msg)
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        downloadStates[spaceIdStr] = .downloading(progress: -1)

        // ── 1. Download ZIP ─────────────────────────────────────────────────
        let (tempFileURL, _) = try await URLSession.shared.download(from: url)

        guard !Task.isCancelled else { throw CancellationError() }

        // Ensure temp file has a .zip extension for ZIPFoundation.
        let zipURL = tempFileURL.deletingLastPathComponent()
            .appendingPathComponent(tempFileURL.lastPathComponent + ".zip")
        try? FileManager.default.moveItem(at: tempFileURL, to: zipURL)
        let resolvedZipURL = FileManager.default.fileExists(atPath: zipURL.path) ? zipURL : tempFileURL

        // ── 2. Install on a background thread ────────────────────────────────
        downloadStates[spaceIdStr] = .installing

        let (compiledURL, modelName) = try await Task.detached(priority: .userInitiated) {
            try MLModelDownloadService.install(zipURL: resolvedZipURL, spaceId: spaceIdStr)
        }.value

        guard !Task.isCancelled else { throw CancellationError() }

        // ── 3. Persist ───────────────────────────────────────────────────────
        let now = Date()
        let entry = SpaceMLModelEntry(
            spaceId: spaceIdStr,
            sourceURL: urlString,
            localPath: compiledURL.path,
            modelName: modelName,
            downloadedAt: now
        )
        store.save(entry)
        downloadStates[spaceIdStr] = .ready(modelName: modelName, downloadedAt: now)

        return compiledURL
    }

    // MARK: - Static install (background-safe)

    /// Unzips the archive, finds the first CoreML artefact, compiles if necessary,
    /// and copies the result to `Application Support/MLModels/<spaceId>/laser_guide.mlmodelc`.
    private nonisolated static func install(zipURL: URL, spaceId: String) throws -> (URL, String) {
        let fm = FileManager.default

        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsDir = appSupport
            .appendingPathComponent("MLModels/\(spaceId)", isDirectory: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let dest = modelsDir.appendingPathComponent("laser_guide.mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ml_unzip_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        defer { try? fm.removeItem(at: zipURL) }

        do {
            try fm.unzipItem(at: zipURL, to: tempRoot)
        } catch {
            throw NSError(
                domain: "MLModelDownloadService", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unzip failed: \(error.localizedDescription)"]
            )
        }

        if let modelc = findFirst(in: tempRoot, extension: "mlmodelc") {
            let name = modelc.deletingPathExtension().lastPathComponent
            try fm.copyItem(at: modelc, to: dest)
            return (dest, name)
        }
        if let pkg = findFirst(in: tempRoot, extension: "mlpackage") {
            let name = pkg.deletingPathExtension().lastPathComponent
            let compiled = try MLModel.compileModel(at: pkg)
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
            domain: "MLModelDownloadService", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Archive contains no CoreML model (.mlmodelc / .mlpackage / .mlmodel)."]
        )
    }

    private nonisolated static func findFirst(in folder: URL, extension ext: String) -> URL? {
        guard let e = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in e {
            guard !url.pathComponents.contains("__MACOSX") else { continue }
            if url.pathExtension.lowercased() == ext.lowercased() { return url }
        }
        return nil
    }
}
