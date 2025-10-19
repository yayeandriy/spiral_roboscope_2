//
//  PresenceModels.swift
//  roboscope2
//
//  Data models for presence tracking and collaborative features
//

import Foundation

// MARK: - Presence Models

/// Information about a user's presence in a work session
struct PresenceInfo: Codable, Identifiable {
    let userId: String
    let timestamp: Date
    
    var id: String { userId }
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case timestamp
    }
    
    /// Check if this presence is still active (within last 30 seconds)
    var isActive: Bool {
        Date().timeIntervalSince(timestamp) < 30.0
    }
}

/// Heartbeat payload for maintaining presence
struct PresenceHeartbeat: Codable {
    let userId: String
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

/// Response containing list of active users
struct PresenceListResponse: Codable {
    let users: [String]
}

// MARK: - Lock Models

/// Request to acquire a distributed lock
struct LockRequest: Codable {
    let ttlSeconds: Int
    
    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }
    
    /// Standard lock duration (30 seconds)
    static let standard = LockRequest(ttlSeconds: 30)
    
    /// Short lock duration (10 seconds)
    static let short = LockRequest(ttlSeconds: 10)
    
    /// Long lock duration (60 seconds)
    static let long = LockRequest(ttlSeconds: 60)
}

/// Response from lock acquisition attempt
struct LockResponse: Codable {
    let acquired: Bool
    let token: String?
    
    /// Check if lock was successfully acquired
    var isSuccess: Bool {
        acquired && token != nil
    }
}

/// Current status of a lock
struct LockStatus: Codable {
    let locked: Bool
}

/// Request to extend an existing lock
struct ExtendLockRequest: Codable {
    let token: String
    let ttlSeconds: Int
    
    enum CodingKeys: String, CodingKey {
        case token
        case ttlSeconds = "ttl_seconds"
    }
}

/// Response from lock extension attempt
struct ExtendLockResponse: Codable {
    let extended: Bool
}

/// Request to release a lock
struct UnlockRequest: Codable {
    let token: String
}

/// Response from unlock attempt
struct UnlockResponse: Codable {
    let released: Bool
}

// MARK: - Sync Models

/// Represents a sync conflict when optimistic locking fails
struct SyncConflict: Error, LocalizedError {
    let resourceType: String
    let resourceId: UUID
    let expectedVersion: Int64
    let actualVersion: Int64
    
    var errorDescription: String? {
        "Sync conflict: \(resourceType) \(resourceId) expected version \(expectedVersion) but found \(actualVersion)"
    }
}

/// Strategy for resolving sync conflicts
enum ConflictResolutionStrategy {
    case serverWins      // Use server version, discard local changes
    case clientWins      // Force client version (use with caution)
    case merge           // Attempt to merge changes (custom logic required)
    case prompt          // Ask user to resolve conflict
}

/// Result of a sync operation
enum SyncResult<T> {
    case success(T)
    case conflict(SyncConflict, serverVersion: T)
    case error(Error)
}

// MARK: - Background Sync Models

/// Configuration for background sync behavior
struct BackgroundSyncConfig {
    let enabled: Bool
    let interval: TimeInterval
    let maxRetries: Int
    let retryBackoffMultiplier: Double
    
    static let `default` = BackgroundSyncConfig(
        enabled: true,
        interval: 30.0,           // Sync every 30 seconds
        maxRetries: 3,
        retryBackoffMultiplier: 2.0
    )
    
    static let aggressive = BackgroundSyncConfig(
        enabled: true,
        interval: 10.0,           // Sync every 10 seconds
        maxRetries: 5,
        retryBackoffMultiplier: 1.5
    )
    
    static let conservative = BackgroundSyncConfig(
        enabled: true,
        interval: 60.0,           // Sync every minute
        maxRetries: 2,
        retryBackoffMultiplier: 3.0
    )
}

/// Status of background sync
enum BackgroundSyncStatus {
    case idle
    case syncing
    case success(lastSync: Date)
    case error(Error, lastAttempt: Date)
}

// MARK: - User Models

/// Simple user identification for presence tracking
struct User: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let avatarUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case avatarUrl = "avatar_url"
    }
    
    /// Display name (fallback to ID if name not available)
    var displayName: String {
        return name ?? id
    }
    
    /// Abbreviated name for UI (first two characters)
    var initials: String {
        let name = displayName
        if name.count >= 2 {
            return String(name.prefix(2)).uppercased()
        } else {
            return name.uppercased()
        }
    }
}

/// Current user session information
struct UserSession: Codable {
    let userId: String
    let sessionId: String
    let deviceId: String
    let startedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case startedAt = "started_at"
    }
}