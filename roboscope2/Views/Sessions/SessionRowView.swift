//
//  SessionRowView.swift
//  roboscope2
//
//  Individual session row component
//

import SwiftUI

struct SessionRowView: View {
    let session: WorkSession
    let refreshTrigger: Bool  // Force re-fetch marker count
    let isSelectionMode: Bool
    let isSelected: Bool
    let onStartAR: () -> Void
    let onMinimap: (() -> Void)?
    // These are kept for compatibility but handled via swipe actions in the list
    // rather than inline buttons in the row. They are optional and unused here.
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    
    @StateObject private var spaceService = SpaceService.shared
    @StateObject private var markerService = MarkerService.shared
    @State private var sessionMarkersCount: Int? = nil
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
    VStack(alignment: .leading, spacing: 10) {
            // Title + optional selection checkbox
            HStack(alignment: .top, spacing: 0) {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .blue : .secondary.opacity(0.5))
                        .padding(.trailing, 12)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let updatedTime = updatedRelativeString {
                        Text(updatedTime)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    } else {
                        Text(session.id.uuidString.prefix(8).description)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                    }

                    // Bottom row: session type + laser guide badge + markers / empty
                    HStack(spacing: 8) {
                        Text(session.sessionType.displayName.capitalized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if session.isLaserGuide {
                            laserGuideBadge
                        }

                        Spacer()
                        markersIndicator

                        if let onMinimap {
                            Button {
                                onMinimap()
                            } label: {
                                Image(systemName: "map")
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 36, height: 36)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            // ML model row (only for LaserGuide sessions whose space has a model URL)
            if session.isLaserGuide, let space = associatedSpace, space.mlModelUrl != nil {
                mlModelRow(space: space)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStrokeColor, lineWidth: 0.5)
        )
        .shadow(color: cardShadowColor, radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onStartAR()
        }
        .task {
            // Fetch accurate per-session marker count without mutating global markers
            await fetchMarkerCount()
        }
        .onChange(of: refreshTrigger) {
            Task {
                await fetchMarkerCount()
            }
        }
    }
    
    // MARK: - Actions

    @ViewBuilder
    private func mlModelRow(space: Space) -> some View {
        let entry = SpaceMLModelStore.shared.find(spaceId: space.id.uuidString)
        HStack(spacing: 8) {
            Image(systemName: entry != nil ? "cpu.fill" : "cpu")
                .font(.caption)
                .foregroundColor(entry != nil ? .green : .secondary)
            if let entry {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.modelName)
                        .font(.caption)
                        .foregroundColor(.primary)
                    Text(entry.downloadedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Model will download at session start")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func fetchMarkerCount() async {
        let count = await markerService.getMarkerCountForSession(session.id)
        sessionMarkersCount = count
    }
    
    // MARK: - Computed Properties
    
    private var associatedSpace: Space? {
        spaceService.spaces.first { $0.id == session.spaceId }
    }
    
    private var cardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    
    private var cardShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.08)
    }
    
    private var updatedRelativeString: String? {
        guard let updatedAt = session.updatedAt else { 
            return nil 
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        let relativeString = fmt.localizedString(for: updatedAt, relativeTo: Date())
        return relativeString
    }
    
    private var markersCount: Int {
        sessionMarkersCount ?? markerService.markers.filter { $0.workSessionId == session.id }.count
    }
    
    @ViewBuilder
    private var markersIndicator: some View {
        if markersCount == 0 {
            Text("Empty")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("\(markersCount) marker\(markersCount == 1 ? "" : "s")")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var laserGuideBadge: some View {
        Text("Laser Guided")
            .font(.caption)
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                    .background(Capsule().fill(Color(.systemBackground)))
            )
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

struct StatusBadge: View {
    let status: WorkSessionStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .font(.caption2)
            Text(status.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(textColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .cornerRadius(12)
    }
    
    private var backgroundColor: Color {
        switch status {
        case .draft:
            return Color.gray.opacity(0.2)
        case .active:
            return Color.green.opacity(0.2)
        case .done:
            return Color.blue.opacity(0.2)
        case .archived:
            return Color.purple.opacity(0.2)
        }
    }
    
    private var textColor: Color {
        switch status {
        case .draft:
            return .gray
        case .active:
            return .green
        case .done:
            return .blue
        case .archived:
            return .purple
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        SessionRowView(
            session: WorkSession(
                id: UUID(),
                spaceId: UUID(),
                sessionType: .inspection,
                status: .active,
                startedAt: Date().addingTimeInterval(-3600), // 1 hour ago
                completedAt: nil,
                version: 1,
                meta: [WorkSessionMetaKeys.spatialEnvironment: AnyCodable("laserGuide")],
                createdAt: Date().addingTimeInterval(-7200), // 2 hours ago
                updatedAt: Date()
            ),
            refreshTrigger: false,
            isSelectionMode: false,
            isSelected: false,
            onStartAR: { },
            onMinimap: nil,
            onEdit: { },
            onDelete: { }
        )
        
        SessionRowView(
            session: WorkSession(
                id: UUID(),
                spaceId: UUID(),
                sessionType: .repair,
                status: .done,
                startedAt: Date().addingTimeInterval(-7200),
                completedAt: Date().addingTimeInterval(-3600),
                version: 2,
                meta: [:],
                createdAt: Date().addingTimeInterval(-14400),
                updatedAt: Date()
            ),
            refreshTrigger: false,
            isSelectionMode: false,
            isSelected: false,
            onStartAR: { },
            onMinimap: nil,
            onEdit: { },
            onDelete: { }
        )
    }
    .padding()
}