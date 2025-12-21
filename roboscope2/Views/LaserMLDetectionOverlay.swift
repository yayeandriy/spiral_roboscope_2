//
//  LaserMLDetectionOverlay.swift
//  roboscope2
//
//  Draws ML detection bounding boxes over the AR view.
//

import SwiftUI

struct LaserMLDetectionOverlay: View {
    let detections: [LaserMLDetection]
    let viewSize: CGSize
    /// Maps normalized image coordinates to normalized view coordinates.
    let imageToViewTransform: CGAffineTransform

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(detections) { detection in
                    let rect = mappedRect(detection.boundingBox, viewSize: geometry.size)
                    Rectangle()
                        .stroke(Color.green, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .overlay(alignment: .topLeading) {
                            Text("\(detection.label) \(String(format: "%.0f%%", detection.confidence * 100))")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.green)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                                .position(x: rect.minX + 40, y: rect.minY - 10)
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
    LaserMLDetectionOverlay(
        detections: [
            LaserMLDetection(boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.15), label: "dot", confidence: 0.91, timestamp: Date()),
            LaserMLDetection(boundingBox: CGRect(x: 0.55, y: 0.45, width: 0.3, height: 0.2), label: "line", confidence: 0.74, timestamp: Date())
        ],
        viewSize: CGSize(width: 400, height: 700),
        imageToViewTransform: .identity
    )
    .background(Color.gray.opacity(0.3))
}
