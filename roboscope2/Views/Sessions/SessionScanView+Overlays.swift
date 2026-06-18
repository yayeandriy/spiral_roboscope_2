//
//  SessionScanView+Overlays.swift
//  roboscope2
//
//  Bottom controls and status/progress overlay views for SessionScanView.
//

import SwiftUI

extension SessionScanView {

    // MARK: - Bottom Controls

    var bottomControls: some View {
        VStack(spacing: 16) {
            if isScanning {
                Button(action: stopScanning) {
                    Label("Stop Scan", systemImage: "stop.fill")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .lgCapsule(tint: .red)
            } else if hasScanData {
                HStack(spacing: 12) {
                    Button(action: saveScanToSpace) {
                        Label("Save Scan", systemImage: "square.and.arrow.up")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .lgCapsule(tint: .green)
                    .disabled(isExporting || isRegistering)

                    Button(action: findSpace) {
                        Label("Find Space", systemImage: "magnifyingglass")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .lgCapsule(tint: .blue)
                    .disabled(isExporting || isRegistering)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
    }

    // MARK: - Export Progress Overlay

    var exportProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView(value: exportProgress)
                .progressViewStyle(.linear)
                .tint(.white)

            Text(exportStatus)
                .font(.subheadline)
                .foregroundColor(.white)

            Text("\(Int(exportProgress * 100))%")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }

    // MARK: - Success Message Overlay

    var successMessageOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Scan Saved Successfully!")
                .font(.headline)
                .foregroundColor(.primary)

            Text("Session data updated with scan")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSuccessMessage = false
                }
            }
        }
    }

    // MARK: - Registration Progress Overlay

    var registrationProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            Text(registrationProgress)
                .font(.subheadline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }

    // MARK: - Registration Result Overlay

    var registrationResultOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Registration Complete!")
                .font(.headline)
                .foregroundColor(.primary)

            Text(registrationMetrics)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Dismiss") {
                withAnimation {
                    showRegistrationResult = false
                    if let transform = transformMatrix {
                        onRegistrationComplete?(transform)
                    }
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }

    // MARK: - Model Loading Overlay

    var modelLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            Text("Loading reference model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }

    // MARK: - Scan Loading Overlay

    var scanLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

            Text("Loading scanned model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
}
