//
//  SpaceModeDock.swift
//  roboscope2
//
//  Vertical Liquid Glass dock with two segments: 3D VIEW | SCAN
//

import SwiftUI

struct SpaceModeDock: View {
    @Binding var selected: SpaceMode
    var has3D: Bool
    var onChange: ((SpaceMode) -> Void)?

    @Namespace private var ns

    var body: some View {
        ZStack {
            // Glass container background
            RoundedRectangle(cornerRadius: 44, style: .continuous)
                .fill(Color.clear)
                .frame(width: 120)
                .lgCapsule(tint: .white) // reuse capsule styling for glass; rounded rect is visually similar
                .opacity(0.98)

            VStack(spacing: 0) {
                segment(
                    title: "3D\nVIEW",
                    systemImage: "cube",
                    mode: .view3D,
                    enabled: has3D
                )

                Divider()
                    .background(Color.white.opacity(0.2))
                    .frame(height: 1)
                    .padding(.vertical, 8)

                segment(
                    title: "SC\nAN",
                    systemImage: "scanner",
                    mode: .scan,
                    enabled: true
                )
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("View switcher")
        .accessibilityValue(selected == .view3D ? "3D View" : "Scan")
    }

    @ViewBuilder
    private func segment(title: String, systemImage: String, mode: SpaceMode, enabled: Bool) -> some View {
        let isSelected = selected == mode

        Button(action: {
            guard enabled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selected = mode
            }
            onChange?(mode)
        }) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                        .matchedGeometryEffect(id: "dockHighlight", in: ns)
                        .padding(2)
                }

                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.headline)
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.leading)
                }
                .foregroundColor(
                    enabled ? (isSelected ? .white : Color.white.opacity(0.92)) : Color.white.opacity(0.4)
                )
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        SpaceModeDock(selected: .constant(.scan), has3D: true, onChange: { _ in })
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
