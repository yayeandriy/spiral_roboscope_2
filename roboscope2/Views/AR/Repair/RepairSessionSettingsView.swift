//
//  RepairSessionSettingsView.swift
//  roboscope2
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  In-session settings sheet for the Repair AR view. Replaces the old standalone "eye" button:
//  the detection-box overlay toggle now lives here, alongside letting the operator swap the
//  live detector model without leaving AR, and tune pin size / placement sensitivity.
//

import SwiftUI

struct RepairSessionSettingsView: View {
    @ObservedObject var settings: RepairSettings
    let activeModel: CoremlModel
    /// Called when the operator picks a different model from the list. The parent is
    /// responsible for downloading/loading it and swapping the live detection request.
    let onSelectModel: (CoremlModel) -> Void
    /// Called after the user confirms the destructive "Clear All Pins" action.
    let onClearScene: () -> Void

    @Environment(\.dismiss) private var dismiss

    @StateObject private var modelRegistry = ModelRegistryService.shared
    @State private var models: [CoremlModel] = []
    @State private var isLoadingModels = false
    @State private var loadError: String?
    @State private var showClearConfirm = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear All Pins", systemImage: "trash")
                    }
                } footer: {
                    Text("Removes every pin placed in this session, both here and on the server. This cannot be undone.")
                }

                Section {
                    Toggle("Show detection boxes", isOn: $settings.repairShowDetectionOverlay)
                        .tint(.orange)
                } footer: {
                    Text("Draws the live YOLO bounding boxes for tuning/debugging. Turning this off only hides the boxes — the maturing-progress ring and placed pins are unaffected.")
                }

                Section {
                    if isLoadingModels && models.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Loading detector models…")
                                .foregroundColor(.secondary)
                        }
                    } else if models.isEmpty {
                        Text("No active models found on Robovision.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Active detector model", selection: Binding(
                            get: { activeModel.id },
                            set: { newId in
                                if let match = models.first(where: { $0.id == newId }) {
                                    onSelectModel(match)
                                }
                            }
                        )) {
                            ForEach(models) { m in
                                Text(m.name).tag(m.id)
                            }
                        }
                    }
                } header: {
                    Text("Detector Model")
                } footer: {
                    Text("Swaps the model used for live detection in this session only. Pins already placed keep their recorded class/confidence; the session's recorded model on the server is not changed.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pin size")
                            Spacer()
                            Text("\(Int((settings.repairPinRadiusMeters * 2 * 100).rounded())) cm")
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.repairPinRadiusMeters) },
                                set: { settings.repairPinRadiusMeters = Float($0) }
                            ),
                            in: 0.004...0.03,
                            step: 0.001
                        )
                        .tint(.orange)
                    }
                } header: {
                    Text("Pin Appearance")
                } footer: {
                    Text("Diameter of the sphere drawn for each pin. Applies immediately to every pin already placed in this session, not just new ones.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Same-object radius")
                            Spacer()
                            Text("\(Int((settings.repairDedupRadiusMeters * 100).rounded())) cm")
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.repairDedupRadiusMeters) },
                                set: { settings.repairDedupRadiusMeters = Float($0) }
                            ),
                            in: 0.01...0.20,
                            step: 0.01
                        )
                        .tint(.orange)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Confidence threshold")
                            Spacer()
                            Text(String(format: "%.2f", settings.repairConfidenceThreshold))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.repairConfidenceThreshold) },
                                set: { settings.repairConfidenceThreshold = Float($0) }
                            ),
                            in: 0.1...0.9,
                            step: 0.05
                        )
                        .tint(.orange)
                    }
                } header: {
                    Text("Placement Sensitivity")
                } footer: {
                    Text("Same-object radius: two confirmed detections within this distance are treated as the same physical object — only the first gets a pin. Confidence threshold: minimum YOLO score for a detection to be tracked at all. Both apply immediately to this live session.")
                }
            }
            .navigationTitle("Repair Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadModels() }
            .alert("Error", isPresented: .constant(loadError != nil)) {
                Button("OK") { loadError = nil }
            } message: {
                if let loadError { Text(loadError) }
            }
            .alert("Clear All Pins?", isPresented: $showClearConfirm) {
                Button("Clear All Pins", role: .destructive) {
                    onClearScene()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes every pin in this session, on this device and on the server. This action cannot be undone.")
            }
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await modelRegistry.list()
        } catch {
            loadError = "Failed to load detector models: \(error.localizedDescription)"
        }
    }
}
