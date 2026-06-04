//
//  LiquidGlassModifiers.swift
//  roboscope2
//
//  Shared Liquid Glass style modifiers used across the app.
//

import SwiftUI

// MARK: - Liquid Glass Helpers (iOS 18+ with graceful fallback)

extension View {
    @ViewBuilder
    func lgCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 18.0, *) {
            let appliedTint = tint ?? .white
            self
                .tint(appliedTint)
                .glassEffect(in: .capsule)
        } else {
            let appliedTint = tint ?? .white
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.25)))
                .overlay(Capsule().fill(appliedTint.opacity(0.18)))
        }
    }

    @ViewBuilder
    func lgCircle(tint: Color? = nil) -> some View {
        if #available(iOS 18.0, *) {
            let appliedTint = tint ?? .white
            self
                .tint(appliedTint)
                .glassEffect(in: .circle)
        } else {
            let appliedTint = tint ?? .white
            self
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25)))
                .overlay(Circle().fill(appliedTint.opacity(0.18)))
        }
    }
}
