//
//  PresenceService.swift
//  roboscope2
//
//  Service for real-time presence tracking and collaboration
//

import Foundation
import Combine

/// Service for managing real-time user presence in work sessions
final class PresenceService: ObservableObject {
    static let shared = PresenceService()
    
    private let networkManager = NetworkManager.shared
    
    // MARK: - Published Properties
    
    @Published private(set) var activeUsers: [String] = []
    @Published private(set) var isConnected: Bool = false
    @Published var error: String? = nil
    
    // MARK: - Private Properties
    
    private var heartbeatTimer: Timer?
    private var currentSessionId: UUID?
    private let userId: String
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Configuration
    
    private let heartbeatInterval: TimeInterval = 10.0 // Send heartbeat every 10 seconds
    private let presenceTimeout: TimeInterval = 30.0  // Consider user offline after 30 seconds
    
    private init() {
        // Generate or retrieve persistent user ID
        if let saved = UserDefaults.standard.string(forKey: "RoboscopeUserId") {
            self.userId = saved
        } else {
            self.userId = UUID().uuidString
            UserDefaults.standard.set(self.userId, forKey: "RoboscopeUserId")
        }
        
        setupAppStateObservers()
    }
    
    deinit {
        leaveCurrentSession()
    }
    
    // MARK: - Presence Operations
    
    /// Join a work session for presence tracking
    /// - Parameter sessionId: The work session UUID
    func joinSession(_ sessionId: UUID) async throws {
        // Leave current session if any
        leaveCurrentSession()
        
        currentSessionId = sessionId
        
        do {
            // Send initial heartbeat
            try await sendHeartbeat(sessionId: sessionId)
            
            // Start periodic heartbeats
            await startHeartbeatTimer(sessionId: sessionId)
            
            // Update user list
            try await updateUserList(sessionId: sessionId)
            
            await setConnected(true)
            await clearError()
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Leave the current session
    func leaveCurrentSession() {
        guard let sessionId = currentSessionId else { return }
        
        stopHeartbeatTimer()
        
        Task {
            try? await leaveSession(sessionId: sessionId)
            await setConnected(false)
            await clearActiveUsers()
        }
        
        currentSessionId = nil
    }
    
    /// Manually update the list of active users
    /// - Parameter sessionId: The work session UUID
    func updateUserList(sessionId: UUID) async throws {
        do {
            let response: PresenceListResponse = try await networkManager.get(
                endpoint: "/presence/\(sessionId.uuidString)"
            )
            
            await updateActiveUsers(response.users)
            await clearError()
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Check if a specific user is currently active
    /// - Parameter userId: The user ID to check
    /// - Returns: True if the user is active
    func isUserActive(_ userId: String) -> Bool {
        return activeUsers.contains(userId)
    }
    
    /// Get the current user ID
    var currentUserId: String {
        return userId
    }
    
    // MARK: - Private Methods
    
    private func sendHeartbeat(sessionId: UUID) async throws {
        let heartbeat = PresenceHeartbeat(userId: userId)
        
        try await networkManager.post(
            endpoint: "/presence/\(sessionId.uuidString)",
            body: heartbeat
        )
    }
    
    private func leaveSession(sessionId: UUID) async throws {
        try await networkManager.delete(
            endpoint: "/presence/\(sessionId.uuidString)/\(userId)"
        )
    }
    
    @MainActor
    private func startHeartbeatTimer(sessionId: UUID) {
        stopHeartbeatTimer()
        
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task {
                do {
                    try await self?.sendHeartbeat(sessionId: sessionId)
                    try await self?.updateUserList(sessionId: sessionId)
                } catch {
                    await self?.setError("Heartbeat failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    private func setupAppStateObservers() {
        // Handle app state changes
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task {
                    await self?.handleAppForeground()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task {
                    await self?.handleAppBackground()
                }
            }
            .store(in: &cancellables)
    }
    
    private func handleAppForeground() async {
        // Reconnect if we were previously connected
        guard let sessionId = currentSessionId else { return }
        
        do {
            try await sendHeartbeat(sessionId: sessionId)
            try await updateUserList(sessionId: sessionId)
            await startHeartbeatTimer(sessionId: sessionId)
            await setConnected(true)
        } catch {
            await setError("Failed to reconnect: \(error.localizedDescription)")
        }
    }
    
    private func handleAppBackground() async {
        stopHeartbeatTimer()
        await setConnected(false)
    }
    
    // MARK: - State Management
    
    @MainActor
    private func setConnected(_ connected: Bool) {
        isConnected = connected
    }
    
    @MainActor
    private func setError(_ errorMessage: String) {
        error = errorMessage
    }
    
    @MainActor
    private func clearError() {
        error = nil
    }
    
    @MainActor
    private func updateActiveUsers(_ users: [String]) {
        activeUsers = users
    }
    
    @MainActor
    private func clearActiveUsers() {
        activeUsers = []
    }
}

// MARK: - Presence Statistics

extension PresenceService {
    /// Get statistics about current session presence
    var presenceStats: PresenceStats {
        PresenceStats(
            totalActiveUsers: activeUsers.count,
            isCurrentUserActive: activeUsers.contains(userId),
            sessionId: currentSessionId,
            isConnected: isConnected
        )
    }
}

/// Statistics about presence in a session
struct PresenceStats {
    let totalActiveUsers: Int
    let isCurrentUserActive: Bool
    let sessionId: UUID?
    let isConnected: Bool
    
    var hasMultipleUsers: Bool {
        totalActiveUsers > 1
    }
    
    var statusDescription: String {
        if !isConnected {
            return "Disconnected"
        } else if totalActiveUsers == 0 {
            return "No active users"
        } else if totalActiveUsers == 1 {
            return "1 user active"
        } else {
            return "\(totalActiveUsers) users active"
        }
    }
}

// MARK: - UIApplication Import

#if canImport(UIKit)
import UIKit
#endif