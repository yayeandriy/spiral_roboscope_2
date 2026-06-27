//
//  AppSettings.swift
//  roboscope2
//
//  App-wide settings and preferences
//

import Foundation
import Combine

/// Centralized app settings manager using UserDefaults
class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    // MARK: - UserDefaults Keys
    
    private enum Keys {
        static let apiEnvironment = "apiEnvironment"
        static let laserGuideAutoRestartDistanceMeters = "laserGuideAutoRestartDistanceMeters"
        static let laserGuideMinAnchorAutoRestartDistanceMeters = "laserGuideMinAnchorAutoRestartDistanceMeters"
        static let laserGuideAutoScopeStableSeconds = "laserGuideAutoScopeStableSeconds"
        static let videoModeEnabled = "videoModeEnabled"
        static let videoModeDistanceScale = "videoModeDistanceScale"
        static let videoModeAccumulatorFrames = "videoModeAccumulatorFrames"
        static let showAccumulatedOverlay = "showAccumulatedOverlay"
        static let lineOverDotFilter = "lineOverDotFilter"
        static let usePerFrame3DPlacement = "usePerFrame3DPlacement"
        static let useYDeltaCheck = "useYDeltaCheck"
        static let laserGuideDistanceToleranceMeters = "laserGuideDistanceToleranceMeters"
        static let testMode = "testMode"
    }
    
    // MARK: - Laser Guide

    /// When the Laser Guide has auto-scoped (snapped origin), automatically return to detection
    /// mode if the camera moves farther than this distance from the scoped dot (meters).
    @Published var laserGuideAutoRestartDistanceMeters: Double {
        didSet {
            defaults.set(laserGuideAutoRestartDistanceMeters, forKey: Keys.laserGuideAutoRestartDistanceMeters)
        }
    }

    /// Minimum distance (meters) the camera must travel from the last anchor dot before the app
    /// returns to detection mode and allows a new anchor snap. This floor prevents closely-spaced
    /// guide segments from triggering a premature re-snap while the phone is still moving near
    /// the previous anchor — which can accidentally reverse the anchor-baseline direction.
    /// Applied as: threshold = max(minAnchorAutoRestart, 0.75 × nearestNeighborGap).
    @Published var laserGuideMinAnchorAutoRestartDistanceMeters: Double {
        didSet {
            defaults.set(laserGuideMinAnchorAutoRestartDistanceMeters,
                         forKey: Keys.laserGuideMinAnchorAutoRestartDistanceMeters)
        }
    }

    /// How long the dot/line distance must remain stable before auto-scope snaps (seconds).
    @Published var laserGuideAutoScopeStableSeconds: Double {
        didSet {
            defaults.set(laserGuideAutoScopeStableSeconds, forKey: Keys.laserGuideAutoScopeStableSeconds)
        }
    }

    // MARK: - Video Mode

    /// When true, LaserGuide session runs detection against uploaded video footage instead of live AR camera.
    @Published var videoModeEnabled: Bool {
        didSet { defaults.set(videoModeEnabled, forKey: Keys.videoModeEnabled) }
    }

    /// Scale factor to convert normalised image-space distance (0..1) to fake world-space metres.
    /// Used by the video-mode measurement path in LaserMLDetectionOverlay when arView is nil.
    /// Default 5.0 — tune so detected values fall within the laser-guide segment range.
    @Published var videoModeDistanceScale: Float {
        didSet { defaults.set(videoModeDistanceScale, forKey: Keys.videoModeDistanceScale) }
    }

    /// Number of recent frames whose detections are merged before measurement.
    /// Higher values recover more of a partially-drawn laser line at the cost of temporal blending.
    @Published var videoModeAccumulatorFrames: Int {
        didSet { defaults.set(videoModeAccumulatorFrames, forKey: Keys.videoModeAccumulatorFrames) }
    }

    /// When true the detection overlay shows accumulated (merged) boxes; per-frame boxes are hidden.
    @Published var showAccumulatedOverlay: Bool {
        didSet { defaults.set(showAccumulatedOverlay, forKey: Keys.showAccumulatedOverlay) }
    }

    /// When true, line detections that overlap a dot detection are excluded from
    /// both the overlay and all calculations (accumulator, measurement).
    @Published var lineOverDotFilter: Bool {
        didSet { defaults.set(lineOverDotFilter, forKey: Keys.lineOverDotFilter) }
    }

    /// When true, the accumulator raycasts each frame's best dot & line to get 3-D world
    /// positions and places the origin immediately on match. When false, reverts to the
    /// pure 2-D accumulator path where the overlay handles raycasting from merged boxes.
    @Published var usePerFrame3DPlacement: Bool {
        didSet { defaults.set(usePerFrame3DPlacement, forKey: Keys.usePerFrame3DPlacement) }
    }

    /// When true, Phase 2 rejects a line whose world Y differs from the locked dot's world Y
    /// by more than `mlDetection.maxDotLineYDeltaMeters`. Disable to allow lines on different planes.
    @Published var useYDeltaCheck: Bool {
        didSet { defaults.set(useYDeltaCheck, forKey: Keys.useYDeltaCheck) }
    }

    /// Maximum allowed delta between the measured dot↔line distance and the nearest laser guide
    /// segment length before the origin snap is rejected (meters).
    @Published var laserGuideDistanceToleranceMeters: Float {
        didSet { defaults.set(laserGuideDistanceToleranceMeters, forKey: Keys.laserGuideDistanceToleranceMeters) }
    }

    // MARK: - API Environment

    enum APIEnvironmentSetting: String, CaseIterable {
        case dev
        case prod

        var displayName: String {
            switch self {
            case .dev: return "Development"
            case .prod: return "Production"
            }
        }
    }

    /// Which API environment the app talks to.
    @Published var apiEnvironment: APIEnvironmentSetting {
        didSet { defaults.set(apiEnvironment.rawValue, forKey: Keys.apiEnvironment) }
    }

    /// Show ALL spaces including inactive ones (for testing).
    @Published var testMode: Bool {
        didSet { defaults.set(testMode, forKey: Keys.testMode) }
    }

    // MARK: - Initialization
    
    private init() {
        // Load saved values or use defaults
        let autoRestart = defaults.double(forKey: Keys.laserGuideAutoRestartDistanceMeters)
        self.laserGuideAutoRestartDistanceMeters = autoRestart > 0 ? autoRestart : 4.0

        let minAnchorRestart = defaults.double(forKey: Keys.laserGuideMinAnchorAutoRestartDistanceMeters)
        self.laserGuideMinAnchorAutoRestartDistanceMeters = minAnchorRestart > 0 ? minAnchorRestart : 2.0

        let stableSeconds = defaults.double(forKey: Keys.laserGuideAutoScopeStableSeconds)
        self.laserGuideAutoScopeStableSeconds = stableSeconds > 0 ? stableSeconds : 1.0

        self.videoModeEnabled = defaults.object(forKey: Keys.videoModeEnabled) as? Bool ?? false
        let vmScale = defaults.float(forKey: Keys.videoModeDistanceScale)
        self.videoModeDistanceScale = vmScale > 0 ? vmScale : 5.0
        let vmFrames = defaults.integer(forKey: Keys.videoModeAccumulatorFrames)
        self.videoModeAccumulatorFrames = vmFrames > 0 ? vmFrames : 3
        self.showAccumulatedOverlay = defaults.object(forKey: Keys.showAccumulatedOverlay) as? Bool ?? true
        self.lineOverDotFilter = defaults.object(forKey: Keys.lineOverDotFilter) as? Bool ?? false
        self.usePerFrame3DPlacement = defaults.object(forKey: Keys.usePerFrame3DPlacement) as? Bool ?? true
        self.useYDeltaCheck = defaults.object(forKey: Keys.useYDeltaCheck) as? Bool ?? true
        let toleranceSaved = defaults.float(forKey: Keys.laserGuideDistanceToleranceMeters)
        self.laserGuideDistanceToleranceMeters = toleranceSaved > 0 ? toleranceSaved : 0.03
        self.testMode = defaults.object(forKey: Keys.testMode) as? Bool ?? false

        // API environment: default to dev in DEBUG, prod otherwise (first launch only).
        if let raw = defaults.string(forKey: Keys.apiEnvironment),
           let env = APIEnvironmentSetting(rawValue: raw) {
            self.apiEnvironment = env
        } else {
            self.apiEnvironment = .prod
        }
    }
}
