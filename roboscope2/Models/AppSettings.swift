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

    var laserGuideMLModelURL: URL? {
        guard let path = laserGuideMLModelLocalPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
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
