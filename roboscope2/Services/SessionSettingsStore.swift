//
//  SessionSettingsStore.swift
//  roboscope2
//
//  Local storage for session settings (LaserGuide mode, etc.)
//

import Foundation

/// Local storage for session-specific settings
final class SessionSettingsStore {
    static let shared = SessionSettingsStore()
    
    private let defaults = UserDefaults.standard
    private let laserGuideKey = "session_laserguide_modes"
    private let laserGuideMLKey = "session_laserguide_ml_detection"
    
    private init() {}
    
    // MARK: - LaserGuide Mode
    
    /// Check if a session has LaserGuide mode enabled
    func isLaserGuide(sessionId: UUID) -> Bool {
        let modes = getLaserGuideModes()
        return modes[sessionId.uuidString] ?? false
    }
    
    /// Set LaserGuide mode for a session
    func setLaserGuide(sessionId: UUID, enabled: Bool) {
        var modes = getLaserGuideModes()
        modes[sessionId.uuidString] = enabled
        saveLaserGuideModes(modes)
    }
    
    /// Remove LaserGuide setting when session is deleted
    func clearLaserGuide(sessionId: UUID) {
        var modes = getLaserGuideModes()
        modes.removeValue(forKey: sessionId.uuidString)
        saveLaserGuideModes(modes)
    }

    // MARK: - LaserGuide ML Detection

    /// Check if a session has ML-based laser detection enabled.
    /// Defaults to false.
    func isLaserGuideMLDetection(sessionId: UUID) -> Bool {
        let modes = getLaserGuideMLModes()
        return modes[sessionId.uuidString] ?? false
    }

    /// Set ML-based laser detection for a session.
    func setLaserGuideMLDetection(sessionId: UUID, enabled: Bool) {
        var modes = getLaserGuideMLModes()
        modes[sessionId.uuidString] = enabled
        saveLaserGuideMLModes(modes)
    }

    /// Remove ML detection setting when session is deleted.
    func clearLaserGuideMLDetection(sessionId: UUID) {
        var modes = getLaserGuideMLModes()
        modes.removeValue(forKey: sessionId.uuidString)
        saveLaserGuideMLModes(modes)
    }
    
    // MARK: - Private Helpers
    
    private func getLaserGuideModes() -> [String: Bool] {
        return defaults.dictionary(forKey: laserGuideKey) as? [String: Bool] ?? [:]
    }
    
    private func saveLaserGuideModes(_ modes: [String: Bool]) {
        defaults.set(modes, forKey: laserGuideKey)
    }

    private func getLaserGuideMLModes() -> [String: Bool] {
        return defaults.dictionary(forKey: laserGuideMLKey) as? [String: Bool] ?? [:]
    }

    private func saveLaserGuideMLModes(_ modes: [String: Bool]) {
        defaults.set(modes, forKey: laserGuideMLKey)
    }
}
