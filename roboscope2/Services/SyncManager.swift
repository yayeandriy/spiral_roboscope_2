//
//  SyncManager.swift
//  roboscope2
//
//  Background sync manager for offline support and conflict resolution
//

import Foundation
import Combine
import BackgroundTasks

/// Manager for background synchronization and conflict resolution
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    // MARK: - Published Properties
    
    @Published private(set) var syncStatus: BackgroundSyncStatus = .idle
    @Published private(set) var pendingChanges: Int = 0
    @Published var error: String? = nil
    
    // MARK: - Dependencies
    
    private let spaceService = SpaceService.shared
    private let workSessionService = WorkSessionService.shared
    private let markerService = MarkerService.shared
    
    // MARK: - Configuration
    
    private let config: BackgroundSyncConfig
    private let backgroundTaskId = "com.roboscope.sync"
    
    // MARK: - Private Properties
    
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isBackgroundSyncRegistered = false
    
    // Pending operations queue
    private var pendingSpaceOperations: [PendingOperation] = []
    private var pendingSessionOperations: [PendingOperation] = []
    private var pendingMarkerOperations: [PendingOperation] = []
    
    private let operationsQueue = DispatchQueue(label: "com.roboscope.sync.operations", qos: .utility)
    
    init(config: BackgroundSyncConfig = .default) {
        self.config = config
        setupAppStateObservers()
    }
    
    deinit {
        stopAutoSync()
    }
    
    // MARK: - Public Methods
    
    /// Start automatic background synchronization
    func startAutoSync() {
        guard config.enabled else { return }
        
        stopAutoSync()
        
        syncTimer = Timer.scheduledTimer(withTimeInterval: config.interval, repeats: true) { [weak self] _ in
            Task {
                await self?.performBackgroundSync()
            }
        }
        
        registerBackgroundTasks()
        
        // Perform initial sync
        Task {
            await performBackgroundSync()
        }
    }
    
    /// Stop automatic synchronization
    func stopAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    /// Manually trigger a sync operation
    func syncNow() async {
        await performBackgroundSync()
    }
    
    /// Add a pending operation to the sync queue
    func addPendingOperation(_ operation: PendingOperation) {
        operationsQueue.async { [weak self] in
            switch operation.resourceType {
            case .space:
                self?.pendingSpaceOperations.append(operation)
            case .workSession:
                self?.pendingSessionOperations.append(operation)
            case .marker:
                self?.pendingMarkerOperations.append(operation)
            }
            
            Task {
                await self?.updatePendingChangesCount()
            }
        }
    }
    
    /// Clear all pending operations
    func clearPendingOperations() {
        operationsQueue.async { [weak self] in
            self?.pendingSpaceOperations.removeAll()
            self?.pendingSessionOperations.removeAll()
            self?.pendingMarkerOperations.removeAll()
            
            Task {
                await self?.updatePendingChangesCount()
            }
        }
    }
    
    /// Register background tasks for iOS background sync
    func registerBackgroundTasks() {
        // Avoid registering in unit test sessions to prevent runtime instability
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        guard !isBackgroundSyncRegistered else { return }
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleBackgroundSync(task as! BGAppRefreshTask)
        }
        
        isBackgroundSyncRegistered = true
    }
    
    /// Schedule background sync task
    func scheduleBackgroundSync() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: config.interval)
        
        try? BGTaskScheduler.shared.submit(request)
    }
    
    // MARK: - Sync Operations
    
    private func performBackgroundSync() async {
        await setSyncStatus(.syncing)
        
        do {
            // Sync pending operations first
            try await syncPendingOperations()
            
            // Then pull latest data
            try await pullLatestData()
            
            await setSyncStatus(.success(lastSync: Date()))
            await clearError()
            
        } catch {
            await setSyncStatus(.error(error, lastAttempt: Date()))
            await setError("Sync failed: \(error.localizedDescription)")
        }
    }
    
    private func syncPendingOperations() async throws {
        let operations = await getAllPendingOperations()
        
        for operation in operations {
            do {
                try await executePendingOperation(operation)
                await removePendingOperation(operation)
            } catch {
                // Handle conflict resolution
                if let apiError = error as? APIError,
                   case .conflict = apiError {
                    try await handleSyncConflict(operation: operation, error: apiError)
                } else {
                    throw error
                }
            }
        }
    }
    
    private func pullLatestData() async throws {
        // Pull latest spaces, sessions, and markers
        // This refreshes the local cache with server data
        
        async let spaces = spaceService.listSpaces()
        async let sessions = workSessionService.listWorkSessions()
        async let markers = markerService.listMarkers()
        
        _ = try await (spaces, sessions, markers)
    }
    
    private func executePendingOperation(_ operation: PendingOperation) async throws {
        switch (operation.resourceType, operation.operationType) {
        case (.space, .create):
            if let data = operation.data as? CreateSpace {
                _ = try await spaceService.createSpace(data)
            }
            
        case (.space, .update):
            if let data = operation.data as? (UUID, UpdateSpace) {
                _ = try await spaceService.updateSpace(id: data.0, update: data.1)
            }
            
        case (.space, .delete):
            if let id = operation.resourceId {
                try await spaceService.deleteSpace(id: id)
            }
            
        case (.workSession, .create):
            if let data = operation.data as? CreateWorkSession {
                _ = try await workSessionService.createWorkSession(data)
            }
            
        case (.workSession, .update):
            if let data = operation.data as? (UUID, UpdateWorkSession) {
                _ = try await workSessionService.updateWorkSession(id: data.0, update: data.1)
            }
            
        case (.workSession, .delete):
            if let id = operation.resourceId {
                try await workSessionService.deleteWorkSession(id: id)
            }
            
        case (.marker, .create):
            if let data = operation.data as? CreateMarker {
                _ = try await markerService.createMarker(data)
            }
            
        case (.marker, .update):
            if let data = operation.data as? (UUID, UpdateMarker) {
                _ = try await markerService.updateMarker(id: data.0, update: data.1)
            }
            
        case (.marker, .delete):
            if let id = operation.resourceId {
                try await markerService.deleteMarker(id: id)
            }
        }
    }
    
    private func handleSyncConflict(operation: PendingOperation, error: APIError) async throws {
        // For now, implement server-wins strategy
        // In a full implementation, you could present options to the user
        
        switch operation.conflictResolution {
        case .serverWins:
            // Discard local changes, pull server version
            try await pullLatestData()
            
        case .clientWins:
            // Force push local changes (dangerous!)
            // This would require special API endpoints or version override
            throw error
            
        case .merge:
            // Custom merge logic would go here
            throw APIError.conflict(message: "Merge conflict resolution not implemented")
            
        case .prompt:
            // This would trigger a UI prompt for user decision
            throw SyncConflict(
                resourceType: operation.resourceType.rawValue,
                resourceId: operation.resourceId ?? UUID(),
                expectedVersion: operation.expectedVersion ?? 0,
                actualVersion: 0 // Would be extracted from error
            )
        }
    }
    
    // MARK: - Background Task Handling
    
    private func handleBackgroundSync(_ task: BGAppRefreshTask) {
        scheduleBackgroundSync() // Schedule the next background sync
        
        Task {
            await performBackgroundSync()
            task.setTaskCompleted(success: true)
        }
        
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
    }
    
    // MARK: - App State Observers
    
    private func setupAppStateObservers() {
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task {
                    await self?.performBackgroundSync()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.scheduleBackgroundSync()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Pending Operations Management
    
    private func getAllPendingOperations() async -> [PendingOperation] {
        return await withCheckedContinuation { continuation in
            operationsQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                
                let allOperations = self.pendingSpaceOperations +
                                  self.pendingSessionOperations +
                                  self.pendingMarkerOperations
                
                continuation.resume(returning: allOperations.sorted { $0.timestamp < $1.timestamp })
            }
        }
    }
    
    private func removePendingOperation(_ operation: PendingOperation) async {
        await withCheckedContinuation { continuation in
            operationsQueue.async { [weak self] in
                switch operation.resourceType {
                case .space:
                    self?.pendingSpaceOperations.removeAll { $0.id == operation.id }
                case .workSession:
                    self?.pendingSessionOperations.removeAll { $0.id == operation.id }
                case .marker:
                    self?.pendingMarkerOperations.removeAll { $0.id == operation.id }
                }
                
                Task {
                    await self?.updatePendingChangesCount()
                }
                
                continuation.resume()
            }
        }
    }
    
    // MARK: - State Management
    
    @MainActor
    private func setSyncStatus(_ status: BackgroundSyncStatus) {
        syncStatus = status
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
    private func updatePendingChangesCount() {
        let total = pendingSpaceOperations.count +
                   pendingSessionOperations.count +
                   pendingMarkerOperations.count
        pendingChanges = total
    }
}

// MARK: - Supporting Types

/// Represents a pending operation to be synced
struct PendingOperation {
    let id = UUID()
    let resourceType: ResourceType
    let operationType: OperationType
    let resourceId: UUID?
    let data: Any?
    let timestamp: Date
    let expectedVersion: Int64?
    let conflictResolution: ConflictResolutionStrategy
    
    enum ResourceType: String {
        case space
        case workSession
        case marker
    }
    
    enum OperationType {
        case create
        case update
        case delete
    }
}

// MARK: - UIApplication Import

#if canImport(UIKit)
import UIKit
#endif