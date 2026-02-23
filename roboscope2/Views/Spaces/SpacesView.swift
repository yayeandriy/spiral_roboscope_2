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
    @State private var selectedSpaceFor3D: Space?
    @State private var selectedSpaceForAR: Space?
    
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
                // Left: Reload
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { Task { await refreshSpaces() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(spaceService.isLoading)
                }

                // Right: Count pill + plus
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // Spaces count pill
                    Text("\(spaceService.spaces.count)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.12))
                        )
                        .foregroundColor(.primary)

                    // Create space button
                    Button(action: { showingCreateSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            // Search removed for simplified UI
            .refreshable {
                await refreshSpaces()
            }
            .task {
                await loadInitialData()
            }
            .fullScreenCover(item: $selectedSpaceFor3D) { space in
                Space3DViewer(space: space)
            }
            .fullScreenCover(item: $selectedSpaceForAR) { space in
                SpaceARView(space: space)
            }
        }
    }
    
    // MARK: - Subviews
    
    private var spacesList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(spaceService.spaces) { space in
                    SpaceTileView(
                        space: space,
                        onDelete: {
                            Task { await deleteSpace(space) }
                        },
                        onView3D: {
                            selectedSpaceFor3D = space
                        },
                        onScan: {
                            selectedSpaceForAR = space
                        }
                    )
                    .onTapGesture { 
                        handleSpaceTap(space)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - Space Tap Handler
    
    private func handleSpaceTap(_ space: Space) {
        // If space has any 3D model (Frame/Reference/Scan), open 3D viewer
        if space.has3DContent {
            selectedSpaceFor3D = space
        } else {
            // Otherwise open AR view for scanning
            selectedSpaceForAR = space
        }
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
        } catch { }
    }
    
    private func deleteSpace(_ space: Space) async {
        do {
            try await spaceService.deleteSpace(id: space.id)
        } catch { }
    }
}

// Extracted SpaceTileView into Views/Components/SpaceTileView.swift

// MARK: - Preview

#Preview {
    SpacesView()
}
