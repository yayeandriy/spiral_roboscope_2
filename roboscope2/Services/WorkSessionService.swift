//
//  WorkSessionService.swift
//  roboscope2
//
//  API service for WorkSession management
//

import Foundation
import Combine

/// Service for managing WorkSessions (work tracking in spaces)
final class WorkSessionService: ObservableObject {
    static let shared = WorkSessionService()
    
    private let networkManager = NetworkManager.shared
    
    // MARK: - Published Properties
    
    @Published var workSessions: [WorkSession] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    
    private init() {}
    
    // MARK: - WorkSession Operations
    
    /// List work sessions with optional filters
    /// - Parameters:
    ///   - spaceId: Optional space filter
    ///   - status: Optional status filter
    ///   - sessionType: Optional type filter
    /// - Returns: Array of work sessions
    func listWorkSessions(
        spaceId: UUID? = nil,
        status: WorkSessionStatus? = nil,
        sessionType: WorkSessionType? = nil
    ) async throws -> [WorkSession] {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            var queryItems: [URLQueryItem] = []
            
            if let spaceId = spaceId {
                queryItems.append(URLQueryItem(name: "space_id", value: spaceId.uuidString))
            }
            if let status = status {
                queryItems.append(URLQueryItem(name: "status", value: status.rawValue))
            }
            if let sessionType = sessionType {
                queryItems.append(URLQueryItem(name: "session_type", value: sessionType.rawValue))
            }
            
            let sessions: [WorkSession] = try await networkManager.get(
                endpoint: "/work-sessions",
                queryItems: queryItems.isEmpty ? nil : queryItems
            )
            
            await updateWorkSessions(sessions)
            await clearError()
            return sessions
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Get a specific work session by ID
    /// - Parameter id: WorkSession UUID
    /// - Returns: The requested work session
    func getWorkSession(id: UUID) async throws -> WorkSession {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let session: WorkSession = try await networkManager.get(endpoint: "/work-sessions/\(id.uuidString)")
            await clearError()
            return session
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Create a new work session
    /// - Parameter session: CreateWorkSession DTO
    /// - Returns: The created work session
    func createWorkSession(_ session: CreateWorkSession) async throws -> WorkSession {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let createdSession: WorkSession = try await networkManager.post(
                endpoint: "/work-sessions",
                body: session
            )
            
            await addWorkSession(createdSession)
            await clearError()
            return createdSession
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Update an existing work session
    /// - Parameters:
    ///   - id: WorkSession UUID
    ///   - update: UpdateWorkSession DTO
    /// - Returns: The updated work session
    func updateWorkSession(id: UUID, update: UpdateWorkSession) async throws -> WorkSession {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let updatedSession: WorkSession = try await networkManager.patch(
                endpoint: "/work-sessions/\(id.uuidString)",
                body: update
            )
            
            await replaceWorkSession(updatedSession)
            await clearError()
            return updatedSession
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Delete a work session
    /// - Parameter id: WorkSession UUID
    func deleteWorkSession(id: UUID) async throws {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            try await networkManager.delete(endpoint: "/work-sessions/\(id.uuidString)")
            await removeWorkSession(id: id)
            await clearError()
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Create a new inspection session
    func createInspectionSession(
        spaceId: UUID,
        autoStart: Bool = true,
        meta: [String: Any]? = nil
    ) async throws -> WorkSession {
        let session = CreateWorkSession(
            spaceId: spaceId,
            sessionType: .inspection,
            status: autoStart ? .active : .draft,
            startedAt: autoStart ? Date() : nil,
            meta: meta
        )
        return try await createWorkSession(session)
    }
    
    /// Create a new repair session
    func createRepairSession(
        spaceId: UUID,
        autoStart: Bool = true,
        meta: [String: Any]? = nil
    ) async throws -> WorkSession {
        let session = CreateWorkSession(
            spaceId: spaceId,
            sessionType: .repair,
            status: autoStart ? .active : .draft,
            startedAt: autoStart ? Date() : nil,
            meta: meta
        )
        return try await createWorkSession(session)
    }
    
    /// Start a work session (change status to active)
    func startSession(id: UUID, version: Int64) async throws -> WorkSession {
        let update = UpdateWorkSession.start(version: version)
        return try await updateWorkSession(id: id, update: update)
    }
    
    /// Complete a work session (change status to done)
    func completeSession(id: UUID, version: Int64) async throws -> WorkSession {
        let update = UpdateWorkSession.complete(version: version)
        return try await updateWorkSession(id: id, update: update)
    }
    
    /// Archive a work session
    func archiveSession(id: UUID, version: Int64) async throws -> WorkSession {
        let update = UpdateWorkSession(
            status: .archived,
            version: version
        )
        return try await updateWorkSession(id: id, update: update)
    }
    
    /// Get active sessions for a space
    func getActiveSessions(spaceId: UUID) async throws -> [WorkSession] {
        return try await listWorkSessions(spaceId: spaceId, status: .active)
    }
    
    /// Get sessions by type
    func getSessionsByType(_ type: WorkSessionType) async throws -> [WorkSession] {
        return try await listWorkSessions(sessionType: type)
    }
    
    /// Get recent sessions (last 7 days)
    func getRecentSessions() async throws -> [WorkSession] {
        let allSessions = try await listWorkSessions()
        let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        
        return allSessions.filter { session in
            session.createdAt > oneWeekAgo
        }.sorted { $0.createdAt > $1.createdAt }
    }
    
    // MARK: - Statistics
    
    /// Calculate session statistics for a space
    func getSessionStats(spaceId: UUID) async throws -> SessionStats {
        let sessions = try await listWorkSessions(spaceId: spaceId)
        
        let totalSessions = sessions.count
        let activeSessions = sessions.filter { $0.status == .active }.count
        let completedSessions = sessions.filter { $0.status == .done }.count
        
        let inspectionCount = sessions.filter { $0.sessionType == .inspection }.count
        let repairCount = sessions.filter { $0.sessionType == .repair }.count
        
        let completedWithDuration = sessions.compactMap { $0.duration }
        let averageDuration = completedWithDuration.isEmpty ? 0 : completedWithDuration.reduce(0, +) / Double(completedWithDuration.count)
        
        return SessionStats(
            totalSessions: totalSessions,
            activeSessions: activeSessions,
            completedSessions: completedSessions,
            inspectionCount: inspectionCount,
            repairCount: repairCount,
            averageDuration: averageDuration
        )
    }
    
    // MARK: - State Management
    
    @MainActor
    private func setLoading(_ loading: Bool) {
        isLoading = loading
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
    private func updateWorkSessions(_ newSessions: [WorkSession]) {
        workSessions = newSessions
    }
    
    @MainActor
    private func addWorkSession(_ session: WorkSession) {
        if !workSessions.contains(where: { $0.id == session.id }) {
            workSessions.append(session)
        }
    }
    
    @MainActor
    private func replaceWorkSession(_ session: WorkSession) {
        if let index = workSessions.firstIndex(where: { $0.id == session.id }) {
            workSessions[index] = session
        } else {
            workSessions.append(session)
        }
    }
    
    @MainActor
    private func removeWorkSession(id: UUID) {
        workSessions.removeAll { $0.id == id }
    }
}

// MARK: - Supporting Types

/// Statistics for work sessions
struct SessionStats {
    let totalSessions: Int
    let activeSessions: Int
    let completedSessions: Int
    let inspectionCount: Int
    let repairCount: Int
    let averageDuration: TimeInterval
    
    var completionRate: Double {
        guard totalSessions > 0 else { return 0 }
        return Double(completedSessions) / Double(totalSessions)
    }
    
    var averageDurationFormatted: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: averageDuration) ?? "0m"
    }
}