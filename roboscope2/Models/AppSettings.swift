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
