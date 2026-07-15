//
//  RepairModelStore.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied from Services/Detection/SpaceMLModelStore.swift (READ-ONLY reference) per
//  05-ios-repair.md §5.2 / §5.10, but RE-KEYED from `spaceId` to `file_hash`
//  (00-rules-and-boundaries.md §0.7.4): Roboscope caches one model per Space; Repair caches
//  a global registry keyed by the model zip's sha256 hash, so switching CoremlModel selection
//  reuses an already-downloaded model instantly if its hash was seen before.
//

import Foundation

// MARK: - Model

struct RepairModelEntry: Codable {
    /// sha256 hex of the model zip (CoremlModel.file_hash) — the cache key.
    let fileHash: String
    /// Original storage_url the model was downloaded from (for diagnostics only; not used
    /// for cache invalidation — file_hash is authoritative).
    let sourceURL: String
    /// Absolute path to the compiled .mlmodelc directory on disk.
    var localPath: String
    /// Human-readable model name (filename without extension).
    let modelName: String
    /// When the model was last downloaded/installed.
    let downloadedAt: Date
}

// MARK: - Store

/// Thread-safe (main-thread) persistent store for the global, file_hash-keyed Repair model cache.
final class RepairModelStore {

    static let shared = RepairModelStore()

    private let userDefaultsKey = "repairModelEntries"
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Read

    func find(fileHash: String) -> RepairModelEntry? {
        all().first { $0.fileHash == fileHash }
    }

    /// Returns a valid on-disk URL for the given file_hash.
    /// Handles stale absolute paths caused by app container UUID changes after re-installs.
    func modelURL(for fileHash: String) -> URL? {
        guard var entry = find(fileHash: fileHash) else { return nil }

        let url = URL(fileURLWithPath: entry.localPath)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        // App container UUID changed — recover by re-rooting the MLModels/repair/ suffix
        // under the current Application Support directory.
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let components = url.pathComponents
        guard let idx = components.firstIndex(of: "MLModels") else { return nil }
        let recovered = components[idx...].reduce(appSupport) { $0.appendingPathComponent($1) }
        guard FileManager.default.fileExists(atPath: recovered.path) else { return nil }

        entry.localPath = recovered.path
        save(entry)
        return recovered
    }

    // MARK: - Write

    func save(_ entry: RepairModelEntry) {
        var existing = all().filter { $0.fileHash != entry.fileHash }
        existing.append(entry)
        persist(existing)
    }

    func remove(fileHash: String) {
        persist(all().filter { $0.fileHash != fileHash })
    }

    // MARK: - Private

    private func all() -> [RepairModelEntry] {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([RepairModelEntry].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist(_ entries: [RepairModelEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }
}
