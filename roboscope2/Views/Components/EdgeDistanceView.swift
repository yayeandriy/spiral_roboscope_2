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
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color.opacity(0.8))
            Text(String(format: "%.2f", distance))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(minWidth: 40)
    }
}
