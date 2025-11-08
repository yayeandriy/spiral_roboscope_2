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
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 20) {
                // Raw center row
                metricGroup(title: "Raw center") {
                    axisRow(axis1: ("x", info.centerX, Color.red), axis2: ("z", info.centerZ, Color.blue))
                }
                // Calibrated center row
                metricGroup(title: "Calibrated center") {
                    if let c = info.calibratedCenter {
                        axisRow(axis1: ("x", c.x, Color.red), axis2: ("z", c.z, Color.blue))
                    } else {
                        HStack(spacing: 24) {
                            axisLabel("x")
                            placeholderChip("—")
                            axisLabel("z")
                            placeholderChip("—")
                        }
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
