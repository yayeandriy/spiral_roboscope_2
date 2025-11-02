//
//  SpaceTileView.swift
//  roboscope2
//
//  Square card component for a Space item.
//

import SwiftUI

struct SpaceTileView: View {
    let space: Space
    var onDelete: (() -> Void)? = nil
    var onView3D: (() -> Void)? = nil
    var onScan: (() -> Void)? = nil

    @Environment(
        \.colorScheme
    ) private var colorScheme
    
    private var has3DModels: Bool { space.has3DContent }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(cardStrokeColor, lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(space.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let description = space.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Spacer(minLength: 0)
                }

                Spacer()

                HStack(spacing: 12) {
                    modelBadge("FRA", present: space.modelGlbUrl != nil, color: .green)
                    modelBadge("REF", present: space.modelUsdcUrl != nil, color: .blue)
                    modelBadge("SCAN", present: space.scanUrl != nil, color: .orange)
                    Spacer()
                }
            }
            .padding(16)
        }
        .aspectRatio(1, contentMode: .fit)
        .contextMenu {
            if has3DModels, let onView3D {
                Button { onView3D() } label: {
                    Label("View 3D Models", systemImage: "cube")
                }
            }
            if let onScan {
                Button { onScan() } label: {
                    Label("Scan Space", systemImage: "camera.metering.center.weighted")
                }
            }
            if let onDelete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func modelBadge(_ text: String, present: Bool, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(present ? color : .secondary)
            .opacity(present ? 1.0 : 0.6)
    }

    private var cardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
}
