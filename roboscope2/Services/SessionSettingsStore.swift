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
    
    // MARK: - Private Helpers
    
    private func getLaserGuideModes() -> [String: Bool] {
        return defaults.dictionary(forKey: laserGuideKey) as? [String: Bool] ?? [:]
    }
    
    private func saveLaserGuideModes(_ modes: [String: Bool]) {
        defaults.set(modes, forKey: laserGuideKey)
    }
}
