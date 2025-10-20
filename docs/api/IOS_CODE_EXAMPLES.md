# Complete Code Examples - iOS Swift

Full working examples demonstrating Roboscope 2 API integration in iOS apps.

## Table of Contents

1. [Complete App Structure](#complete-app-structure)
2. [Space Management Flow](#space-management-flow)
3. [AR Marker Session](#ar-marker-session)
4. [Collaborative Editing](#collaborative-editing)
5. [Offline Support](#offline-support)
6. [Advanced Examples](#advanced-examples)

---

## Complete App Structure

### RoboscopeApp.swift

```swift
import SwiftUI

@main
struct RoboscopeApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        // Configure API environment
        APIConfiguration.shared.environment = .production
        
        // Register background tasks
        BackgroundSyncManager.shared.registerBackgroundTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    BackgroundSyncManager.shared.scheduleBackgroundSync()
                }
        }
    }
}

class AppState: ObservableObject {
    @Published var selectedSpace: Space?
    @Published var currentWorkSession: WorkSession?
    @Published var isAuthenticated = true // Implement auth as needed
    
    static let shared = AppState()
}
```

### ContentView.swift

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            SpaceListView()
                .tabItem {
                    Label("Spaces", systemImage: "cube")
                }
                .tag(0)
            
            WorkSessionListView()
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet")
                }
                .tag(1)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
    }
}
```

---

## Space Management Flow

### Complete Space Workflow

```swift
import SwiftUI

struct SpaceWorkflowView: View {
    @StateObject private var viewModel = SpaceWorkflowViewModel()
    @State private var showARSession = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Step 1: Select or Create Space
                    stepCard(
                        number: 1,
                        title: "Select Space",
                        description: "Choose a space or create a new one"
                    ) {
                        if let space = viewModel.selectedSpace {
                            selectedSpaceView(space)
                        } else {
                            spaceSelectionView
                        }
                    }
                    
                    // Step 2: Create Work Session
                    if viewModel.selectedSpace != nil {
                        stepCard(
                            number: 2,
                            title: "Work Session",
                            description: "Create or select a work session"
                        ) {
                            if let session = viewModel.currentSession {
                                selectedSessionView(session)
                            } else {
                                Button("Create Work Session") {
                                    Task {
                                        await viewModel.createWorkSession()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    
                    // Step 3: Start AR Session
                    if viewModel.currentSession != nil {
                        stepCard(
                            number: 3,
                            title: "AR Markers",
                            description: "Place and manage AR markers"
                        ) {
                            Button("Launch AR View") {
                                showARSession = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Roboscope Workflow")
            .fullScreenCover(isPresented: $showARSession) {
                if let space = viewModel.selectedSpace,
                   let session = viewModel.currentSession {
                    ARSessionView(
                        space: .constant(space),
                        workSession: .constant(session),
                        markers: .constant([])
                    )
                }
            }
        }
    }
    
    private func stepCard<Content: View>(
        number: Int,
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Text("\(number)")
                            .foregroundColor(.white)
                            .fontWeight(.bold)
                    }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            content()
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
        }
        .padding()
        .background(Color.white)
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private var spaceSelectionView: some View {
        VStack {
            Menu {
                ForEach(viewModel.availableSpaces) { space in
                    Button(space.name) {
                        viewModel.selectedSpace = space
                    }
                }
                
                Divider()
                
                Button("Create New Space") {
                    // Show create sheet
                }
            } label: {
                Label("Select Space", systemImage: "cube")
            }
            .buttonStyle(.bordered)
        }
    }
    
    private func selectedSpaceView(_ space: Space) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(space.name)
                    .font(.headline)
                Text(space.key)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Change") {
                viewModel.selectedSpace = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    private func selectedSessionView(_ session: WorkSession) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.sessionType.rawValue.capitalized)
                    .font(.headline)
                Text("Status: \(session.status.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Change") {
                viewModel.currentSession = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

@MainActor
class SpaceWorkflowViewModel: ObservableObject {
    @Published var availableSpaces: [Space] = []
    @Published var selectedSpace: Space?
    @Published var currentSession: WorkSession?
    
    init() {
        Task {
            await loadSpaces()
        }
    }
    
    func loadSpaces() async {
        do {
            availableSpaces = try await SpaceService.shared.listSpaces()
        } catch {
            print("Failed to load spaces: \(error)")
        }
    }
    
    func createWorkSession() async {
        guard let space = selectedSpace else { return }
        
        let create = CreateWorkSession(
            spaceId: space.id,
            sessionType: .inspection,
            status: .active,
            startedAt: Date(),
            completedAt: nil
        )
        
        do {
            currentSession = try await WorkSessionService.shared.createWorkSession(create)
        } catch {
            print("Failed to create session: \(error)")
        }
    }
}
```

---

## AR Marker Session

### Complete AR Workflow

```swift
import SwiftUI
import ARKit
import RealityKit

struct ARMarkerSessionView: View {
    let workSession: WorkSession
    
    @StateObject private var viewModel: ARMarkerSessionViewModel
    @State private var showMarkerList = false
    @State private var showControls = true
    
    init(workSession: WorkSession) {
        self.workSession = workSession
        _viewModel = StateObject(wrappedValue: ARMarkerSessionViewModel(workSession: workSession))
    }
    
    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(
                space: .constant(nil),
                workSession: .constant(workSession),
                markers: $viewModel.markers
            )
            .ignoresSafeArea()
            
            // Overlay UI
            VStack {
                // Top bar
                topBar
                
                Spacer()
                
                // Bottom controls
                if showControls {
                    bottomControls
                }
            }
        }
        .task {
            await viewModel.initialize()
        }
        .onDisappear {
            Task {
                await viewModel.cleanup()
            }
        }
        .sheet(isPresented: $showMarkerList) {
            MarkerListSheet(markers: viewModel.markers, onDelete: { marker in
                Task {
                    await viewModel.deleteMarker(marker)
                }
            })
        }
    }
    
    private var topBar: some View {
        HStack {
            Button {
                // Dismiss
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                PresenceIndicator(sessionId: workSession.id)
                SyncIndicatorView(workSessionId: workSession.id)
            }
        }
        .padding()
    }
    
    private var bottomControls: some View {
        VStack(spacing: 16) {
            // Marker count
            HStack {
                Image(systemName: "map.fill")
                Text("\(viewModel.markers.count) markers")
                    .font(.headline)
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            
            // Action buttons
            HStack(spacing: 16) {
                Button {
                    viewModel.placementMode.toggle()
                } label: {
                    VStack {
                        Image(systemName: viewModel.placementMode ? "hand.tap.fill" : "hand.tap")
                            .font(.title2)
                        Text(viewModel.placementMode ? "Placing" : "Place")
                            .font(.caption)
                    }
                    .frame(width: 80, height: 80)
                    .background(viewModel.placementMode ? Color.accentColor : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                
                Button {
                    showMarkerList = true
                } label: {
                    VStack {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                        Text("List")
                            .font(.caption)
                    }
                    .frame(width: 80, height: 80)
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                
                Button {
                    Task {
                        await viewModel.syncMarkers()
                    }
                } label: {
                    VStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title2)
                        Text("Sync")
                            .font(.caption)
                    }
                    .frame(width: 80, height: 80)
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
            }
        }
        .padding()
    }
}

@MainActor
class ARMarkerSessionViewModel: ObservableObject {
    @Published var markers: [Marker] = []
    @Published var placementMode = false
    @Published var isLoading = false
    
    let workSession: WorkSession
    private let markerService = MarkerService.shared
    private let presenceService = PresenceService.shared
    private let syncManager = SyncManager.shared
    
    init(workSession: WorkSession) {
        self.workSession = workSession
    }
    
    func initialize() async {
        // Join presence
        try? await presenceService.joinSession(workSession.id)
        
        // Load markers
        await loadMarkers()
        
        // Start auto sync
        syncManager.startAutoSync(workSessionId: workSession.id)
    }
    
    func cleanup() async {
        // Leave presence
        try? await presenceService.leaveSession(workSession.id)
        
        // Stop sync
        syncManager.stopAutoSync()
    }
    
    func loadMarkers() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            markers = try await markerService.listMarkers(workSessionId: workSession.id)
        } catch {
            print("Failed to load markers: \(error)")
        }
    }
    
    func syncMarkers() async {
        await syncManager.forceSyncNow(workSessionId: workSession.id)
        await loadMarkers()
    }
    
    func deleteMarker(_ marker: Marker) async {
        do {
            try await markerService.deleteMarker(id: marker.id)
            markers.removeAll { $0.id == marker.id }
        } catch {
            print("Failed to delete marker: \(error)")
        }
    }
}

struct MarkerListSheet: View {
    let markers: [Marker]
    let onDelete: (Marker) -> Void
    
    var body: some View {
        NavigationView {
            List {
                ForEach(markers) { marker in
                    VStack(alignment: .leading) {
                        Text(marker.label ?? "Unnamed Marker")
                            .font(.headline)
                        Text("Version: \(marker.version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            onDelete(marker)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Markers (\(markers.count))")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

---

## Collaborative Editing

### Multi-User Session Editor

```swift
import SwiftUI

struct CollaborativeSessionEditor: View {
    let workSession: WorkSession
    
    @StateObject private var viewModel: CollaborativeEditorViewModel
    @State private var editedStatus: WorkSessionStatus
    @State private var showConflictAlert = false
    
    init(workSession: WorkSession) {
        self.workSession = workSession
        _viewModel = StateObject(wrappedValue: CollaborativeEditorViewModel(workSession: workSession))
        _editedStatus = State(initialValue: workSession.status)
    }
    
    var body: some View {
        Form {
            Section {
                HStack {
                    PresenceIndicator(sessionId: workSession.id)
                    Spacer()
                    lockIndicator
                }
            }
            
            Section("Session Details") {
                Picker("Status", selection: $editedStatus) {
                    ForEach([WorkSessionStatus.draft, .active, .done, .archived], id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(status)
                    }
                }
                .disabled(!viewModel.hasLock)
                
                if let startedAt = workSession.startedAt {
                    DatePicker("Started", selection: .constant(startedAt), displayedComponents: [.date, .hourAndMinute])
                        .disabled(true)
                }
            }
            
            Section {
                if viewModel.hasLock {
                    Button("Save Changes") {
                        Task {
                            await viewModel.saveChanges(newStatus: editedStatus)
                        }
                    }
                    .disabled(editedStatus == workSession.status || viewModel.isSaving)
                    
                    Button("Release Lock", role: .destructive) {
                        Task {
                            await viewModel.releaseLock()
                        }
                    }
                } else {
                    Button("Acquire Edit Lock") {
                        Task {
                            await viewModel.acquireLock()
                        }
                    }
                    .disabled(viewModel.isLocked)
                }
            }
        }
        .navigationTitle("Edit Session")
        .task {
            await viewModel.initialize()
        }
        .onDisappear {
            Task {
                await viewModel.cleanup()
            }
        }
        .alert("Version Conflict", isPresented: $showConflictAlert) {
            Button("Reload") {
                Task {
                    await viewModel.refreshSession()
                    editedStatus = workSession.status
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This session was modified by another user. Please reload and try again.")
        }
        .overlay {
            if viewModel.isSaving {
                ProgressView("Saving...")
            }
        }
    }
    
    @ViewBuilder
    private var lockIndicator: some View {
        if viewModel.hasLock {
            Label("You have lock", systemImage: "lock.open.fill")
                .foregroundColor(.green)
                .font(.caption)
        } else if viewModel.isLocked {
            Label("Locked", systemImage: "lock.fill")
                .foregroundColor(.orange)
                .font(.caption)
        } else {
            Label("Unlocked", systemImage: "lock.open")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
}

@MainActor
class CollaborativeEditorViewModel: ObservableObject {
    @Published var hasLock = false
    @Published var isLocked = false
    @Published var isSaving = false
    @Published var activeUsers: [String] = []
    
    private(set) var workSession: WorkSession
    private let lockService = LockService.shared
    private let sessionService = WorkSessionService.shared
    private let presenceService = PresenceService.shared
    
    init(workSession: WorkSession) {
        self.workSession = workSession
    }
    
    func initialize() async {
        // Join presence
        try? await presenceService.joinSession(workSession.id)
        
        // Check lock status
        await checkLockStatus()
        
        // Start presence updates
        presenceService.startAutoRefresh(sessionId: workSession.id)
    }
    
    func cleanup() async {
        // Release lock if we have it
        if hasLock {
            try? await lockService.releaseLock(sessionId: workSession.id)
        }
        
        // Leave presence
        try? await presenceService.leaveSession(workSession.id)
    }
    
    func checkLockStatus() async {
        do {
            isLocked = try await lockService.checkLockStatus(sessionId: workSession.id)
        } catch {
            print("Failed to check lock: \(error)")
        }
    }
    
    func acquireLock() async {
        do {
            hasLock = try await lockService.acquireLock(sessionId: workSession.id, ttl: 60)
            if hasLock {
                isLocked = true
            }
        } catch {
            print("Failed to acquire lock: \(error)")
        }
    }
    
    func releaseLock() async {
        do {
            let released = try await lockService.releaseLock(sessionId: workSession.id)
            if released {
                hasLock = false
                isLocked = false
            }
        } catch {
            print("Failed to release lock: \(error)")
        }
    }
    
    func saveChanges(newStatus: WorkSessionStatus) async {
        guard hasLock else { return }
        
        isSaving = true
        defer { isSaving = false }
        
        let update = UpdateWorkSession(
            spaceId: nil,
            sessionType: nil,
            status: newStatus,
            startedAt: nil,
            completedAt: newStatus == .done ? Date() : nil,
            version: workSession.version
        )
        
        do {
            workSession = try await sessionService.updateWorkSession(
                id: workSession.id,
                update: update
            )
        } catch {
            print("Failed to save: \(error)")
            // Handle conflict
        }
    }
    
    func refreshSession() async {
        do {
            workSession = try await sessionService.getWorkSession(id: workSession.id)
        } catch {
            print("Failed to refresh: \(error)")
        }
    }
}
```

---

## Offline Support

### Offline-First Architecture

```swift
import Foundation
import CoreData

class OfflineMarkerManager {
    static let shared = OfflineMarkerManager()
    
    private let container: NSPersistentContainer
    private let markerService = MarkerService.shared
    
    private init() {
        container = NSPersistentContainer(name: "RoboscopeModel")
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Core Data failed to load: \(error)")
            }
        }
    }
    
    // MARK: - Fetch Markers
    
    func fetchMarkers(workSessionId: UUID) async throws -> [Marker] {
        // Try network first
        do {
            let markers = try await markerService.listMarkers(workSessionId: workSessionId)
            // Cache locally
            await cacheMarkers(markers)
            return markers
        } catch {
            // Fall back to cache
            return try await fetchCachedMarkers(workSessionId: workSessionId)
        }
    }
    
    // MARK: - Create Marker (Offline Queue)
    
    func createMarker(_ marker: CreateMarker) async throws -> Marker {
        // Try to create online
        do {
            let created = try await markerService.createMarker(marker)
            return created
        } catch {
            // Queue for offline sync
            try await queueOfflineMarker(marker)
            
            // Return temporary marker
            return Marker(
                id: UUID(),
                workSessionId: marker.workSessionId,
                label: marker.label,
                p1: marker.p1,
                p2: marker.p2,
                p3: marker.p3,
                p4: marker.p4,
                color: marker.color,
                version: 0,
                meta: [:],
                createdAt: Date(),
                updatedAt: Date()
            )
        }
    }
    
    // MARK: - Sync Queue
    
    func syncPendingMarkers() async {
        let pending = try? await fetchPendingMarkers()
        
        for createMarker in pending ?? [] {
            do {
                _ = try await markerService.createMarker(createMarker)
                // Remove from queue
                try? await removeFromQueue(createMarker)
            } catch {
                print("Failed to sync marker: \(error)")
            }
        }
    }
    
    // MARK: - Core Data Helpers
    
    private func cacheMarkers(_ markers: [Marker]) async {
        // Implementation using Core Data
    }
    
    private func fetchCachedMarkers(workSessionId: UUID) async throws -> [Marker] {
        // Implementation using Core Data
        return []
    }
    
    private func queueOfflineMarker(_ marker: CreateMarker) async throws {
        // Implementation using Core Data
    }
    
    private func fetchPendingMarkers() async throws -> [CreateMarker] {
        // Implementation using Core Data
        return []
    }
    
    private func removeFromQueue(_ marker: CreateMarker) async throws {
        // Implementation using Core Data
    }
}
```

---

## Next Steps

- [Testing Guide](./IOS_TESTING_GUIDE.md) - Unit & integration tests
- [Performance Optimization](./IOS_PERFORMANCE_GUIDE.md) - App performance tips
- [Deployment Guide](./IOS_DEPLOYMENT_GUIDE.md) - App Store submission

