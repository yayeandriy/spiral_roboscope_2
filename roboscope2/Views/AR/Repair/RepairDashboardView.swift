//
//  RepairDashboardView.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Repair entry point (05-ios-repair.md §5.9 / §5.10): fetch active models + default, let the
//  operator pick one, POST /v1/repair-sessions, then present RepairARSessionView.
//
//  Takes the existing local `WorkSession` (from the parallel nav hook in SessionsView) purely
//  for its already-known `spaceId`/space name — this avoids an extra network round-trip to the
//  Veranda spaces proxy on the session-creation critical path. `SpaceProxyService` remains
//  available (and is exercised) for cases where the Veranda-side space list needs to be
//  browsed independently, but is not required for this flow.
//

import SwiftUI
import UIKit

struct RepairDashboardView: View {
    let session: WorkSession

    @Environment(\.dismiss) var dismiss
    @StateObject private var modelRegistry = ModelRegistryService.shared
    @StateObject private var sessionService = RepairSessionService.shared
    /// Existing, generic Roboscope space list (UUID-keyed) — read-only use, not Laser-Guide-specific.
    @StateObject private var spaceService = SpaceService.shared

    @State private var models: [CoremlModel] = []
    @State private var selectedModel: CoremlModel?
    @State private var isLoadingModels = false
    @State private var isStarting = false
    @State private var errorMessage: String?
    @State private var activeRepairSession: RepairSession?

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Space")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(associatedSpaceName)
                            .fontWeight(.medium)
                    }
                }

                Section("Detector Model") {
                    if isLoadingModels {
                        HStack {
                            ProgressView()
                            Text("Loading models…").foregroundColor(.secondary)
                        }
                    } else if models.isEmpty {
                        Text("No active models found on Robovision. Ask an admin to upload one.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(models) { model in
                            Button {
                                selectedModel = model
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name)
                                            .foregroundColor(.primary)
                                        if model.isDefault {
                                            Text("Default")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedModel?.id == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await startSession() }
                    } label: {
                        HStack {
                            Spacer()
                            if isStarting {
                                ProgressView()
                            } else {
                                Text("Start Repair Session")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(selectedModel == nil || isStarting || isLoadingModels)
                }
            }
            .navigationTitle("Repair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await loadModels() }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .fullScreenCover(item: $activeRepairSession) { repairSession in
                if let selectedModel {
                    RepairARSessionView(session: repairSession, model: selectedModel)
                }
            }
        }
    }

    private var associatedSpaceName: String {
        spaceService.spaces.first(where: { $0.id == session.spaceId })?.name
            ?? "Space \(session.spaceId.uuidString.prefix(8))…"
    }

    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let list = try await modelRegistry.list()
            models = list
            if let def = try await modelRegistry.getDefault(), let matched = list.first(where: { $0.id == def.id }) {
                selectedModel = matched
            } else {
                selectedModel = list.first
            }
        } catch {
            errorMessage = "Failed to load models: \(error.localizedDescription)"
        }
    }

    private func startSession() async {
        guard let selectedModel else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let created = try await sessionService.create(
                spaceId: session.spaceId.uuidString,
                spaceNameCache: spaceService.spaces.first(where: { $0.id == session.spaceId })?.name,
                coremlModelId: selectedModel.id,
                deviceLabel: UIDevice.current.name
            )
            activeRepairSession = created
        } catch {
            errorMessage = "Failed to start Repair session: \(error.localizedDescription)"
        }
    }
}
