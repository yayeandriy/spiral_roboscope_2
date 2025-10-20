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
    
    var body: some View {
        NavigationView {
            VStack { sessionsList }
            .navigationTitle("Work Sessions")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingCreateSheet = true }) {
                        Image(systemName: "plus")
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
                        SessionRowView(session: session) {
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