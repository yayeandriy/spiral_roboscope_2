//
//  SpaceMLDetectionSettingsStore.swift
//  roboscope2
//
//  Local persistence for per-space ML laser detection tuning.
//

import Foundation

struct LaserMLDetectionSettings: Codable, Equatable {
    var confidenceThreshold: Float
    var useROI: Bool
    var roiSize: Float
    var maxDetections: Int
}

final class SpaceMLDetectionSettingsStore {
    static let shared = SpaceMLDetectionSettingsStore()

    private let defaults = UserDefaults.standard
    private let keyPrefix = "space_laser_ml_detection_settings_"

    private init() {}

    func load(spaceId: UUID) -> LaserMLDetectionSettings? {
        let key = keyPrefix + spaceId.uuidString
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(LaserMLDetectionSettings.self, from: data)
        } catch {
            return nil
        }
    }

    func save(spaceId: UUID, settings: LaserMLDetectionSettings) {
        let key = keyPrefix + spaceId.uuidString
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: key)
        } catch {
            // Ignore save errors.
        }
    }

    func clear(spaceId: UUID) {
        let key = keyPrefix + spaceId.uuidString
        defaults.removeObject(forKey: key)
    }
}
