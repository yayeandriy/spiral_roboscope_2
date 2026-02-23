//
//  LaserMLDetectionOverlay.swift
//  roboscope2
//
//  Draws ML detection bounding boxes over the AR view.
//

import SwiftUI
import RealityKit
import ARKit

struct LaserMLDetectionOverlay: View {
    let detections: [LaserMLDetection]
    let viewSize: CGSize
    /// Maps normalized image coordinates to normalized view coordinates.
    let imageToViewTransform: CGAffineTransform
    let arView: ARView?
    let maxDotLineYDeltaMeters: Float
    let onDotLineMeasurement: ((LaserDotLineMeasurement?) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(detections) { detection in
                    if let quad = detection.orientedQuad {
                        let mapped = mappedQuad(quad, viewSize: geometry.size)
                        Path { path in
                            path.move(to: mapped.p1)
                            path.addLine(to: mapped.p2)
                            path.addLine(to: mapped.p3)
                            path.addLine(to: mapped.p4)
                            path.closeSubpath()
                        }
                        .stroke(Color.green, lineWidth: 2)
                        .overlay(alignment: .topLeading) {
                            let labelRect = boundingRect(for: [mapped.p1, mapped.p2, mapped.p3, mapped.p4])
                            Text("\(detection.label) \(String(format: "%.0f%%", detection.confidence * 100))")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.green)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                                .position(x: labelRect.minX + 40, y: labelRect.minY - 10)
                        }
                    } else {
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
            }
            .allowsHitTesting(false)
            .onChange(of: detections) { _, newDetections in
                measureDistanceBetweenDotAndLine(newDetections, viewSize: geometry.size)
            }
            .onChange(of: maxDotLineYDeltaMeters) { _, _ in
                measureDistanceBetweenDotAndLine(detections, viewSize: geometry.size)
            }
        }
    }

    /// ML version of the legacy dot/line measurement:
    /// - classIndex 0 => dot
    /// - classIndex 1 => line
    private func measureDistanceBetweenDotAndLine(_ detections: [LaserMLDetection], viewSize: CGSize) {
        guard let arView else {
            onDotLineMeasurement?(nil)
            return
        }

        // Choose best dot by confidence.
        guard let dot = detections
            .filter({ isDot($0) })
            .max(by: { $0.confidence < $1.confidence }) else {
            onDotLineMeasurement?(nil)
            return
        }

        guard let dotWorld = raycastWorldPosition(for: dot, arView: arView, viewSize: viewSize) else {
            onDotLineMeasurement?(nil)
            return
        }

        // Consider line candidates, but only accept those within Y tolerance.
        let tolerance = maxDotLineYDeltaMeters
        let lineCandidates = detections
            .filter({ isLine($0) })
            .sorted(by: { $0.confidence > $1.confidence })

        var chosenLineWorld: simd_float4?
        for candidate in lineCandidates {
            guard let lineWorld = raycastWorldPosition(for: candidate, arView: arView, viewSize: viewSize) else {
                continue
            }
            if abs(lineWorld.y - dotWorld.y) <= tolerance {
                chosenLineWorld = lineWorld
                break
            }
        }

        guard let lineWorld = chosenLineWorld else {
            onDotLineMeasurement?(nil)
            return
        }

        let dx = dotWorld.x - lineWorld.x
        let dy = dotWorld.y - lineWorld.y
        let dz = dotWorld.z - lineWorld.z
        let distance = sqrt(dx * dx + dy * dy + dz * dz)
        onDotLineMeasurement?(LaserDotLineMeasurement(
            dotWorld: SIMD3<Float>(dotWorld.x, dotWorld.y, dotWorld.z),
            lineWorld: SIMD3<Float>(lineWorld.x, lineWorld.y, lineWorld.z),
            distanceMeters: distance
        ))
    }

    private func isDot(_ d: LaserMLDetection) -> Bool {
        if let idx = d.classIndex { return idx == 0 }
        return d.label.lowercased().contains("dot")
    }

    private func isLine(_ d: LaserMLDetection) -> Bool {
        if let idx = d.classIndex { return idx == 1 }
        return d.label.lowercased().contains("line")
    }

    private func raycastWorldPosition(for detection: LaserMLDetection, arView: ARView, viewSize: CGSize) -> simd_float4? {
        // Center in normalized image coordinates.
        let centerNormImg = CGPoint(x: detection.boundingBox.midX, y: detection.boundingBox.midY)

        // Transform to normalized view coordinates.
        let centerNormView = centerNormImg.applying(imageToViewTransform)

        // Convert to pixel coordinates.
        let centerPx = CGPoint(
            x: centerNormView.x * viewSize.width,
            y: centerNormView.y * viewSize.height
        )

        let results = arView.raycast(from: centerPx, allowing: .existingPlaneGeometry, alignment: .any)
        let hit = results.first ?? arView.raycast(from: centerPx, allowing: .estimatedPlane, alignment: .any).first
        return hit?.worldTransform.columns.3
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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

    private func mappedPoint(_ pNormImgTopLeft: CGPoint, viewSize: CGSize) -> CGPoint {
        let p = pNormImgTopLeft.applying(imageToViewTransform)
        return CGPoint(x: p.x * viewSize.width, y: p.y * viewSize.height)
    }

    private func mappedQuad(_ quad: LaserMLOrientedQuad, viewSize: CGSize) -> LaserMLOrientedQuad {
        LaserMLOrientedQuad(
            p1: mappedPoint(quad.p1, viewSize: viewSize),
            p2: mappedPoint(quad.p2, viewSize: viewSize),
            p3: mappedPoint(quad.p3, viewSize: viewSize),
            p4: mappedPoint(quad.p4, viewSize: viewSize)
        )
    }
}

#Preview {
    LaserMLDetectionOverlay(
        detections: [
            LaserMLDetection(
                boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.2, height: 0.15),
                orientedQuad: LaserMLOrientedQuad(
                    p1: CGPoint(x: 0.2, y: 0.3),
                    p2: CGPoint(x: 0.38, y: 0.28),
                    p3: CGPoint(x: 0.40, y: 0.42),
                    p4: CGPoint(x: 0.22, y: 0.44)
                ),
                classIndex: 0,
                label: "dot",
                confidence: 0.91,
                timestamp: Date()
            ),
            LaserMLDetection(boundingBox: CGRect(x: 0.55, y: 0.45, width: 0.3, height: 0.2), orientedQuad: nil, classIndex: 1, label: "line", confidence: 0.74, timestamp: Date())
        ],
        viewSize: CGSize(width: 400, height: 700),
        imageToViewTransform: .identity,
        arView: nil,
        maxDotLineYDeltaMeters: 0.05,
        onDotLineMeasurement: nil
    )
    .background(Color.gray.opacity(0.3))
}
