//
//  WorkSession.swift
//  roboscope2
//
//  Data models for Work Session management
//

import Foundation

// MARK: - Enums

/// Status of a work session
enum WorkSessionStatus: String, Codable, CaseIterable {
    case draft
    case active
    case done
    case archived
    
    var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .active: return "Active"
        case .done: return "Done"
        case .archived: return "Archived"
        }
    }
    
    var icon: String {
        switch self {
        case .draft: return "doc.text"
        case .active: return "play.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        }
    }
}

/// Type of work session
enum WorkSessionType: String, Codable, CaseIterable {
    case inspection
    case repair
    case other
    
    var displayName: String {
        switch self {
        case .inspection: return "Inspection"
        case .repair: return "Repair"
        case .other: return "Other"
        }
    }
    
    var icon: String {
        switch self {
        case .inspection: return "magnifyingglass"
        case .repair: return "wrench.and.screwdriver.fill"
        case .other: return "ellipsis.circle"
        }
    }
}

// MARK: - WorkSession Models

/// Core WorkSession model representing a work session in a space
struct WorkSession: Codable, Identifiable, Hashable {
    let id: UUID
    let spaceId: UUID
    let sessionType: WorkSessionType
    let status: WorkSessionStatus
    let startedAt: Date?
    let completedAt: Date?
    let version: Int64
    let meta: [String: AnyCodable]
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, status, version, meta
        case spaceId = "space_id"
        case sessionType = "session_type"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    /// Duration of the session (if completed)
    var duration: TimeInterval? {
        guard let startedAt = startedAt,
              let completedAt = completedAt else {
            return nil
        }
        return completedAt.timeIntervalSince(startedAt)
    }
    
    /// Check if the session is currently active
    var isActive: Bool {
        return status == .active
    }
    
    /// Check if the session is completed
    var isCompleted: Bool {
        return status == .done || status == .archived
    }
    
    /// Human-readable status display
    var statusDisplay: String {
        status.displayName
    }
}

// MARK: - WorkSession DTOs

/// DTO for creating a new WorkSession
struct CreateWorkSession: Codable {
    let spaceId: UUID
    let sessionType: WorkSessionType
    let status: WorkSessionStatus?
    let startedAt: Date?
    let completedAt: Date?
    let meta: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case status, meta
        case spaceId = "space_id"
        case sessionType = "session_type"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
    
    init(
        spaceId: UUID,
        sessionType: WorkSessionType,
        status: WorkSessionStatus = .draft,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        meta: [String: Any]? = nil
    ) {
        self.spaceId = spaceId
        self.sessionType = sessionType
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.meta = meta?.mapValues { AnyCodable($0) }
    }
    
    /// Create an active session starting now
    static func activeSession(
        spaceId: UUID,
        sessionType: WorkSessionType,
        meta: [String: Any]? = nil
    ) -> CreateWorkSession {
        CreateWorkSession(
            spaceId: spaceId,
            sessionType: sessionType,
            status: .active,
            startedAt: Date(),
            meta: meta
        )
    }
}

/// DTO for updating an existing WorkSession
struct UpdateWorkSession: Codable {
    let spaceId: UUID?
    let sessionType: WorkSessionType?
    let status: WorkSessionStatus?
    let startedAt: Date?
    let completedAt: Date?
    let version: Int64? // For optimistic locking
    let meta: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case status, version, meta
        case spaceId = "space_id"
        case sessionType = "session_type"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
    
    init(
        spaceId: UUID? = nil,
        sessionType: WorkSessionType? = nil,
        status: WorkSessionStatus? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        version: Int64? = nil,
        meta: [String: Any]? = nil
    ) {
        self.spaceId = spaceId
        self.sessionType = sessionType
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.version = version
        self.meta = meta?.mapValues { AnyCodable($0) }
    }
    
    /// Complete a session (mark as done with end time)
    static func complete(version: Int64) -> UpdateWorkSession {
        UpdateWorkSession(
            status: .done,
            completedAt: Date(),
            version: version
        )
    }
    
    /// Start a session (mark as active with start time)
    static func start(version: Int64) -> UpdateWorkSession {
        UpdateWorkSession(
            status: .active,
            startedAt: Date(),
            version: version
        )
    }
}