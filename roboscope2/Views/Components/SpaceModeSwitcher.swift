//
//  SpaceModeSwitcher.swift
//  roboscope2
//
//  A reusable Liquid Glass two-state switcher: "3D View" | "Scan"
//

import SwiftUI

enum SpaceMode: Hashable {
    case view3D
    case scan
}

struct SpaceModeSwitcher: View {
    @Binding var selected: SpaceMode
    var has3D: Bool
    var onChange: ((SpaceMode) -> Void)?

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            segment(
                title: "3D VIEW",
                systemImage: "cube",
                mode: .view3D,
                enabled: has3D
            )

            Divider()
                .frame(height: 22)
                .background(Color.white.opacity(0.18))
                .padding(.horizontal, 4)

            segment(
                title: "SCAN",
                systemImage: "scanner",
                mode: .scan,
                enabled: true
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .lgCapsule(tint: .white)
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
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.25))
                        .matchedGeometryEffect(id: "highlight", in: ns)
                        .transition(.opacity)
                }

                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                    Text(title)
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(
                    enabled ? (isSelected ? .white : Color.white.opacity(0.9)) : Color.white.opacity(0.35)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .contentShape(Rectangle())
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        SpaceModeSwitcher(selected: .constant(.scan), has3D: true, onChange: { _ in })
    }
}
