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
    // Search and filters removed for a simpler UI
    @State private var arSession: WorkSession?
    @State private var isLaunchingAR: Bool = false
    @State private var refreshTrigger: Bool = false  // Force row refresh
    
    var body: some View {
        NavigationView {
            VStack { sessionsList }
            .navigationTitle("Work Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        // Sessions count pill
                        Text("\(allSessions.count)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                            )
                            .foregroundColor(.primary)

                        Button(action: { showingCreateSheet = true }) {
                            Image(systemName: "plus")
                        }
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { Task { await refreshData() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(workSessionService.isLoading)
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
            .fullScreenCover(item: $arSession) { session in
                ARSessionView(session: session)
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
    
    // Filters removed
    
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
                        SessionRowView(session: session, refreshTrigger: refreshTrigger) {
                            // Start AR Session
                            startARSession(session)
                        } onEdit: { }
                          onDelete: { }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
            if isLaunchingAR {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Opening session...")
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
    
    private var allSessions: [WorkSession] {
        // Sort by creation date (newest first)
        return workSessionService.workSessions.sorted {
            guard let date0 = $0.createdAt, let date1 = $1.createdAt else {
                return $0.createdAt != nil
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
        // Immediate haptic + overlay to confirm tap even if navigation takes a moment
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isLaunchingAR = true
        // Trigger navigation
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

// Supporting filter chip removed

// MARK: - Preview

#Preview {
    SessionsView()
}