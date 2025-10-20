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
    @State private var showingCreateSheet = false
    @State private var selectedSession: WorkSession?
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var sessionToDelete: WorkSession?
    @State private var searchText = ""
    @State private var filterStatus: WorkSessionStatus?
    @State private var filterType: WorkSessionType?
    @State private var arSession: WorkSession?
    
    var body: some View {
        NavigationView {
            VStack {
                // Filter Controls
                filterControls
                
                // Sessions List
                sessionsList
            }
            .navigationTitle("Work Sessions")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await refreshData()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search sessions...")
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
            .fullScreenCover(item: $arSession) { session in
                ARSessionView(session: session)
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
            .task {
                await loadInitialData()
            }
            .refreshable {
                await refreshData()
            }
        }
    }
    
    // MARK: - Filter Controls
    
    private var filterControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // Status Filter
                Menu {
                    Button("All Statuses") {
                        filterStatus = nil
                    }
                    
                    ForEach(WorkSessionStatus.allCases, id: \.self) { status in
                        Button(status.displayName) {
                            filterStatus = status
                        }
                    }
                } label: {
                    FilterChip(
                        title: filterStatus?.displayName ?? "All Statuses",
                        isSelected: filterStatus != nil
                    )
                }
                
                // Type Filter
                Menu {
                    Button("All Types") {
                        filterType = nil
                    }
                    
                    ForEach(WorkSessionType.allCases, id: \.self) { type in
                        Button(type.displayName) {
                            filterType = type
                        }
                    }
                } label: {
                    FilterChip(
                        title: filterType?.displayName ?? "All Types",
                        isSelected: filterType != nil
                    )
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Sessions List
    
    private var sessionsList: some View {
        Group {
            if workSessionService.isLoading && workSessionService.workSessions.isEmpty {
                ProgressView("Loading sessions...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSessions.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(filteredSessions) { session in
                        SessionRowView(session: session) {
                            // Start AR Session
                            startARSession(session)
                        } onEdit: {
                            // Edit Session
                            selectedSession = session
                            showingEditSheet = true
                        } onDelete: {
                            // Delete Session
                            sessionToDelete = session
                            showingDeleteAlert = true
                        }
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
                showingCreateSheet = true
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
    
    private var filteredSessions: [WorkSession] {
        var sessions = workSessionService.workSessions
        
        // Apply status filter
        if let filterStatus = filterStatus {
            sessions = sessions.filter { $0.status == filterStatus }
        }
        
        // Apply type filter
        if let filterType = filterType {
            sessions = sessions.filter { $0.sessionType == filterType }
        }
        
        // Apply search filter
        if !searchText.isEmpty {
            sessions = sessions.filter { session in
                // Search by space name if we have space data
                if let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) {
                    return space.name.localizedCaseInsensitiveContains(searchText) ||
                           space.key.localizedCaseInsensitiveContains(searchText)
                }
                return false
            }
        }
        
        // Sort by creation date (newest first)
        return sessions.sorted { 
            guard let date0 = $0.createdAt, let date1 = $1.createdAt else { 
                return $0.createdAt != nil // Sessions with dates come first
            }
            return date0 > date1
        }
    }
    
    // MARK: - Actions
    
    private func loadInitialData() async {
        await refreshData()
    }
    
    private func refreshData() async {
        async let sessions = workSessionService.listWorkSessions()
        async let spaces = spaceService.listSpaces()
        
        do {
            _ = try await (sessions, spaces)
        } catch {
            print("Error refreshing data: \(error)")
        }
    }
    
    private func startARSession(_ session: WorkSession) {
        arSession = session
    }
    
    private func deleteSession(_ session: WorkSession) async {
        do {
            try await workSessionService.deleteWorkSession(id: session.id)
            await refreshData()
        } catch {
            print("Error deleting session: \(error)")
            // TODO: Show error alert
        }
    }
}

// MARK: - Supporting Views

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    
    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color(.systemGray6))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(16)
    }
}

// MARK: - Preview

#Preview {
    SessionsView()
}