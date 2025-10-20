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
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with type and status
            HStack {
                sessionTypeIcon
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.sessionType.displayName)
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    if let space = associatedSpace {
                        Text(space.name)
                            .font(.subheadline)
                    } else {
                        Text("Space: \(session.spaceId.uuidString.prefix(8))...")
                            .font(.caption)
                    }
                }
                
                Spacer()
                
                StatusBadge(status: session.status)
            }
            
            // Session details
            VStack(alignment: .leading, spacing: 6) {
                if let startedAt = session.startedAt {
                    HStack {
                        Image(systemName: "play.circle")
                            .foregroundColor(.green)
                        Text("Started: \(startedAt, formatter: dateFormatter)")
                            .font(.caption)
                    }
                }
                
                if let completedAt = session.completedAt {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.blue)
                        Text("Completed: \(completedAt, formatter: dateFormatter)")
                            .font(.caption)
                    }
                }
                
                if let duration = session.duration {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.orange)
                        Text("Duration: \(formatDuration(duration))")
                            .font(.caption)
                    }
                }
                
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.gray)
                    if let createdAt = session.createdAt {
                        Text("Created: \(createdAt, formatter: dateFormatter)")
                            .font(.caption)
                    } else {
                        Text("Created: Unknown")
                            .font(.caption)
                    }
                }
            }
            
            // Action buttons
            if session.status == .active {
                HStack {
                    Button(action: onStartAR) {
                        Label("Start AR", systemImage: "arkit")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    Spacer(minLength: 0)
                }
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
    }
    
    // MARK: - Computed Properties
    
    private var sessionTypeIcon: some View {
        Image(systemName: session.sessionType.icon)
            .font(.title2)
            .foregroundColor(iconColor)
            .frame(width: 32, height: 32)
            .background(iconColor.opacity(0.1))
            .cornerRadius(8)
    }
    
    private var iconColor: Color {
        switch session.sessionType {
        case .inspection:
            return .blue
        case .repair:
            return .orange
        case .other:
            return .gray
        }
    }
    
    private var associatedSpace: Space? {
        spaceService.spaces.first { $0.id == session.spaceId }
    }
    
    private var cardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    
    private var cardShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.08)
    }
    
    // MARK: - Formatters
    
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
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