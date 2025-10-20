//
//  LockService.swift
//  roboscope2
//
//  Service for distributed locking and collaborative editing
//

import Foundation
import Combine

/// Service for managing distributed locks for collaborative editing
final class LockService: ObservableObject {
    static let shared = LockService()
    
    private let networkManager = NetworkManager.shared
    
    // MARK: - Published Properties
    
    @Published private(set) var activeLocks: [UUID: LockInfo] = [:]
    @Published var error: String? = nil
    
    // MARK: - Private Properties
    
    private var lockTokens: [UUID: String] = [:]
    private var lockExtensionTimers: [UUID: Timer] = [:]
    
    // MARK: - Configuration
    
    private let defaultTTL: Int = 30 // 30 seconds default lock duration
    private let extensionInterval: TimeInterval = 20.0 // Extend lock every 20 seconds (before 30s expiry)
    
    private init() {}
    
    deinit {
        releaseAllLocks()
    }
    
    // MARK: - Lock Operations
    
    /// Acquire a distributed lock for a work session
    /// - Parameters:
    ///   - sessionId: The work session UUID
    ///   - ttl: Lock time-to-live in seconds (default: 30)
    /// - Returns: True if lock was acquired successfully
    func acquireLock(sessionId: UUID, ttl: Int = 30) async throws -> Bool {
        do {
            let request = LockRequest(ttlSeconds: ttl)
            let response: LockResponse = try await networkManager.post(
                endpoint: "/locks/work-sessions/\(sessionId.uuidString)",
                body: request
            )
            
            if response.isSuccess, let token = response.token {
                await storeLockInfo(sessionId: sessionId, token: token, ttl: ttl)
                startLockExtension(sessionId: sessionId, ttl: ttl)
                await clearError()
                return true
            } else {
                return false
            }
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Extend an existing lock
    /// - Parameters:
    ///   - sessionId: The work session UUID
    ///   - ttl: New time-to-live in seconds
    /// - Returns: True if lock was extended successfully
    func extendLock(sessionId: UUID, ttl: Int = 30) async throws -> Bool {
        guard let token = lockTokens[sessionId] else {
            throw APIError.badRequest(message: "No lock token found for session")
        }
        
        do {
            let request = ExtendLockRequest(token: token, ttlSeconds: ttl)
            let response: ExtendLockResponse = try await networkManager.post(
                endpoint: "/locks/work-sessions/\(sessionId.uuidString)/extend",
                body: request
            )
            
            if response.extended {
                await updateLockExpiry(sessionId: sessionId, ttl: ttl)
                await clearError()
                return true
            } else {
                // Lock extension failed, remove from our tracking
                await removeLockInfo(sessionId: sessionId)
                stopLockExtension(sessionId: sessionId)
                return false
            }
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Release a lock
    /// - Parameter sessionId: The work session UUID
    /// - Returns: True if lock was released successfully
    func releaseLock(sessionId: UUID) async throws -> Bool {
        guard let token = lockTokens[sessionId] else {
            // Already released or never acquired
            return true
        }
        
        do {
            let request = UnlockRequest(token: token)
            let response: UnlockResponse = try await networkManager.post(
                endpoint: "/locks/work-sessions/\(sessionId.uuidString)/unlock",
                body: request
            )
            
            await removeLockInfo(sessionId: sessionId)
            stopLockExtension(sessionId: sessionId)
            await clearError()
            
            return response.released
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Check if a work session is currently locked
    /// - Parameter sessionId: The work session UUID
    /// - Returns: True if the session is locked
    func isLocked(sessionId: UUID) async throws -> Bool {
        do {
            let status: LockStatus = try await networkManager.get(
                endpoint: "/locks/work-sessions/\(sessionId.uuidString)/status"
            )
            
            await clearError()
            return status.locked
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Check if we currently hold the lock for a session
    /// - Parameter sessionId: The work session UUID
    /// - Returns: True if we hold the lock
    func holdsLock(sessionId: UUID) -> Bool {
        return lockTokens[sessionId] != nil
    }
    
    /// Get lock information for a session
    /// - Parameter sessionId: The work session UUID
    /// - Returns: Lock info if available
    func getLockInfo(sessionId: UUID) -> LockInfo? {
        return activeLocks[sessionId]
    }
    
    /// Release all currently held locks
    func releaseAllLocks() {
        let sessionIds = Array(lockTokens.keys)
        
        for sessionId in sessionIds {
            Task {
                try? await releaseLock(sessionId: sessionId)
            }
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Try to acquire a lock with retries
    /// - Parameters:
    ///   - sessionId: The work session UUID
    ///   - maxRetries: Maximum number of retry attempts
    ///   - retryDelay: Delay between retries in seconds
    /// - Returns: True if lock was eventually acquired
    func acquireLockWithRetry(
        sessionId: UUID,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1.0
    ) async throws -> Bool {
        for attempt in 0...maxRetries {
            let success = try await acquireLock(sessionId: sessionId)
            if success {
                return true
            }
            
            if attempt < maxRetries {
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        
        return false
    }
    
    /// Safely execute code while holding a lock
    /// - Parameters:
    ///   - sessionId: The work session UUID
    ///   - operation: The operation to execute while locked
    /// - Returns: The result of the operation
    func withLock<T>(
        sessionId: UUID,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let acquired = try await acquireLock(sessionId: sessionId)
        
        guard acquired else {
            throw APIError.conflict(message: "Could not acquire lock for session")
        }
        
        defer {
            Task {
                try? await releaseLock(sessionId: sessionId)
            }
        }
        
        return try await operation()
    }
    
    // MARK: - Private Methods
    
    private func startLockExtension(sessionId: UUID, ttl: Int) {
        stopLockExtension(sessionId: sessionId)
        
        let timer = Timer.scheduledTimer(withTimeInterval: extensionInterval, repeats: true) { [weak self] _ in
            Task {
                do {
                    let extended = try await self?.extendLock(sessionId: sessionId, ttl: ttl) ?? false
                    if !extended {
                        // Lock extension failed, stop the timer
                        self?.stopLockExtension(sessionId: sessionId)
                    }
                } catch {
                    await self?.setError("Failed to extend lock: \(error.localizedDescription)")
                    self?.stopLockExtension(sessionId: sessionId)
                }
            }
        }
        
        lockExtensionTimers[sessionId] = timer
    }
    
    private func stopLockExtension(sessionId: UUID) {
        lockExtensionTimers[sessionId]?.invalidate()
        lockExtensionTimers.removeValue(forKey: sessionId)
    }
    
    // MARK: - State Management
    
    @MainActor
    private func storeLockInfo(sessionId: UUID, token: String, ttl: Int) {
        lockTokens[sessionId] = token
        activeLocks[sessionId] = LockInfo(
            sessionId: sessionId,
            token: token,
            acquiredAt: Date(),
            expiresAt: Date().addingTimeInterval(TimeInterval(ttl)),
            ttl: ttl
        )
    }
    
    @MainActor
    private func updateLockExpiry(sessionId: UUID, ttl: Int) {
        if var lockInfo = activeLocks[sessionId] {
            lockInfo.expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
            lockInfo.ttl = ttl
            activeLocks[sessionId] = lockInfo
        }
    }
    
    @MainActor
    private func removeLockInfo(sessionId: UUID) {
        lockTokens.removeValue(forKey: sessionId)
        activeLocks.removeValue(forKey: sessionId)
    }
    
    @MainActor
    private func setError(_ errorMessage: String) {
        error = errorMessage
    }
    
    @MainActor
    private func clearError() {
        error = nil
    }
}

// MARK: - Supporting Types

/// Information about an active lock
struct LockInfo {
    let sessionId: UUID
    let token: String
    let acquiredAt: Date
    var expiresAt: Date
    var ttl: Int
    
    /// Check if the lock is still valid (not expired)
    var isValid: Bool {
        return Date() < expiresAt
    }
    
    /// Time remaining until lock expiry
    var timeRemaining: TimeInterval {
        return max(0, expiresAt.timeIntervalSinceNow)
    }
    
    /// Human-readable time remaining
    var timeRemainingFormatted: String {
        let remaining = timeRemaining
        if remaining > 60 {
            return String(format: "%.0f min", remaining / 60)
        } else {
            return String(format: "%.0f sec", remaining)
        }
    }
}

// MARK: - Lock Service Statistics

extension LockService {
    /// Get statistics about current locks
    var lockStats: LockStats {
        LockStats(
            totalActiveLocks: activeLocks.count,
            expiringSoon: activeLocks.values.filter { $0.timeRemaining < 10 }.count,
            oldestLock: activeLocks.values.min(by: { $0.acquiredAt < $1.acquiredAt })
        )
    }
}

/// Statistics about active locks
struct LockStats {
    let totalActiveLocks: Int
    let expiringSoon: Int
    let oldestLock: LockInfo?
    
    var hasExpiringLocks: Bool {
        expiringSoon > 0
    }
    
    var statusDescription: String {
        if totalActiveLocks == 0 {
            return "No active locks"
        } else if totalActiveLocks == 1 {
            return "1 active lock"
        } else {
            return "\(totalActiveLocks) active locks"
        }
    }
}