//
//  RepairSessionSettingsView.swift
//  roboscope2
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  In-session settings sheet for the Repair AR view. Replaces the old standalone "eye" button:
//  the detection-box overlay toggle now lives here, alongside letting the operator swap the
//  live detector model without leaving AR, and tune pin size / placement sensitivity.
//  "Clear All Pins" moved OUT of this sheet onto the main AR viewport as a recycle-bin button
//  (RepairARSessionView.topBar) — it's used often enough to want a one-tap + one-confirmation
//  flow without a trip through Settings.
//

import SwiftUI

struct RepairSessionSettingsView: View {
    @ObservedObject var settings: RepairSettings
    /// Which sub-mode this sheet was opened from (v0.4) — determines which sections show at
    /// all (pins/dedup are meaningless in Validation) and which model/threshold the "Detector
    /// Model" picker and "Confidence threshold" slider actually edit.
    let sessionMode: RepairSessionMode
    /// The model currently driving live detection for `sessionMode` — Planning's `activeModel`,
    /// or Validation's `validationModel` (nil if Validation hasn't been entered yet this
    /// session, in which case the picker still lets the operator pick one ahead of time).
    let currentModel: CoremlModel?
    /// Called when the operator picks a different model from the list. The parent is
    /// responsible for downloading/loading it and swapping the live detection request for
    /// whichever mode is currently active.
    let onSelectModel: (CoremlModel) -> Void

    @Environment(\.dismiss) private var dismiss

    @StateObject private var modelRegistry = ModelRegistryService.shared
    @State private var models: [CoremlModel] = []
    @State private var isLoadingModels = false
    @State private var loadError: String?

    /// Reads/writes whichever confidence threshold matches `sessionMode` — the two are
    /// independent settings (see RepairSettings) since Planning and Validation run different
    /// models for different purposes.
    private var confidenceThreshold: Float {
        get { sessionMode == .planning ? settings.repairPlanningConfidenceThreshold : settings.repairValidationConfidenceThreshold }
        nonmutating set {
            if sessionMode == .planning {
                settings.repairPlanningConfidenceThreshold = newValue
            } else {
                settings.repairValidationConfidenceThreshold = newValue
            }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                if sessionMode == .planning {
                    Section {
                        Toggle("Show detection boxes", isOn: $settings.repairShowDetectionOverlay)
                            .tint(.orange)
                    } footer: {
                        Text("Draws the live YOLO bounding boxes for tuning/debugging. Turning this off only hides the boxes — the maturing-progress ring and placed pins are unaffected.")
                    }
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
                        Picker("\(sessionMode.displayName) detector model", selection: Binding(
                            get: { currentModel?.id },
                            set: { newId in
                                if let newId, let match = models.first(where: { $0.id == newId }) {
                                    onSelectModel(match)
                                }
                            }
                        )) {
                            if currentModel == nil {
                                Text("Not yet resolved").tag(nil as UUID?)
                            }
                            ForEach(models) { m in
                                Text(m.name).tag(m.id as UUID?)
                            }
                        }
                    }
                } header: {
                    Text("\(sessionMode.displayName) Detector Model")
                } footer: {
                    Text(sessionMode == .planning
                        ? "Swaps the model used for live detection/placement in this session only. Pins already placed keep their recorded class/confidence; the session's recorded model on the server is not changed."
                        : "Swaps the model used for Validation's passive detection overlay in this session only. Has no effect on Planning or on any pin already placed.")
                }

                if sessionMode == .planning {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Pin size")
                                Spacer()
                                Text(String(format: "%.1f cm", settings.repairPinRadiusMeters * 2 * 100))
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(settings.repairPinRadiusMeters) },
                                    set: { settings.repairPinRadiusMeters = Float($0) }
                                ),
                                // 0.0005 m radius = 0.1 cm diameter (smallest selectable) ... 0.03 m
                                // radius = 6 cm diameter. Step lands exactly on 0.1 cm increments.
                                in: 0.0005...0.03,
                                step: 0.0005
                            )
                            .tint(.orange)
                        }
                    } header: {
                        Text("Pin Appearance")
                    } footer: {
                        Text("Diameter of the sphere drawn for each pin. Applies immediately to every pin already placed in this session, not just new ones.")
                    }
                }

                Section {
                    if sessionMode == .planning {
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
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Confidence threshold")
                            Spacer()
                            Text(String(format: "%.2f", confidenceThreshold))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(confidenceThreshold) },
                                set: { confidenceThreshold = Float($0) }
                            ),
                            in: 0.1...0.9,
                            step: 0.05
                        )
                        .tint(.orange)
                    }
                } header: {
                    Text("Placement Sensitivity")
                } footer: {
                    Text(sessionMode == .planning
                        ? "Same-object radius: two confirmed detections within this distance are treated as the same physical object — only the first gets a pin. Confidence threshold: minimum YOLO score for a detection to be tracked at all. Both apply immediately to this live session."
                        : "Confidence threshold: minimum YOLO score for a detection to be shown in the Validation overlay at all. Applies immediately to this live session.")
                }

                if sessionMode == .planning {
                    Section {
                        Toggle("Require repeated detections", isOn: $settings.repairUseAccumulator)
                            .tint(.orange)

                        if settings.repairUseAccumulator {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Accumulator window")
                                    Spacer()
                                    Text("\(settings.repairTemporalWindowFrames) frames")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.repairTemporalWindowFrames) },
                                        set: { newValue in
                                            let window = Int(newValue.rounded())
                                            settings.repairTemporalWindowFrames = window
                                            if settings.repairConfirmThreshold > window {
                                                settings.repairConfirmThreshold = window
                                            }
                                        }
                                    ),
                                    in: 5...60,
                                    step: 1
                                )
                                .tint(.orange)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Confirm threshold")
                                    Spacer()
                                    Text("\(settings.repairConfirmThreshold) of \(settings.repairTemporalWindowFrames)")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.repairConfirmThreshold) },
                                        set: { settings.repairConfirmThreshold = Int($0.rounded()) }
                                    ),
                                    in: 1...Double(max(1, settings.repairTemporalWindowFrames)),
                                    step: 1
                                )
                                .tint(.orange)
                            }
                        }
                    } header: {
                        Text("Detection Accumulator")
                    } footer: {
                        Text(settings.repairUseAccumulator
                            ? "On (default): a pin is placed once a tracked object hits the confirm threshold within the last N frames of the accumulator window (the classic \"15 of the last 20\" behavior). Higher thresholds are steadier but slower to place a pin."
                            : "A pin is placed immediately on the very first detection of an object, no accumulation delay. This trades off steadiness (more prone to single-frame noise) for instant placement.")
                    }
                }
            }
            .navigationTitle("\(sessionMode.displayName) Settings")
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
