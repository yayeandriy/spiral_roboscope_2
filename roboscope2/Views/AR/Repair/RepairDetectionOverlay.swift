//
//  RepairDetectionOverlay.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied from Views/AR/LaserGuide/LaserMLDetectionOverlay.swift (READ-ONLY reference) per
//  05-ios-repair.md §5.2. Keeps the `mappedRect` transform math and `imageToViewTransform`
//  usage. STRIPS the dot/line measurement callbacks — Repair only needs debug bboxes, no
//  measurement. Optional; useful for on-device tuning of the auto-placer thresholds, not
//  required for RepairAutoPlacer to function (it consumes raw detections directly).
//

import SwiftUI

struct RepairDetectionOverlay: View {
    let detections: [RepairDetection]
    let viewSize: CGSize
    /// Maps normalized image coordinates to normalized view coordinates.
    let imageToViewTransform: CGAffineTransform
    var boxColor: Color = .green

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(detections) { detection in
                    let rect = mappedRect(detection.boundingBox, viewSize: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .stroke(boxColor, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)

                        Text("\(detection.label) \(String(format: "%.2f", detection.confidence))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(boxColor.opacity(0.85))
                            .position(x: rect.minX + 30, y: max(8, rect.minY - 8))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func mappedRect(_ rectNormImgTopLeft: CGRect, viewSize: CGSize) -> CGRect {
        // Map all 4 corners through the display transform to properly handle rotation/aspect.
        let p1 = CGPoint(x: rectNormImgTopLeft.minX, y: rectNormImgTopLeft.minY).applying(imageToViewTransform)
        let p2 = CGPoint(x: rectNormImgTopLeft.maxX, y: rectNormImgTopLeft.minY).applying(imageToViewTransform)
        let p3 = CGPoint(x: rectNormImgTopLeft.minX, y: rectNormImgTopLeft.maxY).applying(imageToViewTransform)
        let p4 = CGPoint(x: rectNormImgTopLeft.maxX, y: rectNormImgTopLeft.maxY).applying(imageToViewTransform)

        let xs = [p1.x, p2.x, p3.x, p4.x]
        let ys = [p1.y, p2.y, p3.y, p4.y]

        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0

        let mapped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        return CGRect(
            x: mapped.origin.x * viewSize.width,
            y: mapped.origin.y * viewSize.height,
            width: mapped.size.width * viewSize.width,
            height: mapped.size.height * viewSize.height
        )
    }
}

#Preview {
    RepairDetectionOverlay(
        detections: [
            RepairDetection(
                boundingBox: CGRect(x: 0.3, y: 0.4, width: 0.15, height: 0.15),
                classIndex: 0,
                label: "object",
                confidence: 0.87,
                timestamp: Date()
            )
        ],
        viewSize: CGSize(width: 390, height: 844),
        imageToViewTransform: .identity
    )
    .background(Color.gray.opacity(0.3))
}
