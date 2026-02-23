//
//  DetectionSettingsPanel.swift
//  roboscope2
//
//  Collapsible laser detection settings panel used in LaserGuideARSessionView.
//

import SwiftUI

struct DetectionSettingsPanel: View {
    @ObservedObject var mlDetection: LaserMLDetectionService
    @ObservedObject var settings: AppSettings
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle button
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Detection")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.35), .white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )

            // Settings panel
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Confidence")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                            Text(String(format: "%.2f", mlDetection.confidenceThreshold))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.green)
                        }
                        Slider(value: $mlDetection.confidenceThreshold, in: 0.05...0.95, step: 0.05)
                            .tint(.green)
                    }

                    Toggle(isOn: $mlDetection.useROI) {
                        Text("Use ROI")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .toggleStyle(.switch)
                    .tint(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("ROI Size")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                            Text(String(format: "%.2f", mlDetection.roiSize))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.green)
                        }
                        Slider(value: $mlDetection.roiSize, in: 0.20...1.00, step: 0.05)
                            .tint(.green)
                    }
                    .disabled(!mlDetection.useROI)
                    .opacity(mlDetection.useROI ? 1.0 : 0.5)

                    if let err = mlDetection.lastError, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                            .lineLimit(3)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Auto-scope Stable")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                            Text(String(format: "%.1fs", settings.laserGuideAutoScopeStableSeconds))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.green)
                        }
                        Slider(
                            value: Binding(
                                get: { settings.laserGuideAutoScopeStableSeconds },
                                set: { settings.laserGuideAutoScopeStableSeconds = $0 }
                            ),
                            in: 0.2...3.0,
                            step: 0.1
                        )
                        .tint(.green)
                    }
                }
                .padding(12)
                .frame(width: 220)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.35), .white.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                .padding(.top, 4)
            }
        }
    }
}
