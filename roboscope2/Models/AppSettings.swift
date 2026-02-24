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
        static let modelPointsSampleCount = "modelPointsSampleCount"
        static let scanPointsSampleCount = "scanPointsSampleCount"
        static let maxICPIterations = "maxICPIterations"
        static let icpConvergenceThreshold = "icpConvergenceThreshold"
        static let pauseARDuringRegistration = "pauseARDuringRegistration"
        static let useBackgroundLoading = "useBackgroundLoading"
        static let skipModelConsistencyChecks = "skipModelConsistencyChecks"
        static let showPerformanceLogs = "showPerformanceLogs"
        static let registrationPreset = "registrationPreset"
        static let laserGuideAutoRestartDistanceMeters = "laserGuideAutoRestartDistanceMeters"
        static let laserGuideAutoScopeStableSeconds = "laserGuideAutoScopeStableSeconds"
        static let laserGuideMLModelLocalPath = "laserGuideMLModelLocalPath"
        static let laserGuideMLModelDisplayName = "laserGuideMLModelDisplayName"
        static let laserGuideMLModelSourceURL = "laserGuideMLModelSourceURL"
        static let videoModeEnabled = "videoModeEnabled"
        static let videoModeDistanceScale = "videoModeDistanceScale"
        static let videoModeAccumulatorFrames = "videoModeAccumulatorFrames"
        static let showAccumulatedOverlay = "showAccumulatedOverlay"
        static let lineOverDotFilter = "lineOverDotFilter"
    }
    
    // MARK: - Scan Registration Settings
    
    /// Number of points to sample from the model for registration
    @Published var modelPointsSampleCount: Int {
        didSet {
            defaults.set(modelPointsSampleCount, forKey: Keys.modelPointsSampleCount)
        }
    }
    
    /// Number of points to sample from the scan for registration
    @Published var scanPointsSampleCount: Int {
        didSet {
            defaults.set(scanPointsSampleCount, forKey: Keys.scanPointsSampleCount)
        }
    }
    
    /// Maximum number of ICP iterations
    @Published var maxICPIterations: Int {
        didSet {
            defaults.set(maxICPIterations, forKey: Keys.maxICPIterations)
        }
    }
    
    /// Convergence threshold for ICP algorithm
    @Published var icpConvergenceThreshold: Double {
        didSet {
            defaults.set(icpConvergenceThreshold, forKey: Keys.icpConvergenceThreshold)
        }
    }
    
    /// Pause AR session during registration for better performance
    @Published var pauseARDuringRegistration: Bool {
        didSet {
            defaults.set(pauseARDuringRegistration, forKey: Keys.pauseARDuringRegistration)
        }
    }
    
    /// Use background thread for model loading
    @Published var useBackgroundLoading: Bool {
        didSet {
            defaults.set(useBackgroundLoading, forKey: Keys.useBackgroundLoading)
        }
    }
    
    /// Skip consistency checks when loading models
    @Published var skipModelConsistencyChecks: Bool {
        didSet {
            defaults.set(skipModelConsistencyChecks, forKey: Keys.skipModelConsistencyChecks)
        }
    }
    
    /// Show performance timing logs
    @Published var showPerformanceLogs: Bool {
        didSet {
            defaults.set(showPerformanceLogs, forKey: Keys.showPerformanceLogs)
        }
    }
    
    // MARK: - Presets
    
    enum RegistrationPreset: String, CaseIterable {
        case instant = "Instant"
        case ultraFast = "Ultra Fast"
        case fast = "Fast"
        case balanced = "Balanced"
        case accurate = "Accurate"
        case custom = "Custom"
    }
    
    @Published var currentPreset: RegistrationPreset {
        didSet {
            defaults.set(currentPreset.rawValue, forKey: Keys.registrationPreset)
        }
    }

    // MARK: - Laser Guide

    /// When the Laser Guide has auto-scoped (snapped origin), automatically return to detection
    /// mode if the camera moves farther than this distance from the scoped dot (meters).
    @Published var laserGuideAutoRestartDistanceMeters: Double {
        didSet {
            defaults.set(laserGuideAutoRestartDistanceMeters, forKey: Keys.laserGuideAutoRestartDistanceMeters)
        }
    }

    /// How long the dot/line distance must remain stable before auto-scope snaps (seconds).
    @Published var laserGuideAutoScopeStableSeconds: Double {
        didSet {
            defaults.set(laserGuideAutoScopeStableSeconds, forKey: Keys.laserGuideAutoScopeStableSeconds)
        }
    }

    /// Optional local filesystem path to a compiled CoreML model (.mlmodelc) used for LaserGuide ML detection.
    /// When nil, the bundled `laser-pens` model is used.
    @Published var laserGuideMLModelLocalPath: String? {
        didSet {
            if let laserGuideMLModelLocalPath {
                defaults.set(laserGuideMLModelLocalPath, forKey: Keys.laserGuideMLModelLocalPath)
            } else {
                defaults.removeObject(forKey: Keys.laserGuideMLModelLocalPath)
            }
        }
    }

    /// Display name for the selected LaserGuide ML model.
    @Published var laserGuideMLModelDisplayName: String? {
        didSet {
            if let laserGuideMLModelDisplayName {
                defaults.set(laserGuideMLModelDisplayName, forKey: Keys.laserGuideMLModelDisplayName)
            } else {
                defaults.removeObject(forKey: Keys.laserGuideMLModelDisplayName)
            }
        }
    }

    /// Original remote URL from which the currently active model was downloaded.
    /// Used to detect when the API serves a newer version.
    @Published var laserGuideMLModelSourceURL: String? {
        didSet {
            if let laserGuideMLModelSourceURL {
                defaults.set(laserGuideMLModelSourceURL, forKey: Keys.laserGuideMLModelSourceURL)
            } else {
                defaults.removeObject(forKey: Keys.laserGuideMLModelSourceURL)
            }
        }
    }

    var laserGuideMLModelURL: URL? {
        guard let path = laserGuideMLModelLocalPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) { return url }

        // Absolute path is stale (app container UUID changed after reinstall/update).
        // Recover by finding the "MLModels/..." portion and re-rooting it under the
        // current Application Support directory, then persist the corrected path.
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let components = url.pathComponents
        guard let idx = components.firstIndex(of: "MLModels") else { return nil }
        let recovered = components[idx...].reduce(appSupport) { $0.appendingPathComponent($1) }
        guard FileManager.default.fileExists(atPath: recovered.path) else { return nil }

        DispatchQueue.main.async { self.laserGuideMLModelLocalPath = recovered.path }
        return recovered
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

    // MARK: - Initialization
    
    private init() {
        // Load saved values or use defaults
        let modelPoints = defaults.integer(forKey: Keys.modelPointsSampleCount)
        self.modelPointsSampleCount = modelPoints > 0 ? modelPoints : 5000
        
        let scanPoints = defaults.integer(forKey: Keys.scanPointsSampleCount)
        self.scanPointsSampleCount = scanPoints > 0 ? scanPoints : 10000
        
        let iterations = defaults.integer(forKey: Keys.maxICPIterations)
        self.maxICPIterations = iterations > 0 ? iterations : 30
        
        let threshold = defaults.double(forKey: Keys.icpConvergenceThreshold)
        self.icpConvergenceThreshold = threshold > 0 ? threshold : 0.001
        
        self.pauseARDuringRegistration = defaults.object(forKey: Keys.pauseARDuringRegistration) as? Bool ?? true
        self.useBackgroundLoading = defaults.object(forKey: Keys.useBackgroundLoading) as? Bool ?? true
        self.skipModelConsistencyChecks = defaults.object(forKey: Keys.skipModelConsistencyChecks) as? Bool ?? true
        self.showPerformanceLogs = defaults.object(forKey: Keys.showPerformanceLogs) as? Bool ?? false
        
        let presetRaw = defaults.string(forKey: Keys.registrationPreset) ?? RegistrationPreset.balanced.rawValue
        self.currentPreset = RegistrationPreset(rawValue: presetRaw) ?? .balanced

        let autoRestart = defaults.double(forKey: Keys.laserGuideAutoRestartDistanceMeters)
        self.laserGuideAutoRestartDistanceMeters = autoRestart > 0 ? autoRestart : 4.0

        let stableSeconds = defaults.double(forKey: Keys.laserGuideAutoScopeStableSeconds)
        self.laserGuideAutoScopeStableSeconds = stableSeconds > 0 ? stableSeconds : 1.0

        self.laserGuideMLModelLocalPath = defaults.string(forKey: Keys.laserGuideMLModelLocalPath)
        self.laserGuideMLModelDisplayName = defaults.string(forKey: Keys.laserGuideMLModelDisplayName)
        self.laserGuideMLModelSourceURL = defaults.string(forKey: Keys.laserGuideMLModelSourceURL)
        self.videoModeEnabled = defaults.object(forKey: Keys.videoModeEnabled) as? Bool ?? false
        let vmScale = defaults.float(forKey: Keys.videoModeDistanceScale)
        self.videoModeDistanceScale = vmScale > 0 ? vmScale : 5.0
        let vmFrames = defaults.integer(forKey: Keys.videoModeAccumulatorFrames)
        self.videoModeAccumulatorFrames = vmFrames > 0 ? vmFrames : 3
        self.showAccumulatedOverlay = defaults.object(forKey: Keys.showAccumulatedOverlay) as? Bool ?? true
        self.lineOverDotFilter = defaults.object(forKey: Keys.lineOverDotFilter) as? Bool ?? false
    }
    
    // MARK: - Preset Management
    
    func applyPreset(_ preset: RegistrationPreset, updateCurrentPreset: Bool = true) {
        if updateCurrentPreset {
            currentPreset = preset
        }
        
        switch preset {
        case .instant:
            modelPointsSampleCount = 1000
            scanPointsSampleCount = 3000
            maxICPIterations = 10
            icpConvergenceThreshold = 0.005
            pauseARDuringRegistration = true
            useBackgroundLoading = true
            skipModelConsistencyChecks = true
            
        case .ultraFast:
            modelPointsSampleCount = 2000
            scanPointsSampleCount = 5000
            maxICPIterations = 15
            icpConvergenceThreshold = 0.003
            pauseARDuringRegistration = true
            useBackgroundLoading = true
            skipModelConsistencyChecks = true
            
        case .fast:
            modelPointsSampleCount = 3000
            scanPointsSampleCount = 8000
            maxICPIterations = 20
            icpConvergenceThreshold = 0.002
            pauseARDuringRegistration = true
            useBackgroundLoading = true
            skipModelConsistencyChecks = true
            
        case .balanced:
            modelPointsSampleCount = 5000
            scanPointsSampleCount = 10000
            maxICPIterations = 30
            icpConvergenceThreshold = 0.001
            pauseARDuringRegistration = true
            useBackgroundLoading = true
            skipModelConsistencyChecks = true
            
        case .accurate:
            modelPointsSampleCount = 8000
            scanPointsSampleCount = 15000
            maxICPIterations = 50
            icpConvergenceThreshold = 0.0001
            pauseARDuringRegistration = false
            useBackgroundLoading = false
            skipModelConsistencyChecks = false
            
        case .custom:
            // Keep current values
            break
        }
    }
    
    func resetToDefaults() {
        applyPreset(.balanced)
    }
}
