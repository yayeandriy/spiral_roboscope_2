//
//  SettingsView.swift
//  roboscope2
//
//  App settings interface
//

import SwiftUI
import UniformTypeIdentifiers
import CoreML
import ZIPFoundation

struct SettingsView: View {
    @StateObject var settings = AppSettings.shared
    @StateObject var videoService = VideoModeService.shared
    @State var showVideoModePicker = false
    @State var videoModeError: String? = nil
    
    var body: some View {
        NavigationView {
            Form {
                // API Environment Section
                Section {
                    Picker("API Environment", selection: $settings.apiEnvironment) {
                        ForEach(AppSettings.APIEnvironmentSetting.allCases, id: \.self) { env in
                            Text(env.displayName).tag(env)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Base URL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(APIConfiguration.shared.baseURL)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text("API")
                } footer: {
                    Text("Switch between development and production API servers. Changes take effect immediately.")
                }

                Toggle("Test Mode", isOn: $settings.testMode)
                    .tint(.orange)

                // Detection Section
                Section {
                    Toggle("Y-delta check", isOn: $settings.useYDeltaCheck)
                        .tint(.orange)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Segment tolerance")
                            Spacer()
                            Text("\(Int((settings.laserGuideDistanceToleranceMeters * 100).rounded())) cm")
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.laserGuideDistanceToleranceMeters) },
                                set: { settings.laserGuideDistanceToleranceMeters = Float($0) }
                            ),
                            in: 0.01...0.20,
                            step: 0.01
                        )
                        .tint(.orange)
                    }
                } header: {
                    Text("Detection")
                } footer: {
                    Text("Y-delta check rejects lines whose world-Y differs from the locked dot by more than the configured threshold. Segment tolerance controls how closely the measured dot↔line distance must match a laser guide segment.")
                }

                // Anchor auto-restart section
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Min re-snap distance")
                            Spacer()
                            Text(String(format: "%.1f m", settings.laserGuideMinAnchorAutoRestartDistanceMeters))
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: $settings.laserGuideMinAnchorAutoRestartDistanceMeters,
                            in: 0.5...5.0,
                            step: 0.5
                        )
                        .tint(.orange)
                    }
                } header: {
                    Text("Anchor")
                } footer: {
                    Text("Minimum distance (m) the camera must travel from the last anchor dot before a new snap is allowed. Prevents closely-spaced guide segments from triggering a premature re-snap while the phone is still drifting near the previous anchor, which could reverse the Z+ direction. Default: 2 m.")
                }

            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showVideoModePicker) {
                VideoDocumentPicker(
                    onPick: { url in
                        Task { @MainActor in
                            do {
                                try VideoModeService.shared.saveVideo(from: url)
                                showVideoModePicker = false
                            } catch {
                                videoModeError = error.localizedDescription
                                showVideoModePicker = false
                            }
                        }
                    },
                    onCancel: { showVideoModePicker = false }
                )
            }
            .alert("Video Error", isPresented: .constant(videoModeError != nil)) {
                Button("OK") { videoModeError = nil }
            } message: {
                if let videoModeError { Text(videoModeError) }
            }
        }
    }

}

#Preview {
    SettingsView()
}
