//
//  SpaceDetectionSettingsStore.swift
//  roboscope2
//
//  Local persistence for per-space laser detection tuning.
//

import Foundation
import CoreGraphics

struct LaserDetectionSettings: Codable, Equatable {
    var brightnessThreshold: Float
    var useHueDetection: Bool
    var targetHue: Float
    var minBlobSize: Double
    var lineAnisotropyThreshold: Double
    var maxDotLineYDeltaMeters: Float
}

final class SpaceDetectionSettingsStore {
    static let shared = SpaceDetectionSettingsStore()

    private let defaults = UserDefaults.standard
    private let keyPrefix = "space_laser_detection_settings_"

    private init() {}

    func load(spaceId: UUID) -> LaserDetectionSettings? {
        let key = keyPrefix + spaceId.uuidString
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(LaserDetectionSettings.self, from: data)
        } catch {
            return nil
        }
    }

    func save(spaceId: UUID, settings: LaserDetectionSettings) {
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
