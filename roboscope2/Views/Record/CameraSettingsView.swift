//
//  CameraSettingsView.swift
//  roboscope2
//
//  Sheet for configuring camera recording settings.
//

import SwiftUI

struct CameraSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var settings: RecorderSettings

    var body: some View {
        NavigationView {
            Form {
                Section("Video") {
                    Picker("Proportion", selection: $settings.proportion) {
                        ForEach(RecorderSettings.CaptureProportion.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }

                    Picker("Frame Rate", selection: $settings.frameRate) {
                        ForEach(RecorderSettings.FrameRate.allCases, id: \.rawValue) { f in
                            Text("\(f.rawValue) fps").tag(f)
                        }
                    }

                    Picker("Quality", selection: $settings.quality) {
                        ForEach(RecorderSettings.Quality.allCases, id: \.self) { q in
                            Text(q.rawValue.capitalized).tag(q)
                        }
                    }
                }

                Section("Camera") {
                    Picker("Lens", selection: $settings.camera) {
                        ForEach(RecorderSettings.CameraPosition.allCases, id: \.self) { c in
                            Text(c.label).tag(c)
                        }
                    }
                }
            }
            .navigationTitle("Camera Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        settings.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
