//
//  SessionRowView.swift
//  roboscope2
//
//  Individual session row component
//

import SwiftUI

struct SessionRowView: View {
    let session: WorkSession
    let onStartAR: () -> Void
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
            // Top row: status (left) + time ago (right)
            HStack(alignment: .firstTextBaseline) {
                Text(session.status.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor)
                Spacer()
                if let timeAgo = timeAgoString {
                    Text(timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Title: Space name (or fallback)
            Text(spaceName)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            // Bottom row: session type (left) + markers badge (right)
            HStack {
                Text(session.sessionType.displayName.capitalized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                markersBadge
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
            onStartAR()
        }
        .task {
            // Fetch accurate per-session marker count without mutating global markers
            print("[SessionRow] Fetching markers for session \(session.id)")
            let count = await markerService.getMarkerCountForSession(session.id)
            print("[SessionRow] Got count: \(count) for session \(session.id)")
            sessionMarkersCount = count
        }
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
    
    private var statusColor: Color {
        switch session.status {
        case .draft: return .gray
        case .active: return .green
        case .done: return .blue
        case .archived: return .purple
        }
    }
    
    private var spaceName: String {
        if let space = associatedSpace { return space.name }
        return "Space: \(session.spaceId.uuidString.prefix(8))..."
    }
    
    private var markersCount: Int {
        let count = sessionMarkersCount ?? markerService.markers.filter { $0.workSessionId == session.id }.count
        print("[SessionRow] Displaying count: \(count) (exact: \(sessionMarkersCount?.description ?? "nil"), filtered: \(markerService.markers.filter { $0.workSessionId == session.id }.count))")
        return count
    }
    
    private var markersBadge: some View {
        Text("\(markersCount) markers")
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
    
    // MARK: - Formatters
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }
    
    private var timeAgoString: String? {
        let ref = session.updatedAt ?? session.startedAt ?? session.createdAt
        guard let date = ref else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
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
                meta: [:],
                createdAt: Date().addingTimeInterval(-7200), // 2 hours ago
                updatedAt: Date()
            ),
            onStartAR: { print("Start AR") },
            onEdit: { print("Edit") },
            onDelete: { print("Delete") }
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
            onStartAR: { print("Start AR") },
            onEdit: { print("Edit") },
            onDelete: { print("Delete") }
        )
    }
    .padding()
}