//
//  MarkerBadgeView.swift
//  roboscope2
//
//  Extracted badge view showing marker metrics/details.
//

import SwiftUI

struct MarkerBadgeView: View {
    let info: SpatialMarkerService.MarkerInfo
    var details: MarkerDetails? = nil
    var onDelete: (() -> Void)? = nil
    @State private var showNodes: Bool = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 20) {
                // Raw center row
                metricGroup(title: "Raw center") {
                    axisRow(axis1: ("x", info.centerX, Color.red), axis2: ("z", info.centerZ, Color.blue))
                }
                // Calibrated center row (only show if different from raw)
                if let c = info.calibratedCenter, calibratedDiffersFromRaw(calibrated: c, rawX: info.centerX, rawZ: info.centerZ) {
                    metricGroup(title: "Calibrated center") {
                        axisRow(axis1: ("x", c.x, Color.red), axis2: ("z", c.z, Color.blue))
                    }
                }
                // Collapsible: Raw nodes
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showNodes.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showNodes ? "chevron.down" : "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                            Text("Nodes")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(.white.opacity(0.95))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    if showNodes {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(info.nodes.enumerated()), id: \.0) { idx, p in
                                HStack(spacing: 10) {
                                    Text("p\(idx+1)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.8))
                                        .frame(width: 22, alignment: .leading)
                                    coordChip(label: "x", value: p.x, tint: .red)
                                    coordChip(label: "y", value: p.y, tint: .green)
                                    coordChip(label: "z", value: p.z, tint: .blue)
                                    Spacer()
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                // Size row
                metricGroup(title: "Size") {
                    let width = info.calibratedWidth ?? info.width
                    let length = info.calibratedLength ?? info.length
                    axisRow(axis1: ("W", width, Color.red), axis2: ("L", length, Color.blue))
                }

                // Subtle id line
                HStack {
                    let idText: String = info.backendId?.uuidString ?? info.localId.uuidString
                    Text("ID: \(shortId(idText))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.55))
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Circle().fill(Color.red.opacity(0.92)))
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .offset(x: 10, y: -10)
            }
        }
    }
}

// MARK: - Small helpers

private func meterString(_ v: Float) -> String {
    String(format: "%.3fm", v)
}

private func centerString(x: Float, y: Float, z: Float) -> String {
    "x: " + String(format: "%.3f", x) + "  y: " + String(format: "%.3f", y) + "  z: " + String(format: "%.3f", z)
}

@ViewBuilder
private func labeledPair(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
        Text(value)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

// MARK: - Metric chips and labels (visuals to match the provided mock)

private func shortValueString(_ v: Float) -> String {
    String(format: "%.3f", v)
}

// Compact UUID display like ABC123… for readability
private func shortId(_ full: String, prefix: Int = 6) -> String {
    let clean = full.uppercased()
    if clean.count <= prefix { return clean }
    let head = clean.prefix(prefix)
    return String(head)
}

@ViewBuilder
private func axisLabel(_ s: String) -> some View {
    Text(s)
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(.white.opacity(0.85))
        .frame(width: 18)
}

private func axisRow(axis1: (String, Float, Color), axis2: (String, Float, Color)) -> some View {
    HStack(spacing: 24) {
        axisLabel(axis1.0)
        MetricChip(value: shortValueString(axis1.1), tint: axis1.2)
        axisLabel(axis2.0)
        MetricChip(value: shortValueString(axis2.1), tint: axis2.2)
    }
}

@ViewBuilder
private func coordChip(label: String, value: Float, tint: Color) -> some View {
    HStack(spacing: 6) {
        axisLabel(label)
        MetricChip(value: shortValueString(value), tint: tint)
    }
}

@ViewBuilder private func metricGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title)
            .font(.system(size: 19, weight: .semibold))
            .foregroundColor(.white.opacity(0.95))
        content()
    }
}

private func placeholderChip(_ value: String) -> some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(0.12))
        .frame(width: 84, height: 40)
        .overlay(
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
        )
}

private struct MetricChip: View {
    let value: String
    let tint: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.95))
            .frame(width: 84, height: 40)
            .overlay(
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Helper to detect calibrated difference

private func calibratedDiffersFromRaw(calibrated: SIMD3<Float>, rawX: Float, rawZ: Float) -> Bool {
    let epsilon: Float = 1e-6
    let xDiffers = abs(calibrated.x - rawX) > epsilon
    let zDiffers = abs(calibrated.z - rawZ) > epsilon
    return xDiffers || zDiffers
}
