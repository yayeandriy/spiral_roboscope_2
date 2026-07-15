//
//  RepairModelPickerSection.swift
//  roboscope2
//
//  UNTESTED — needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  "Session settings" surface for Repair: lets the operator swap the detector model used for
//  NEW repair sessions, without blocking the "+" flow with a model-picker screen every time.
//  Embedded as a single additive Section in the existing global SettingsView.
//
//  Existing (already-created) repair sessions are unaffected — there is no
//  PATCH /repair-sessions endpoint to retarget a session's model after creation.
//

import SwiftUI

struct RepairModelPickerSection: View {
    @StateObject private var modelRegistry = ModelRegistryService.shared
    @ObservedObject private var repairSettings = RepairSettings.shared

    @State private var models: [CoremlModel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if isLoading && models.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading detector models…")
                        .foregroundColor(.secondary)
                }
            } else if models.isEmpty {
                Text("No active models found on Robovision. Ask an admin to upload one.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Picker("Planning Model", selection: $repairSettings.preferredPlanningModelId) {
                    Text("Server Default").tag(nil as String?)
                    ForEach(models) { model in
                        Text(model.name).tag(model.id.uuidString as String?)
                    }
                }
                Picker("Validation Model", selection: $repairSettings.preferredValidationModelId) {
                    Text("Server Default").tag(nil as String?)
                    ForEach(models) { model in
                        Text(model.name).tag(model.id.uuidString as String?)
                    }
                }
            }
        } header: {
            Text("Repair")
        } footer: {
            Text("Planning Model applies to new repair sessions started from the Repair tab. Validation Model applies the first time an operator switches a session into Validation mode. \"Server Default\" defers to whichever model is flagged as the default for that mode on Robovision. Sessions already in progress keep the models they're already using.")
        }
        .task { await loadModels() }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    private func loadModels() async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await modelRegistry.list()
        } catch {
            errorMessage = "Failed to load detector models: \(error.localizedDescription)"
        }
    }
}
