//
//  SessionsView.swift
//  roboscope2
//
//  Main view for managing work sessions
//

import SwiftUI

struct SessionsView: View {
    @StateObject private var workSessionService = WorkSessionService.shared
    @StateObject private var spaceService = SpaceService.shared
    @StateObject private var settings = AppSettings.shared
    @State private var showingCreateSheet = false
    @State private var selectedSession: WorkSession?
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var sessionToDelete: WorkSession?
    // Search and filters removed for a simpler UI
    @State private var arSession: WorkSession?
    @State private var dashboardSession: WorkSession?
    @State private var minimapSession: WorkSession?
    @State private var isLaunchingAR: Bool = false
    @State private var refreshTrigger: Bool = false  // Force row refresh
    @State private var isQuickCreating: Bool = false
    /// Persisted space tab selection. Empty string = no previous selection.
    @AppStorage("selectedSpaceTabId") private var persistedSpaceId: String = ""
    /// Resolved tab. nil = no tab selected yet (show space picker).
    @State private var selectedTabSpaceId: UUID? = nil
    @State private var isDeletingEmpty = false
    @State private var isSelectionMode = false
    @State private var selectedForDeletion: Set<UUID> = []
    @State private var showingDeleteAllAlert = false
    @State private var showingDeleteSelectedAlert = false

    @ViewBuilder
    private func laserGuideDestination(for session: WorkSession) -> some View {
        if settings.videoModeEnabled {
            VideoDetectionView(session: session)
        } else {
            LaserGuideARSessionView(session: session)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if selectedTabSpaceId == nil {
                    SpacesListView(
                        spaces: availableSpaces,
                        sessionCounts: spaceSessionCounts,
                        isLoading: false, // full-screen splash handled above
                        onSelect: { selectSpaceTab($0.id) }
                    )
                    .padding(.top, 16)
                } else {
                    sessionHeader
                    sessionsList
                }
            }
            .navigationTitle(selectedTabSpaceId == nil ? "Spaces" : selectedSpaceName)
            .navigationBarTitleDisplayMode(selectedTabSpaceId == nil ? .large : .inline)
            .toolbar(selectedTabSpaceId == nil ? .hidden : .visible, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectedTabSpaceId != nil {
                        Button(action: { goBackToSpaces() }) {
                            Image(systemName: "chevron.left")
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedTabSpaceId != nil && !isSelectionMode {
                        Button(action: { handleCreateTapped() }) {
                            Image(systemName: "plus")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            // Search removed
            .sheet(isPresented: $showingCreateSheet) {
                CreateSessionView { newSession in
                    // Session created, refresh list
                    Task {
                        await refreshData()
                    }
                }
            }
            .sheet(item: $selectedSession) { session in
                EditSessionView(session: session) { updatedSession in
                    // Session updated, refresh list
                    Task {
                        await refreshData()
                    }
                }
            }
            .fullScreenCover(item: $dashboardSession) { session in
                SessionDashboardView(session: session)
            }
            .onChange(of: dashboardSession) { oldValue, newValue in
                // As soon as navigation triggers, hide the local overlay
                if newValue != nil { isLaunchingAR = false }

                // When returning from Dashboard (which may have added markers), refresh the data
                if oldValue != nil && newValue == nil {
                    refreshTrigger.toggle()
                    Task {
                        await refreshData()
                    }
                }
            }
            .fullScreenCover(item: $arSession) { session in
                laserGuideDestination(for: session)
            }
            .onChange(of: arSession) { oldValue, newValue in
                // As soon as navigation triggers, hide the local overlay
                if newValue != nil { isLaunchingAR = false }
                
                // When returning from AR session, refresh the data to reflect any marker changes
                if oldValue != nil && newValue == nil {
                    // Toggle refresh trigger to force row views to re-fetch marker counts
                    refreshTrigger.toggle()
                    Task {
                        await refreshData()
                    }
                }
            }
            .fullScreenCover(item: $minimapSession) { session in
                MinimapView(spaceId: session.spaceId.uuidString, sessionId: session.id)
            }
            .alert("Delete Session", isPresented: $showingDeleteAlert, presenting: sessionToDelete) { session in
                Button("Delete", role: .destructive) {
                    Task {
                        await deleteSession(session)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { session in
                Text("Are you sure you want to delete this session? This action cannot be undone.")
            }
            .alert("Delete All Sessions?", isPresented: $showingDeleteAllAlert) {
                Button("Delete All", role: .destructive) {
                    Task { await deleteAllSessions() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently delete ALL \(allSessions.count) sessions in this space. This action cannot be undone.")
            }
            .alert("Delete Selected?", isPresented: $showingDeleteSelectedAlert) {
                Button("Delete \(selectedForDeletion.count)", role: .destructive) {
                    Task { await deleteSelectedSessions() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently delete the \(selectedForDeletion.count) selected sessions. This action cannot be undone.")
            }
            .overlay {
                if isDeletingEmpty {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Deleting empty sessions…")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .overlay {
                if selectedTabSpaceId == nil && spaceService.spaces.isEmpty {
                    ZStack {
                        Color(.systemBackground).ignoresSafeArea()
                        VStack(spacing: 24) {
                            Image("AppIcon")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 100, height: 100)
                                .cornerRadius(24)
                                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                            Text("Roboscope")
                                .font(.title)
                                .fontWeight(.bold)
                            ProgressView()
                                .padding(.top, 4)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .task {
                await loadInitialData()
            }
            .onChange(of: spaceService.spaces) { _, _ in
                resolvePersistedTab()
            }
            .refreshable {
                await refreshData()
            }
        }
    }
    
    // Filters removed

    // MARK: - Session Header

    private var sessionHeader: some View {
        VStack(spacing: 0) {
            if isSelectionMode {
                HStack {
                    Text("\(selectedForDeletion.count) selected")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Button("Cancel") { exitSelectionMode() }
                    Button(role: .destructive) {
                        showingDeleteSelectedAlert = true
                    } label: {
                        Text("Delete")
                    }
                    .disabled(selectedForDeletion.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(allSessions.count) sessions")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !allSessions.isEmpty {
                        Menu {
                            Button(role: .destructive) {
                                Task { await deleteAllEmptySessions() }
                            } label: {
                                Label("Delete All Empty Sessions", systemImage: "trash.slash")
                            }

                            Button {
                                enterSelectionMode()
                            } label: {
                                Label("Select to Delete…", systemImage: "checklist")
                            }

                            Divider()

                            Button(role: .destructive) {
                                showingDeleteAllAlert = true
                            } label: {
                                Label("Delete All", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundColor(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Sessions List
    
    private var sessionsList: some View {
        Group {
            if workSessionService.isLoading && workSessionService.workSessions.isEmpty {
                ProgressView("Loading sessions...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allSessions.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(allSessions) { session in
                        SessionRowView(
                            session: session,
                            refreshTrigger: refreshTrigger,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedForDeletion.contains(session.id)
                        ) {
                            if isSelectionMode {
                                toggleSelection(session.id)
                            } else {
                                startARSession(session)
                            }
                        } onMinimap: {
                            minimapSession = session
                        } onEdit: { }
                          onDelete: { }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isSelectionMode {
                                Button(role: .destructive) {
                                    sessionToDelete = session
                                    showingDeleteAlert = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    selectedSession = session
                                    showingEditSheet = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .overlay(alignment: .bottom) {
            if workSessionService.isLoading && !workSessionService.workSessions.isEmpty {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Updating...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(.regularMaterial, in: Capsule())
                .padding()
            }
        }
        .overlay {
            if isLaunchingAR || isQuickCreating {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isQuickCreating ? "Creating session…" : "Opening session...")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .transition(.opacity)
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            
            Text("No Sessions Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Create your first work session to get started")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                handleCreateTapped()
            } label: {
                Label("Create Session", systemImage: "plus")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Computed Properties

    /// All spaces sorted by name.
    private var availableSpaces: [Space] {
        spaceService.spaces.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sessions for the currently selected space tab.
    private var filteredSessions: [WorkSession] {
        guard let spaceId = selectedTabSpaceId else { return [] }
        return workSessionService.workSessions
            .filter { $0.spaceId == spaceId }
            .sorted {
                guard let d0 = $0.createdAt, let d1 = $1.createdAt else { return $0.createdAt != nil }
                return d0 > d1
            }
    }

    /// Pre-computed session counts per space, so the list doesn't re-filter on every row.
    private var spaceSessionCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for session in workSessionService.workSessions {
            counts[session.spaceId, default: 0] += 1
        }
        return counts
    }

    private var allSessions: [WorkSession] {
        filteredSessions
    }

    private var selectedSpaceName: String {
        guard let spaceId = selectedTabSpaceId,
              let space = availableSpaces.first(where: { $0.id == spaceId }) else {
            return "Work Sessions"
        }
        return space.name
    }

    private var titleText: String {
        selectedSpaceName
    }
    
    // MARK: - Actions

    private func selectSpaceTab(_ spaceId: UUID) {
        selectedTabSpaceId = spaceId
        persistedSpaceId = spaceId.uuidString
    }

    private func goBackToSpaces() {
        selectedTabSpaceId = nil
        persistedSpaceId = ""
    }

    // MARK: - Selection Mode

    private func enterSelectionMode() {
        isSelectionMode = true
        selectedForDeletion = []
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedForDeletion = []
    }

    private func toggleSelection(_ id: UUID) {
        if selectedForDeletion.contains(id) {
            selectedForDeletion.remove(id)
        } else {
            selectedForDeletion.insert(id)
        }
    }

    /// Resolve the persisted tab ID against available spaces. If valid, select it.
    /// If no persisted tab but only one space exists, auto-select it.
    private func resolvePersistedTab() {
        guard !persistedSpaceId.isEmpty,
              let uuid = UUID(uuidString: persistedSpaceId),
              availableSpaces.contains(where: { $0.id == uuid }) else {
            // No valid persisted tab. If only one space, auto-select it.
            if availableSpaces.count == 1, let only = availableSpaces.first {
                selectSpaceTab(only.id)
            }
            return
        }
        if selectedTabSpaceId != uuid {
            selectedTabSpaceId = uuid
        }
    }
    
    private func loadInitialData() async {
        await refreshData()
        resolvePersistedTab()
    }
    
    private func refreshData() async {
        async let sessions = workSessionService.listWorkSessions()
        async let spaces = spaceService.listSpaces()
        
        do {
            _ = try await (sessions, spaces)
        } catch {
            // TODO: handle error UI if needed
        }
        // Resolve persisted tab after data loads (spaces may have just arrived)
        resolvePersistedTab()
    }
    
    private func startARSession(_ session: WorkSession) {
        // Immediate haptic + overlay to confirm tap even if navigation takes a moment
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isLaunchingAR = true

        // LaserGuide sessions open a dashboard first; AR starts only on "Add marker"
        if session.isLaserGuide {
            dashboardSession = session
        } else {
            // Trigger navigation
            arSession = session
        }
    }

    // MARK: - Delete All Empty

    private func deleteAllEmptySessions() async {
        isDeletingEmpty = true
        defer { isDeletingEmpty = false }

        let markerService = MarkerService.shared
        var emptyIds: [UUID] = []

        for session in filteredSessions {
            let count = await markerService.getMarkerCountForSession(session.id)
            if count == 0 {
                emptyIds.append(session.id)
            }
        }

        guard !emptyIds.isEmpty else { return }

        for id in emptyIds {
            try? await workSessionService.deleteWorkSession(id: id)
        }
        await refreshData()
    }
    
    // MARK: - Create helpers

    private func handleCreateTapped() {
        if spaceService.spaces.count == 1, let space = spaceService.spaces.first {
            Task { await quickCreateAndOpen(space: space) }
        } else {
            showingCreateSheet = true
        }
    }

    private func quickCreateAndOpen(space: Space) async {
        isQuickCreating = true
        defer { isQuickCreating = false }
        do {
            let request = CreateWorkSession(
                spaceId: space.id,
                sessionType: .inspection,
                status: .active,
                startedAt: Date(),
                completedAt: nil,
                meta: nil
            )
            let created = try await workSessionService.createWorkSession(request)
            SessionSettingsStore.shared.setLaserGuide(sessionId: created.id, enabled: true)
            await refreshData()
            await MainActor.run {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dashboardSession = created
            }
        } catch {
            // No-op: session list will not change, user can retry manually
        }
    }

    private func deleteSession(_ session: WorkSession) async {
        do {
            try await workSessionService.deleteWorkSession(id: session.id)
            await refreshData()
        } catch {
            // TODO: Show error alert
        }
    }

    private func deleteAllSessions() async {
        isDeletingEmpty = true
        defer { isDeletingEmpty = false }
        for session in allSessions {
            try? await workSessionService.deleteWorkSession(id: session.id)
        }
        await refreshData()
    }

    private func deleteSelectedSessions() async {
        isDeletingEmpty = true
        defer { isDeletingEmpty = false }
        for id in selectedForDeletion {
            try? await workSessionService.deleteWorkSession(id: id)
        }
        await refreshData()
        exitSelectionMode()
    }
}

// Supporting filter chip removed

// MARK: - Preview

#Preview {
    SessionsView()
}

// MARK: - Session Dashboard (LaserGuide)

private struct SessionDashboardView: View {
    let session: WorkSession

    @Environment(\.dismiss) private var dismiss
    @StateObject private var markerService = MarkerService.shared
    @StateObject private var settings = AppSettings.shared

    @ViewBuilder
    private func laserGuideDestination(for session: WorkSession) -> some View {
        if settings.videoModeEnabled {
            VideoDetectionView(session: session)
        } else {
            LaserGuideARSessionView(session: session)
        }
    }

    @State private var markers: [Marker] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var arSession: WorkSession?

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        arSession = session
                    } label: {
                        Label("Add marker", systemImage: "plus")
                    }
                }

                Section {
                    ForEach(markers) { marker in
                        HStack {
                            Text(markerTitle(marker))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(markerRelativeDate(marker))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Session Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
            .task {
                await loadMarkers()
            }
            .fullScreenCover(item: $arSession) { session in
                laserGuideDestination(for: session)
            }
            .onChange(of: arSession) { oldValue, newValue in
                // When returning from AR, refresh markers list
                if oldValue != nil && newValue == nil {
                    Task {
                        await loadMarkers()
                    }
                }
            }
        }
    }

    private func loadMarkers() async {
        await MainActor.run {
            isLoading = true
        }
        do {
            let loaded = try await markerService.getMarkersForSession(session.id)
            await MainActor.run {
                markers = loaded.sorted { $0.createdAt > $1.createdAt }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = "Failed to load markers: \(error.localizedDescription)"
            }
        }
    }

    private func markerTitle(_ marker: Marker) -> String {
        if let label = marker.label, !label.isEmpty { return label }
        return "Marker \(marker.id.uuidString.prefix(8))"
    }

    private func markerRelativeDate(_ marker: Marker) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: marker.createdAt, relativeTo: Date())
    }
}