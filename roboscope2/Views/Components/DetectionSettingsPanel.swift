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

                    // Accumulator frame count
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Acc Frames")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                            Spacer()
                            Text("\(settings.videoModeAccumulatorFrames)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.orange)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.videoModeAccumulatorFrames) },
                                set: { settings.videoModeAccumulatorFrames = Int($0.rounded()) }
                            ),
                            in: 1...10,
                            step: 1
                        )
                        .tint(.orange)
                    }

                    Toggle(isOn: $settings.showAccumulatedOverlay) {
                        Text("Acc. Overlay")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .toggleStyle(.switch)
                    .tint(.orange)

                    Toggle(isOn: $settings.lineOverDotFilter) {
                        Text("Line over dot")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .toggleStyle(.switch)
                    .tint(.orange)

                    Toggle(isOn: $settings.usePerFrame3DPlacement) {
                        Text("Per-frame 3D")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .toggleStyle(.switch)
                    .tint(.orange)

                    if let err = mlDetection.lastError, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.red)
                            .lineLimit(3)
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
