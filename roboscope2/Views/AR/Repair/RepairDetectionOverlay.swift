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
import UIKit

struct RepairDetectionOverlay: View {
    let detections: [RepairDetection]
    let viewSize: CGSize
    /// Maps normalized image coordinates to normalized view coordinates.
    let imageToViewTransform: CGAffineTransform
    var boxColor: Color = .green
    /// Per-class marker color (from the active model's `RepairClassStyle.color`, v0.2), used when
    /// present so Validation mode's "highlight different classes" reads visually the same way
    /// Planning's pin colors do. Falls back to `boxColor` for any class without a configured color.
    var classStyles: [String: RepairClassStyle]? = nil
    /// When true, draws `detection.maskPolygon` (filled + stroked, YOLOv8-segmentation only) in
    /// place of the plain rectangle, for any detection that has one — falling back to the
    /// rectangle for detections without a polygon (plain-detect models, or extraction miss).
    /// Off by default so Planning's debug overlay keeps its existing plain-box look; Validation
    /// mode's passive overlay turns this on.
    var showMaskPolygon: Bool = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(detections) { detection in
                    let color = resolvedColor(for: detection.label)
                    let polygonPoints = showMaskPolygon ? mappedPolygon(detection.maskPolygon, viewSize: geometry.size) : nil

                    if let polygonPoints, polygonPoints.count >= 3 {
                        let labelAnchor = polygonPoints.min(by: { $0.y < $1.y }) ?? polygonPoints[0]
                        ZStack(alignment: .topLeading) {
                            Path { path in
                                path.move(to: polygonPoints[0])
                                for p in polygonPoints.dropFirst() { path.addLine(to: p) }
                                path.closeSubpath()
                            }
                            .fill(color.opacity(0.28))

                            Path { path in
                                path.move(to: polygonPoints[0])
                                for p in polygonPoints.dropFirst() { path.addLine(to: p) }
                                path.closeSubpath()
                            }
                            .stroke(color, lineWidth: 2)

                            Text("\(detection.label) \(String(format: "%.2f", detection.confidence))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.85))
                                .position(x: labelAnchor.x + 30, y: max(8, labelAnchor.y - 8))
                        }
                    } else {
                        let rect = mappedRect(detection.boundingBox, viewSize: geometry.size)
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .stroke(color, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)

                            Text("\(detection.label) \(String(format: "%.2f", detection.confidence))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(color.opacity(0.85))
                                .position(x: rect.minX + 30, y: max(8, rect.minY - 8))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func resolvedColor(for label: String) -> Color {
        if let hex = classStyles?[label]?.color, let uiColor = UIColor(hex: hex) {
            return Color(uiColor)
        }
        return boxColor
    }

    /// Maps each polygon point (normalized image space, top-left origin — same space as
    /// `boundingBox`) through `imageToViewTransform` then scales into on-screen points, same
    /// per-point approach as `mappedRect`'s corners.
    private func mappedPolygon(_ polygon: [CGPoint]?, viewSize: CGSize) -> [CGPoint]? {
        guard let polygon, polygon.count >= 3 else { return nil }
        return polygon.map { p in
            let viewNorm = p.applying(imageToViewTransform)
            return CGPoint(x: viewNorm.x * viewSize.width, y: viewNorm.y * viewSize.height)
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
