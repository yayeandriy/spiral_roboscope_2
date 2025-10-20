//
//  SpacesView.swift
//  roboscope2
//
//  View for managing 3D spaces
//

import SwiftUI

struct SpacesView: View {
    @StateObject private var spaceService = SpaceService.shared
    @State private var showingCreateSheet = false
    
    var body: some View {
        NavigationView {
            ZStack {
                if spaceService.isLoading && spaceService.spaces.isEmpty {
                    ProgressView("Loading spaces...")
                } else if spaceService.spaces.isEmpty {
                    emptyStateView
                } else {
                    spacesList
                }
            }
            .navigationTitle("Spaces")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingCreateSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { Task { await refreshSpaces() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(spaceService.isLoading)
                }
            }
            // Search removed for simplified UI
            .refreshable {
                await refreshSpaces()
            }
            .task {
                await loadInitialData()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var spacesList: some View {
        List {
            ForEach(spaceService.spaces) { space in
                SpaceRowView(space: space)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task {
                                await deleteSpace(space)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "cube")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            
            Text("No Spaces")
                .font(.title)
                .fontWeight(.semibold)
            
            Text("Create a space to get started")
                .font(.body)
                .foregroundColor(.secondary)
            
            Button(action: { showingCreateSheet = true }) {
                Label("Create Space", systemImage: "plus")
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    // Search removed
    
    // MARK: - Actions
    
    private func loadInitialData() async {
        await refreshSpaces()
    }
    
    private func refreshSpaces() async {
        do {
            _ = try await spaceService.listSpaces()
        } catch {
            print("Error loading spaces: \(error)")
        }
    }
    
    private func deleteSpace(_ space: Space) async {
        do {
            try await spaceService.deleteSpace(id: space.id)
        } catch {
            print("Error deleting space: \(error)")
        }
    }
}

// MARK: - Space Row View

struct SpaceRowView: View {
    let space: Space
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(space.name)
                    .font(.headline)
                
                Spacer()
                
                Text(space.key)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(4)
            }
            
            if let description = space.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            HStack(spacing: 16) {
                if space.modelGlbUrl != nil {
                    Label("GLB", systemImage: "cube.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                
                if space.modelUsdcUrl != nil {
                    Label("USDC", systemImage: "cube.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                if let createdAt = space.createdAt {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(.gray)
                        Text("Created: \(createdAt, formatter: dateFormatter)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}

// MARK: - Preview

#Preview {
    SpacesView()
}
