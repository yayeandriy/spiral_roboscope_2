//
//  CreateSessionView.swift
//  roboscope2
//
//  View for creating new work sessions
//

import SwiftUI

struct CreateSessionView: View {
    let onSessionCreated: (WorkSession) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workSessionService = WorkSessionService.shared
    @StateObject private var spaceService = SpaceService.shared
    
    @State private var selectedSpace: Space?
    @State private var sessionType: WorkSessionType = .inspection
    @State private var sessionStatus: WorkSessionStatus = .draft
    @State private var startImmediately = false
    @State private var showingSpacePicker = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
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
                                Text("Select Space")
                                    .foregroundColor(.secondary)
                            }
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Choose the space where this work session will take place")
                }
                
                // Session Type
                Section {
                    Picker("Session Type", selection: $sessionType) {
                        ForEach(WorkSessionType.allCases, id: \.self) { type in
                            HStack {
                                Image(systemName: type.icon)
                                Text(type.displayName)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                } header: {
                    Text("Session Type")
                } footer: {
                    Text(sessionTypeDescription)
                }
                
                // Session Options
                Section {
                    Toggle("Start Immediately", isOn: $startImmediately)
                        .onChange(of: startImmediately) { newValue in
                            sessionStatus = newValue ? .active : .draft
                        }
                } header: {
                    Text("Options")
                } footer: {
                    Text("If enabled, the session will start immediately and be marked as active")
                }
                
                // Status (read-only, based on start immediately toggle)
                Section {
                    HStack {
                        StatusBadge(status: sessionStatus)
                        Spacer()
                        Text("This will be the initial status")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Initial Status")
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        Task {
                            await createSession()
                        }
                    }
                    .disabled(selectedSpace == nil || isCreating)
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
                if isCreating {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Creating session...")
                            .font(.headline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .task {
                await loadSpaces()
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var sessionTypeDescription: String {
        switch sessionType {
        case .inspection:
            return "Inspect and document issues or conditions"
        case .repair:
            return "Perform maintenance or repair work"
        case .other:
            return "General work session"
        }
    }
    
    // MARK: - Actions
    
    private func loadSpaces() async {
        do {
            _ = try await spaceService.listSpaces()
        } catch {
            errorMessage = "Failed to load spaces: \(error.localizedDescription)"
        }
    }
    
    private func createSession() async {
        guard let selectedSpace = selectedSpace else { return }
        
        isCreating = true
        
        do {
            let createRequest = CreateWorkSession(
                spaceId: selectedSpace.id,
                sessionType: sessionType,
                status: sessionStatus,
                startedAt: startImmediately ? Date() : nil,
                completedAt: nil
            )
            
            let createdSession = try await workSessionService.createWorkSession(createRequest)
            
            await MainActor.run {
                onSessionCreated(createdSession)
                dismiss()
            }
            
        } catch {
            await MainActor.run {
                isCreating = false
                errorMessage = "Failed to create session: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Space Picker View

struct SpacePickerView: View {
    @Binding var selectedSpace: Space?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spaceService = SpaceService.shared
    
    var body: some View {
        NavigationView {
            List {
                ForEach(spaceService.spaces) { space in
                    Button {
                        selectedSpace = space
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(space.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                Text(space.key)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                if let description = space.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            
                            Spacer()
                            
                            if selectedSpace?.id == space.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Select Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    CreateSessionView { session in
        print("Created session: \(session)")
    }
}