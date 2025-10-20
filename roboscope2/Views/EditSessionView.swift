//
//  EditSessionView.swift
//  roboscope2
//
//  View for editing existing work sessions
//

import SwiftUI

struct EditSessionView: View {
    let session: WorkSession
    let onSessionUpdated: (WorkSession) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workSessionService = WorkSessionService.shared
    @StateObject private var spaceService = SpaceService.shared
    
    @State private var selectedSpace: Space?
    @State private var sessionType: WorkSessionType
    @State private var sessionStatus: WorkSessionStatus
    @State private var showingSpacePicker = false
    @State private var isUpdating = false
    @State private var errorMessage: String?
    
    init(session: WorkSession, onSessionUpdated: @escaping (WorkSession) -> Void) {
        self.session = session
        self.onSessionUpdated = onSessionUpdated
        self._sessionType = State(initialValue: session.sessionType)
        self._sessionStatus = State(initialValue: session.status)
    }
    
    var body: some View {
        NavigationView {
            Form {
                // Session Info
                Section {
                    HStack {
                        Text("Session ID")
                        Spacer()
                        Text(session.id.uuidString.prefix(8) + "...")
                            .font(.caption)
                    }
                    
                    HStack {
                        Text("Created")
                        Spacer()
                        if let createdAt = session.createdAt {
                            Text(createdAt, formatter: dateTimeFormatter)
                                .font(.caption)
                        } else {
                            Text("Unknown")
                                .font(.caption)
                        }
                    }
                    
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(session.version)")
                            .font(.caption)
                    }
                } header: {
                    Text("Session Information")
                }
                
                // Space Selection
                Section {
                    Button {
                        showingSpacePicker = true
                    } label: {
                        HStack {
                            Text("Space")
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            if let selectedSpace = selectedSpace {
                                VStack(alignment: .trailing) {
                                    Text(selectedSpace.name)
                                        .foregroundColor(.primary)
                                    Text(selectedSpace.key)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("Loading...")
                            }
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("Location")
                }
                
                // Session Type - separate rows
                Section("Session Type") {
                    ForEach(WorkSessionType.allCases, id: \.self) { type in
                        Button {
                            sessionType = type
                        } label: {
                            HStack {
                                Image(systemName: type.icon)
                                Text(type.displayName)
                                Spacer()
                                if sessionType == type {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                
                // Status
                Section {
                    Picker("Status", selection: $sessionStatus) {
                        ForEach(WorkSessionStatus.allCases, id: \.self) { status in
                            HStack {
                                Image(systemName: status.icon)
                                Text(status.displayName)
                            }
                            .tag(status)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                } header: {
                    Text("Status")
                } footer: {
                    Text(statusDescription)
                }
                
                // Timestamps
                Section {
                    if let startedAt = session.startedAt {
                        HStack {
                            Text("Started At")
                            Spacer()
                            Text(startedAt, formatter: dateTimeFormatter)
                        }
                    }
                    
                    if let completedAt = session.completedAt {
                        HStack {
                            Text("Completed At")
                            Spacer()
                            Text(completedAt, formatter: dateTimeFormatter)
                        }
                    }
                    
                    if let duration = session.duration {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(formatDuration(duration))
                        }
                    }
                } header: {
                    Text("Timeline")
                }
                
                // Quick Actions
                Section {
                    if session.status == .draft {
                        Button {
                            sessionStatus = .active
                        } label: {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("Start Session")
                            }
                        }
                    }
                    
                    if session.status == .active {
                        Button {
                            sessionStatus = .done
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Complete Session")
                            }
                        }
                    }
                    
                    if session.status == .done {
                        Button {
                            sessionStatus = .archived
                        } label: {
                            HStack {
                                Image(systemName: "archivebox.fill")
                                Text("Archive Session")
                            }
                        }
                    }
                } header: {
                    Text("Quick Actions")
                }
            }
            .navigationTitle("Edit Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        Task {
                            await updateSession()
                        }
                    }
                    .disabled(hasNoChanges || isUpdating)
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingSpacePicker) {
                SpacePickerView(selectedSpace: $selectedSpace)
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
            .overlay {
                if isUpdating {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Updating session...")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task {
                await loadInitialData()
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var hasNoChanges: Bool {
        guard let selectedSpace = selectedSpace else { return true }
        
        return selectedSpace.id == session.spaceId &&
               sessionType == session.sessionType &&
               sessionStatus == session.status
    }
    
    private var statusDescription: String {
        switch sessionStatus {
        case .draft:
            return "Session is saved but not started"
        case .active:
            return "Session is currently in progress"
        case .done:
            return "Session has been completed"
        case .archived:
            return "Session is archived and read-only"
        }
    }
    
    private var dateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
    
    // MARK: - Actions
    
    private func loadInitialData() async {
        do {
            _ = try await spaceService.listSpaces()
            selectedSpace = spaceService.spaces.first { $0.id == session.spaceId }
        } catch {
            errorMessage = "Failed to load spaces: \(error.localizedDescription)"
        }
    }
    
    private func updateSession() async {
        guard let selectedSpace = selectedSpace else { return }
        
        isUpdating = true
        
        do {
            // Determine if timestamps should be updated based on status changes
            var startedAt: Date? = session.startedAt
            var completedAt: Date? = session.completedAt
            
            // If changing from draft to active, set start time
            if session.status == .draft && sessionStatus == .active && startedAt == nil {
                startedAt = Date()
            }
            
            // If changing to done, set completion time
            if sessionStatus == .done && completedAt == nil {
                completedAt = Date()
            }
            
            let updateRequest = UpdateWorkSession(
                spaceId: selectedSpace.id != session.spaceId ? selectedSpace.id : nil,
                sessionType: sessionType != session.sessionType ? sessionType : nil,
                status: sessionStatus != session.status ? sessionStatus : nil,
                startedAt: startedAt != session.startedAt ? startedAt : nil,
                completedAt: completedAt != session.completedAt ? completedAt : nil,
                version: session.version
            )
            
            let updatedSession = try await workSessionService.updateWorkSession(
                id: session.id,
                update: updateRequest
            )
            
            await MainActor.run {
                onSessionUpdated(updatedSession)
                dismiss()
            }
            
        } catch {
            await MainActor.run {
                isUpdating = false
                errorMessage = "Failed to update session: \(error.localizedDescription)"
            }
        }
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

// MARK: - Preview

#Preview {
    EditSessionView(
        session: WorkSession(
            id: UUID(),
            spaceId: UUID(),
            sessionType: .inspection,
            status: .active,
            startedAt: Date().addingTimeInterval(-3600),
            completedAt: nil,
            version: 1,
            meta: [:],
            createdAt: Date().addingTimeInterval(-7200),
            updatedAt: Date()
        )
    ) { session in
        print("Updated session: \(session)")
    }
}