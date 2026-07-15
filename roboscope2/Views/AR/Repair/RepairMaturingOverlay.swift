//
//  RepairMaturingOverlay.swift
//  roboscope2
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Shows a small circular progress ring over any object that is currently being tracked by
//  RepairAutoPlacer but hasn't accumulated enough confirmed hits to become a pin yet — lets the
//  operator see "this is being recognized, hold steady" before the pin actually appears. Always
//  visible (unlike RepairDetectionOverlay's raw debug boxes, which are opt-in).
//

import SwiftUI

struct RepairMaturingOverlay: View {
    /// (stable candidate id, normalized image-space bbox top-left, 0...1 progress toward confirm)
    let candidates: [(id: UUID, bbox: CGRect, progress: Float)]
    let viewSize: CGSize
    let imageToViewTransform: CGAffineTransform

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(candidates, id: \.id) { candidate in
                    let center = mappedCenter(candidate.bbox, viewSize: geometry.size)
                    ProgressRing(progress: CGFloat(candidate.progress))
                        .frame(width: 34, height: 34)
                        .position(center)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func mappedCenter(_ rectNormImgTopLeft: CGRect, viewSize: CGSize) -> CGPoint {
        let p = CGPoint(x: rectNormImgTopLeft.midX, y: rectNormImgTopLeft.midY).applying(imageToViewTransform)
        return CGPoint(x: p.x * viewSize.width, y: p.y * viewSize.height)
    }
}

/// A minimal circular "filling up" indicator — track ring + progress arc, no text.
private struct ProgressRing: View {
    let progress: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview {
    RepairMaturingOverlay(
        candidates: [
            (id: UUID(), bbox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1), progress: 0.6)
        ],
        viewSize: CGSize(width: 390, height: 844),
        imageToViewTransform: .identity
    )
    .background(Color.gray.opacity(0.3))
}
