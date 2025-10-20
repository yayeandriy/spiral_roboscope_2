# Real-time Features Guide - iOS Swift

Complete guide for implementing real-time presence tracking and collaborative locking in your iOS app.

## Table of Contents

1. [Overview](#overview)
2. [Presence Tracking](#presence-tracking)
3. [Distributed Locking](#distributed-locking)
4. [Real-time Sync](#real-time-sync)
5. [Conflict Resolution](#conflict-resolution)
6. [Background Updates](#background-updates)

---

## Overview

The Roboscope 2 API provides Redis-backed real-time features:
- **Presence tracking** - Know who's viewing each work session
- **Distributed locks** - Prevent concurrent edits
- **Optimistic concurrency** - Handle version conflicts gracefully
- **TTL-based expiry** - Auto-cleanup of stale locks

---

## Presence Tracking

### Models/Presence.swift

```swift
import Foundation

struct PresenceInfo: Codable, Identifiable {
    let userId: String
    let timestamp: Date
    
    var id: String { userId }
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case timestamp
    }
}

struct PresenceHeartbeat: Codable {
    let userId: String
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

struct PresenceListResponse: Codable {
    let users: [String]
}
```

### Services/PresenceService.swift

```swift
import Foundation
import Combine

class PresenceService {
    static let shared = PresenceService()
    private let networkManager = NetworkManager.shared
    
    private var heartbeatTimer: Timer?
    private var currentSessionId: UUID?
    private let userId: String
    
    // Publishers for real-time updates
    @Published private(set) var activeUsers: [String] = []
    
    private init() {
        // Generate or retrieve persistent user ID
        if let saved = UserDefaults.standard.string(forKey: "userId") {
            self.userId = saved
        } else {
            self.userId = UUID().uuidString
            UserDefaults.standard.set(self.userId, forKey: "userId")
        }
    }
    
    // MARK: - Presence Operations
    
    func joinSession(_ sessionId: UUID) async throws {
        currentSessionId = sessionId
        
        // Send initial heartbeat
        try await sendHeartbeat(sessionId: sessionId)
        
        // Start periodic heartbeats (every 10 seconds)
        await MainActor.run {
            heartbeatTimer?.invalidate()
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                Task {
                    try? await self?.sendHeartbeat(sessionId: sessionId)
                }
            }
        }
        
        // Get initial user list
        try await updateUserList(sessionId: sessionId)
    }
    
    func leaveSession(_ sessionId: UUID) async throws {
        currentSessionId = nil
        
        // Stop heartbeats
        await MainActor.run {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
        
        // Remove presence
        let _: EmptyResponse = try await networkManager.request(
            endpoint: "/presence/\(sessionId.uuidString)/\(userId)",
            method: .delete
        )
        
        activeUsers = []
    }
    
    private func sendHeartbeat(sessionId: UUID) async throws {
        let heartbeat = PresenceHeartbeat(userId: userId)
        let _: EmptyResponse = try await networkManager.requestJSON(
            endpoint: "/presence/\(sessionId.uuidString)",
            method: .post,
            body: heartbeat
        )
    }
    
    func updateUserList(sessionId: UUID) async throws {
        let response: PresenceListResponse = try await networkManager.request(
            endpoint: "/presence/\(sessionId.uuidString)"
        )
        
        await MainActor.run {
            activeUsers = response.users
        }
    }
    
    // MARK: - Auto Refresh
    
    func startAutoRefresh(sessionId: UUID, interval: TimeInterval = 5.0) {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                try? await self?.updateUserList(sessionId: sessionId)
            }
        }
    }
}
```

### PresenceView.swift

```swift
import SwiftUI

struct PresenceIndicator: View {
    @StateObject private var presenceService = PresenceService.shared
    let sessionId: UUID
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2.fill")
                .foregroundColor(.green)
            
            Text("\(presenceService.activeUsers.count)")
                .font(.caption)
                .fontWeight(.semibold)
            
            if presenceService.activeUsers.count > 1 {
                Text("users active")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("user active")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .task {
            do {
                try await presenceService.joinSession(sessionId)
                presenceService.startAutoRefresh(sessionId: sessionId)
            } catch {
                print("Failed to join session: \(error)")
            }
        }
        .onDisappear {
            Task {
                try? await presenceService.leaveSession(sessionId)
            }
        }
    }
}

struct ActiveUsersSheet: View {
    @StateObject private var presenceService = PresenceService.shared
    let sessionId: UUID
    
    var body: some View {
        NavigationView {
            List(presenceService.activeUsers, id: \.self) { userId in
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    
                    Text(userId)
                        .font(.body)
                    
                    Spacer()
                    
                    Text("Active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Active Users")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                try? await presenceService.updateUserList(sessionId: sessionId)
            }
        }
    }
}
```

---

## Distributed Locking

### Models/Lock.swift

```swift
import Foundation

struct LockRequest: Codable {
    let ttlSeconds: Int
    
    enum CodingKeys: String, CodingKey {
        case ttlSeconds = "ttl_seconds"
    }
}

struct LockResponse: Codable {
    let acquired: Bool
    let token: String?
}

struct LockStatus: Codable {
    let locked: Bool
}

struct ExtendLockRequest: Codable {
    let token: String
    let ttlSeconds: Int
    
    enum CodingKeys: String, CodingKey {
        case token
        case ttlSeconds = "ttl_seconds"
    }
}

struct UnlockRequest: Codable {
    let token: String
}

struct UnlockResponse: Codable {
    let released: Bool
}
```

### Services/LockService.swift

```swift
import Foundation
import Combine

class LockService {
    static let shared = LockService()
    private let networkManager = NetworkManager.shared
    
    private var lockTokens: [UUID: String] = [:]
    private var lockExtensionTimers: [UUID: Timer] = [:]
    
    private init() {}
    
    // MARK: - Lock Operations
    
    func acquireLock(sessionId: UUID, ttl: Int = 30) async throws -> Bool {
        let request = LockRequest(ttlSeconds: ttl)
        
        let response: LockResponse = try await networkManager.requestJSON(
            endpoint: "/locks/\(sessionId.uuidString)",
            method: .post,
            body: request
        )
        
        if response.acquired, let token = response.token {
            lockTokens[sessionId] = token
            
            // Start auto-extension (refresh before expiry)
            startLockExtension(sessionId: sessionId, ttl: ttl)
            
            return true
        }
        
        return false
    }
    
    func releaseLock(sessionId: UUID) async throws -> Bool {
        guard let token = lockTokens[sessionId] else {
            return false
        }
        
        // Stop auto-extension
        stopLockExtension(sessionId: sessionId)
        
        let request = UnlockRequest(token: token)
        
        let response: UnlockResponse = try await networkManager.requestJSON(
            endpoint: "/locks/\(sessionId.uuidString)",
            method: .delete,
            body: request
        )
        
        if response.released {
            lockTokens.removeValue(forKey: sessionId)
            return true
        }
        
        return false
    }
    
    func checkLockStatus(sessionId: UUID) async throws -> Bool {
        let status: LockStatus = try await networkManager.request(
            endpoint: "/locks/\(sessionId.uuidString)"
        )
        
        return status.locked
    }
    
    func extendLock(sessionId: UUID, ttl: Int = 30) async throws -> Bool {
        guard let token = lockTokens[sessionId] else {
            return false
        }
        
        let request = ExtendLockRequest(token: token, ttlSeconds: ttl)
        
        let response: LockResponse = try await networkManager.requestJSON(
            endpoint: "/locks/\(sessionId.uuidString)/extend",
            method: .post,
            body: request
        )
        
        return response.acquired
    }
    
    // MARK: - Auto Extension
    
    private func startLockExtension(sessionId: UUID, ttl: Int) {
        stopLockExtension(sessionId: sessionId)
        
        // Extend lock at 50% of TTL to ensure it doesn't expire
        let interval = TimeInterval(ttl) * 0.5
        
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                try? await self?.extendLock(sessionId: sessionId, ttl: ttl)
            }
        }
        
        lockExtensionTimers[sessionId] = timer
    }
    
    private func stopLockExtension(sessionId: UUID) {
        lockExtensionTimers[sessionId]?.invalidate()
        lockExtensionTimers.removeValue(forKey: sessionId)
    }
    
    // MARK: - Cleanup
    
    func releaseAllLocks() async {
        for sessionId in lockTokens.keys {
            try? await releaseLock(sessionId: sessionId)
        }
    }
}
```

### LockableEditView.swift

```swift
import SwiftUI

struct LockableWorkSessionView: View {
    let workSession: WorkSession
    
    @State private var isLocked = false
    @State private var hasLock = false
    @State private var isEditing = false
    @State private var showError: String?
    
    var body: some View {
        VStack {
            // Lock status indicator
            HStack {
                if hasLock {
                    Label("You have edit lock", systemImage: "lock.open.fill")
                        .foregroundColor(.green)
                } else if isLocked {
                    Label("Locked by another user", systemImage: "lock.fill")
                        .foregroundColor(.orange)
                } else {
                    Label("Unlocked", systemImage: "lock.open")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(hasLock ? "Release Lock" : "Acquire Lock") {
                    Task {
                        await toggleLock()
                    }
                }
                .disabled(isLocked && !hasLock)
            }
            .padding()
            .background(.ultraThinMaterial)
            
            // Edit form (only enabled if we have lock)
            Form {
                Section("Session Details") {
                    TextField("Label", text: .constant(workSession.status.rawValue))
                        .disabled(!hasLock)
                }
            }
            .disabled(!hasLock)
        }
        .navigationTitle("Edit Session")
        .task {
            await checkLockStatus()
        }
        .onDisappear {
            if hasLock {
                Task {
                    try? await LockService.shared.releaseLock(sessionId: workSession.id)
                }
            }
        }
        .alert("Error", isPresented: .constant(showError != nil)) {
            Button("OK") {
                showError = nil
            }
        } message: {
            Text(showError ?? "")
        }
    }
    
    func checkLockStatus() async {
        do {
            isLocked = try await LockService.shared.checkLockStatus(sessionId: workSession.id)
        } catch {
            showError = "Failed to check lock status: \(error.localizedDescription)"
        }
    }
    
    func toggleLock() async {
        do {
            if hasLock {
                let released = try await LockService.shared.releaseLock(sessionId: workSession.id)
                if released {
                    hasLock = false
                    isLocked = false
                }
            } else {
                let acquired = try await LockService.shared.acquireLock(sessionId: workSession.id, ttl: 60)
                if acquired {
                    hasLock = true
                    isLocked = true
                } else {
                    showError = "Failed to acquire lock. Another user may be editing."
                }
            }
        } catch {
            showError = "Lock operation failed: \(error.localizedDescription)"
        }
    }
}
```

---

## Real-time Sync

### SyncManager.swift

```swift
import Foundation
import Combine

class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isSyncing = false
    
    private var syncTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {}
    
    // MARK: - Auto Sync
    
    func startAutoSync(interval: TimeInterval = 30.0, workSessionId: UUID) {
        stopAutoSync()
        
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task {
                await self?.syncMarkers(workSessionId: workSessionId)
            }
        }
    }
    
    func stopAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    // MARK: - Sync Operations
    
    func syncMarkers(workSessionId: UUID) async {
        guard !isSyncing else { return }
        
        await MainActor.run {
            isSyncing = true
        }
        
        defer {
            Task { @MainActor in
                isSyncing = false
                lastSyncDate = Date()
            }
        }
        
        do {
            let markers = try await MarkerService.shared.listMarkers(workSessionId: workSessionId)
            
            // Post notification for UI to update
            NotificationCenter.default.post(
                name: .markersDidSync,
                object: nil,
                userInfo: ["markers": markers]
            )
        } catch {
            print("Sync failed: \(error)")
        }
    }
    
    func forceSyncNow(workSessionId: UUID) async {
        await syncMarkers(workSessionId: workSessionId)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let markersDidSync = Notification.Name("markersDidSync")
}
```

### SyncIndicatorView.swift

```swift
import SwiftUI

struct SyncIndicatorView: View {
    @StateObject private var syncManager = SyncManager.shared
    let workSessionId: UUID
    
    var body: some View {
        HStack(spacing: 8) {
            if syncManager.isSyncing {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Syncing...")
                    .font(.caption)
            } else if let lastSync = syncManager.lastSyncDate {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Synced \(timeAgo(lastSync))")
                    .font(.caption)
            }
            
            Button {
                Task {
                    await syncManager.forceSyncNow(workSessionId: workSessionId)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(syncManager.isSyncing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .task {
            syncManager.startAutoSync(workSessionId: workSessionId)
        }
        .onDisappear {
            syncManager.stopAutoSync()
        }
    }
    
    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 {
            return "\(seconds)s ago"
        } else {
            return "\(seconds / 60)m ago"
        }
    }
}
```

---

## Conflict Resolution

### OptimisticConcurrencyHandler.swift

```swift
import Foundation

class OptimisticConcurrencyHandler {
    
    static func handleUpdate<T: Decodable>(
        currentVersion: Int64,
        update: UpdateWorkSession,
        updateOperation: (UpdateWorkSession) async throws -> T
    ) async throws -> T {
        var attemptUpdate = update
        attemptUpdate.version = currentVersion
        
        do {
            return try await updateOperation(attemptUpdate)
        } catch let error as APIError {
            switch error {
            case .conflict:
                // Version conflict - need to refresh and retry
                throw ConflictError.versionMismatch
            default:
                throw error
            }
        }
    }
    
    static func retryWithRefresh<T: Decodable>(
        resourceId: UUID,
        maxRetries: Int = 3,
        refreshOperation: (UUID) async throws -> WorkSession,
        updateOperation: (WorkSession, UpdateWorkSession) async throws -> T,
        createUpdate: (WorkSession) -> UpdateWorkSession
    ) async throws -> T {
        var attempts = 0
        
        while attempts < maxRetries {
            do {
                // Refresh to get latest version
                let latest = try await refreshOperation(resourceId)
                let update = createUpdate(latest)
                
                return try await handleUpdate(
                    currentVersion: latest.version,
                    update: update,
                    updateOperation: { try await updateOperation(latest, $0) }
                )
            } catch ConflictError.versionMismatch {
                attempts += 1
                if attempts >= maxRetries {
                    throw ConflictError.maxRetriesExceeded
                }
                // Wait before retry (exponential backoff)
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempts)) * 100_000_000))
            }
        }
        
        throw ConflictError.maxRetriesExceeded
    }
}

enum ConflictError: Error, LocalizedError {
    case versionMismatch
    case maxRetriesExceeded
    
    var errorDescription: String? {
        switch self {
        case .versionMismatch:
            return "Resource was modified by another user"
        case .maxRetriesExceeded:
            return "Failed to update after multiple retries"
        }
    }
}
```

### Usage Example

```swift
// Update work session with automatic retry on conflict
func updateSessionStatus(sessionId: UUID, newStatus: WorkSessionStatus) async throws {
    try await OptimisticConcurrencyHandler.retryWithRefresh(
        resourceId: sessionId,
        refreshOperation: { id in
            try await WorkSessionService.shared.getWorkSession(id: id)
        },
        updateOperation: { session, update in
            try await WorkSessionService.shared.updateWorkSession(id: session.id, update: update)
        },
        createUpdate: { session in
            UpdateWorkSession(
                spaceId: nil,
                sessionType: nil,
                status: newStatus,
                startedAt: nil,
                completedAt: nil,
                version: session.version
            )
        }
    )
}
```

---

## Background Updates

### BackgroundSyncManager.swift

```swift
import Foundation
import BackgroundTasks

class BackgroundSyncManager {
    static let shared = BackgroundSyncManager()
    
    private let taskIdentifier = "com.yourapp.roboscope.sync"
    
    private init() {}
    
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundSync(task: task as! BGAppRefreshTask)
        }
    }
    
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule background sync: \(error)")
        }
    }
    
    private func handleBackgroundSync(task: BGAppRefreshTask) {
        // Schedule next sync
        scheduleBackgroundSync()
        
        // Perform sync
        Task {
            // Sync active sessions
            // Update markers
            // Refresh presence
            
            task.setTaskCompleted(success: true)
        }
    }
}
```

---

## Next Steps

- [SwiftUI Views Guide](./IOS_SWIFTUI_VIEWS.md) - Pre-built UI components
- [Code Examples](./IOS_CODE_EXAMPLES.md) - Complete working examples
- [Testing Guide](./IOS_TESTING_GUIDE.md) - Unit & integration tests

