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
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    @StateObject private var spaceService = SpaceService.shared
    
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
                            .foregroundColor(.secondary)
                    } else {
                        Text("Space: \(session.spaceId.uuidString.prefix(8))...")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
                    }
                }
                
                if let completedAt = session.completedAt {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.blue)
                        Text("Completed: \(completedAt, formatter: dateFormatter)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let duration = session.duration {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.orange)
                        Text("Duration: \(formatDuration(duration))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.gray)
                    if let createdAt = session.createdAt {
                        Text("Created: \(createdAt, formatter: dateFormatter)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Created: Unknown")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Action buttons
            HStack(spacing: 12) {
                // Start AR button (only for active sessions)
                if session.status == .active {
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
                }
                
                Spacer()
                
                // Edit button
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .frame(width: 24, height: 24)
                }
                
                // Delete button
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
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