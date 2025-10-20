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
    @State private var selectedSpace: Space?
    
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
            .fullScreenCover(item: $selectedSpace) { space in
                SpaceARView(space: space)
            }
        }
    }
    
    // MARK: - Subviews
    
    private var spacesList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(spaceService.spaces) { space in
                    SpaceTileView(space: space) {
                        Task { await deleteSpace(space) }
                    }
                    .onTapGesture { selectedSpace = space }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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

// MARK: - Space Tile View (Square Card)

struct SpaceTileView: View {
    let space: Space
    var onDelete: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Card background
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(cardStrokeColor, lineWidth: 0.5)
                )

            // Content
            VStack(alignment: .leading, spacing: 8) {
                // Title
                Text(space.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                // Subtitle/description
                if let description = space.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Spacer(minLength: 0)
                }

                Spacer()

                // Bottom labels
                HStack(spacing: 12) {
                    if space.modelGlbUrl != nil {
                        Text("GLB")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                    }

                    if space.modelUsdcUrl != nil {
                        Text("USDC")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    }

                    Spacer()
                }
            }
            .padding(16)
        }
        .aspectRatio(1, contentMode: .fit) // Square card
        .contextMenu {
            if let onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var cardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
}

// MARK: - Preview

#Preview {
    SpacesView()
}
