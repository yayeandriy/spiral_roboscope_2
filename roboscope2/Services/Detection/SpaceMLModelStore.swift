//
//  SpaceMLModelStore.swift
//  roboscope2
//
//  Persists one downloaded CoreML model per Space in UserDefaults.
//  Each entry records the original remote URL (used to detect stale models),
//  the local compiled path, a display name, and the download timestamp.
//

import Foundation

// MARK: - Model

struct SpaceMLModelEntry: Codable {
    let spaceId: String
    /// Original remote URL the model was downloaded from (Space.ml_model_url).
    let sourceURL: String
    /// Absolute path to the compiled .mlmodelc directory on disk.
    var localPath: String
    /// Human-readable model name (filename without extension).
    let modelName: String
    /// When the model was last downloaded/updated.
    let downloadedAt: Date
}

// MARK: - Store

/// Thread-safe (main-thread) persistent store for per-space ML model entries.
final class SpaceMLModelStore {

    static let shared = SpaceMLModelStore()

    private let userDefaultsKey = "spaceMLModelEntries"
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Read

    func find(spaceId: String) -> SpaceMLModelEntry? {
        all().first { $0.spaceId == spaceId }
    }

    /// Returns a valid on-disk URL for the space's model.
    /// Handles stale absolute paths caused by app container UUID changes after re-installs.
    func modelURL(for spaceId: String) -> URL? {
        guard var entry = find(spaceId: spaceId) else { return nil }

        let url = URL(fileURLWithPath: entry.localPath)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        // App container UUID changed — recover by re-rooting the MLModels/ suffix
        // under the current Application Support directory.
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let components = url.pathComponents
        guard let idx = components.firstIndex(of: "MLModels") else { return nil }
        let recovered = components[idx...].reduce(appSupport) { $0.appendingPathComponent($1) }
        guard FileManager.default.fileExists(atPath: recovered.path) else { return nil }

        // Persist the corrected path so we don't repeat this recovery next time.
        entry.localPath = recovered.path
        save(entry)
        return recovered
    }

    // MARK: - Write

    func save(_ entry: SpaceMLModelEntry) {
        var existing = all().filter { $0.spaceId != entry.spaceId }
        existing.append(entry)
        persist(existing)
    }

    func remove(spaceId: String) {
        persist(all().filter { $0.spaceId != spaceId })
    }

    // MARK: - Private

    private func all() -> [SpaceMLModelEntry] {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([SpaceMLModelEntry].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist(_ entries: [SpaceMLModelEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: userDefaultsKey)
    }
}
