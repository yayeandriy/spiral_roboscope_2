//
//  EdgeDistanceView.swift
//  roboscope2
//
//  Small stat view used inside marker badge.
//

import SwiftUI

struct EdgeDistanceView: View {
    let label: String
    let distance: Float
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color.opacity(0.95))
            Text(String(format: "%.2f m", distance))
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .foregroundColor(.white)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.5), lineWidth: 1)
                )
        )
        .frame(minWidth: 56)
    }
}
