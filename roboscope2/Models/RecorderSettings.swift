//
//  RecorderSettings.swift
//  roboscope2
//
//  Camera recording configuration
//

import Foundation

/// Persisted camera settings for the recorder.
struct RecorderSettings: Codable, Equatable {
    /// Predefined capture proportions replacing separate resolution + crop.
    enum CaptureProportion: String, CaseIterable, Codable {
        case full16x9   = "16:9"
        case standard4x3 = "4:3"
        case square      = "1:1"
        case squareTight = "1:1 Tight"

        /// Aspect ratio (width / height).
        var aspectRatio: CGFloat {
            switch self {
            case .full16x9:    return 16.0 / 9.0
            case .standard4x3: return 4.0 / 3.0
            case .square,
                 .squareTight: return 1.0
            }
        }

        /// Whether this proportion is square.
        var isSquare: Bool {
            switch self {
            case .square, .squareTight: return true
            default: return false
            }
        }

        /// Output pixel dimensions (derived from 1080p base).
        var pixelSize: (width: Int, height: Int) {
            let base: Int
            switch self {
            case .squareTight: base = 1080  // tighter square, smaller
            default:           base = 1920  // full-width base
            }
            let height = Int(CGFloat(base) / aspectRatio)
            return (base, height)
        }

        var label: String { rawValue }
    }

    enum FrameRate: Int, CaseIterable, Codable {
        case fps24 = 24
        case fps30 = 30
        case fps60 = 60
    }

    enum CameraPosition: String, CaseIterable, Codable {
        case front
        case back
        case backUltraWide

        var label: String {
            switch self {
            case .front:         return "Front"
            case .back:          return "Back"
            case .backUltraWide: return "Ultra-Wide"
            }
        }
    }

    enum Quality: String, CaseIterable, Codable {
        case low, medium, high
    }

    var proportion: CaptureProportion = .full16x9
    var frameRate: FrameRate = .fps30
    var camera: CameraPosition = .back
    var quality: Quality = .high

    // MARK: - Persistence

    private static let defaultsKey = "recorderSettings"

    static func load() -> RecorderSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(RecorderSettings.self, from: data)
        else { return RecorderSettings() }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
