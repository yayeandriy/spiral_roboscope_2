//
//  RepairModelDownloadService.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied from Services/Detection/MLModelDownloadService.swift (READ-ONLY reference) per
//  05-ios-repair.md §5.2 / §5.10. Key differences from the Roboscope original (00 §0.7.4/§0.7.7):
//   - Cache key is `file_hash` (global registry), NOT `spaceId` (per-space).
//   - `storage_url` is assumed PUBLICLY GET-able — no SpiralStorageService presigned-URL
//     resolution, no storage credentials on the phone at all. Downloads the zip directly.
//
//  IMPORTANT (05 §5.10 — device-time verification, not an iOS bug if it fails):
//  model zips are uploaded via a multipart flow, and spiral-storage may not set a public-read
//  ACL on multipart-completed objects. If `storage_url` 403s here, the fix is storage/web-side
//  (make Veranda model objects public); this service surfaces a clear error rather than
//  guessing at a workaround.
//

import Foundation
import Combine
import CoreML
import ZIPFoundation

// MARK: - Download state

enum RepairModelDownloadState: Equatable {
    case idle
    /// Downloading the model ZIP; `progress` is 0–1 (or -1 when indeterminate).
    case downloading(progress: Double)
    case installing
    case ready(modelName: String, downloadedAt: Date)
    case error(String)

    var isInProgress: Bool {
        switch self { case .downloading, .installing: return true; default: return false }
    }

    var errorMessage: String? {
        if case .error(let m) = self { return m }; return nil
    }
}

// MARK: - Service

/// Singleton that downloads, installs, and caches CoreML models for Repair, keyed globally
/// by `file_hash`. Call `ensureModel(for:)` once a session's CoremlModel is resolved (RepairView).
@MainActor
final class RepairModelDownloadService: ObservableObject {

    static let shared = RepairModelDownloadService()

    // MARK: Published

    /// Per-file_hash download states. Observe to drive loading UI.
    @Published private(set) var downloadStates: [String: RepairModelDownloadState] = [:]

    // MARK: Private

    private let store = RepairModelStore.shared
    /// Active download tasks keyed by file_hash — joining avoids duplicate downloads.
    private var activeTasks: [String: Task<URL, Error>] = [:]

    private init() {}

    // MARK: - Public API

    func state(for fileHash: String) -> RepairModelDownloadState {
        downloadStates[fileHash] ?? .idle
    }

    /// Ensures the compiled model for `model` is downloaded and ready, returning its
    /// compiled .mlmodelc URL. Reuses the on-disk artifact if the file_hash is already cached.
    func ensureModel(for model: CoremlModel) async throws -> URL {
        let fileHash = model.fileHash

        // Already have a valid local copy for this hash — reuse it, no re-download.
        if let entry = store.find(fileHash: fileHash), let url = store.modelURL(for: fileHash) {
            downloadStates[fileHash] = .ready(modelName: entry.modelName, downloadedAt: entry.downloadedAt)
            return url
        }

        // Join an in-flight task for the same hash to avoid duplicate downloads.
        if let existing = activeTasks[fileHash] {
            return try await existing.value
        }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performDownload(model: model)
        }
        activeTasks[fileHash] = task
        defer { activeTasks.removeValue(forKey: fileHash) }

        return try await task.value
    }

    // MARK: - Private helpers

    private func performDownload(model: CoremlModel) async throws -> URL {
        let fileHash = model.fileHash
        guard let sourceURL = URL(string: model.storageUrl) else {
            let msg = "Invalid model storage_url: \(model.storageUrl)"
            downloadStates[fileHash] = .error(msg)
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        downloadStates[fileHash] = .downloading(progress: -1)

        // Direct public download — no storage credentials, no presigned-URL resolution
        // (Repair models must be publicly GET-able; see the file-header note above and
        // 05-ios-repair.md §5.10).
        let tempFileURL: URL
        let response: URLResponse
        do {
            (tempFileURL, response) = try await URLSession.shared.download(from: sourceURL)
        } catch {
            let msg = "Download failed: \(error.localizedDescription)"
            downloadStates[fileHash] = .error(msg)
            throw error
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg: String
            if http.statusCode == 403 {
                msg = "Model storage returned 403 Forbidden. This is a storage/ACL issue " +
                      "(see 05-ios-repair.md §5.10), not an iOS bug — the model object needs " +
                      "to be publicly GET-able."
            } else {
                msg = "Model download failed with HTTP \(http.statusCode)."
            }
            downloadStates[fileHash] = .error(msg)
            throw NSError(domain: "RepairModelDownloadService", code: http.statusCode,
                           userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard !Task.isCancelled else { throw CancellationError() }

        // Ensure temp file has a .zip extension for ZIPFoundation.
        let zipURL = tempFileURL.deletingLastPathComponent()
            .appendingPathComponent(tempFileURL.lastPathComponent + ".zip")
        try? FileManager.default.moveItem(at: tempFileURL, to: zipURL)
        let resolvedZipURL = FileManager.default.fileExists(atPath: zipURL.path) ? zipURL : tempFileURL

        // Install on a background thread.
        downloadStates[fileHash] = .installing

        let (compiledURL, modelName) = try await Task.detached(priority: .userInitiated) {
            try RepairModelDownloadService.install(zipURL: resolvedZipURL, fileHash: fileHash)
        }.value

        guard !Task.isCancelled else { throw CancellationError() }

        let now = Date()
        let entry = RepairModelEntry(
            fileHash: fileHash,
            sourceURL: model.storageUrl,
            localPath: compiledURL.path,
            modelName: modelName,
            downloadedAt: now
        )
        store.save(entry)
        downloadStates[fileHash] = .ready(modelName: modelName, downloadedAt: now)

        return compiledURL
    }

    // MARK: - Static install (background-safe)

    /// Unzips the archive, finds the first CoreML artefact, compiles if necessary,
    /// and copies the result to `Application Support/MLModels/repair/<file_hash>/model.mlmodelc`.
    private nonisolated static func install(zipURL: URL, fileHash: String) throws -> (URL, String) {
        let fm = FileManager.default

        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelsDir = appSupport
            .appendingPathComponent("MLModels/repair/\(fileHash)", isDirectory: true)
        try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let dest = modelsDir.appendingPathComponent("model.mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("repair_ml_unzip_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        defer { try? fm.removeItem(at: zipURL) }

        do {
            try fm.unzipItem(at: zipURL, to: tempRoot)
        } catch {
            throw NSError(
                domain: "RepairModelDownloadService", code: 10,
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
            domain: "RepairModelDownloadService", code: 11,
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
