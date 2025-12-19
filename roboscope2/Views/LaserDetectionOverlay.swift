//
//  LaserDetectionOverlay.swift
//  roboscope2
//
//  Overlay view showing detected laser points with bounding boxes
//

import SwiftUI
import RealityKit
import ARKit

struct LaserDotLineMeasurement: Equatable {
    let dotWorld: SIMD3<Float>
    let lineWorld: SIMD3<Float>
    let distanceMeters: Float
}

struct LaserDetectionOverlay: View {
    let detectedPoints: [LaserPoint]
    let viewSize: CGSize
    @ObservedObject var laserService: LaserDetectionService
    /// Maps normalized image coordinates to normalized view coordinates.
    let imageToViewTransform: CGAffineTransform
    let arView: ARView?
    let onDotLineMeasurement: ((LaserDotLineMeasurement?) -> Void)?

    private var filteredForDisplay: [LaserPoint] {
        // Display max one dot and max one line.
        // We do not apply Y filtering here because it requires raycasting; that is handled
        // inside measureDistanceBetweenDotAndLine(_:viewSize:).
        let dot = detectedPoints
            .filter { $0.shape == .rounded }
            .max(by: { $0.brightness < $1.brightness })

        let line = detectedPoints
            .filter { $0.shape == .lineSegment }
            .max(by: { $0.brightness < $1.brightness })

        return [dot, line].compactMap { $0 }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Bounding boxes
                ForEach(filteredForDisplay) { point in
                    LaserBoundingBox(
                        point: point,
                        viewSize: geometry.size
                        , imageToViewTransform: imageToViewTransform
                    )
                }
            }
            .allowsHitTesting(false)
            .onChange(of: detectedPoints) { _, newPoints in
                measureDistanceBetweenDotAndLine(newPoints, viewSize: geometry.size)
            }
            .onChange(of: laserService.maxDotLineYDeltaMeters) { _, _ in
                measureDistanceBetweenDotAndLine(detectedPoints, viewSize: geometry.size)
            }
        }
    }
    
    /// Measure real-world distance between the chosen dot and line using raycasts.
    /// Filters to max one dot + one line, and only accepts lines whose world-space Y
    /// is within `laserService.maxDotLineYDeltaMeters` of the dot's Y.
    private func measureDistanceBetweenDotAndLine(_ points: [LaserPoint], viewSize: CGSize) {
        guard let arView = arView else {
            onDotLineMeasurement?(nil)
            return
        }
        // Pick best dot by brightness.
        guard let dot = points.filter({ $0.shape == .rounded }).max(by: { $0.brightness < $1.brightness }) else {
            onDotLineMeasurement?(nil)
            return
        }

        // Raycast dot to world.
        guard let dotWorld = raycastWorldPosition(for: dot, arView: arView, viewSize: viewSize) else {
            onDotLineMeasurement?(nil)
            return
        }

        // Consider line candidates, but only accept those within Y tolerance.
        let tolerance = laserService.maxDotLineYDeltaMeters
        let lineCandidates = points.filter { $0.shape == .lineSegment }.sorted { $0.brightness > $1.brightness }

        var chosenLine: LaserPoint?
        var chosenLineWorld: simd_float4?

        for candidate in lineCandidates {
            guard let lineWorld = raycastWorldPosition(for: candidate, arView: arView, viewSize: viewSize) else {
                continue
            }
            if abs(lineWorld.y - dotWorld.y) <= tolerance {
                chosenLine = candidate
                chosenLineWorld = lineWorld
                break
            }
        }

        guard let lineWorld = chosenLineWorld, chosenLine != nil else {
            onDotLineMeasurement?(nil)
            return
        }

        // Calculate 3D distance between dot and line hit points.
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

    private func raycastWorldPosition(for point: LaserPoint, arView: ARView, viewSize: CGSize) -> simd_float4? {
        // Get center positions in normalized image coordinates
        let centerNormImg = CGPoint(x: point.boundingBox.midX, y: point.boundingBox.midY)

        // Transform to normalized view coordinates
        let centerNormView = centerNormImg.applying(imageToViewTransform)

        // Convert to pixel coordinates
        let centerPx = CGPoint(
            x: centerNormView.x * viewSize.width,
            y: centerNormView.y * viewSize.height
        )

        // Perform raycasts from this screen position
        let results = arView.raycast(from: centerPx, allowing: .existingPlaneGeometry, alignment: .any)
        let hit = results.first ?? arView.raycast(from: centerPx, allowing: .estimatedPlane, alignment: .any).first
        return hit?.worldTransform.columns.3
    }
}

struct LaserBoundingBox: View {
    let point: LaserPoint
    let viewSize: CGSize
    let imageToViewTransform: CGAffineTransform

    private struct RenderBox {
        let centerPx: CGPoint
        let widthPx: CGFloat
        let heightPx: CGFloat
        let rotationRadians: CGFloat
        let labelAnchor: CGPoint
    }
    
    private var frameRect: CGRect {
        // point.boundingBox is in normalized image coordinates (0-1).
        // Use displayTransform to map center point correctly (handles rotation/aspect).
        let rect = point.boundingBox
        
        // Transform center from normalized image space to normalized view space
        let centerNormImg = CGPoint(x: rect.midX, y: rect.midY)
        let centerNormView = centerNormImg.applying(imageToViewTransform)
        
        // For size, we need to account for potential 90° rotation.
        // Extract the scale components from the transform.
        let a = imageToViewTransform.a
        let b = imageToViewTransform.b
        let c = imageToViewTransform.c
        let d = imageToViewTransform.d
        
        // Calculate effective scale factors
        let scaleX = sqrt(a * a + c * c)
        let scaleY = sqrt(b * b + d * d)
        
        // Apply scale to size (in normalized coordinates)
        let widthNormView = abs(rect.width * scaleX)
        let heightNormView = abs(rect.height * scaleY)
        
        // Convert to pixel coordinates
        let centerPx = CGPoint(
            x: centerNormView.x * viewSize.width,
            y: centerNormView.y * viewSize.height
        )
        let widthPx = widthNormView * viewSize.width
        let heightPx = heightNormView * viewSize.height
        
        return CGRect(
            x: centerPx.x - widthPx / 2,
            y: centerPx.y - heightPx / 2,
            width: widthPx,
            height: heightPx
        )
    }

    private var orientedRenderBox: RenderBox? {
        guard point.shape == .lineSegment, let obb = point.orientedLineBox else { return nil }
        let imageW = max(1.0, point.imageSize.width)
        let imageH = max(1.0, point.imageSize.height)

        // Center in normalized image coordinates.
        let centerNormImg = obb.centerNorm
        let centerNormView = centerNormImg.applying(imageToViewTransform)
        let centerPx = CGPoint(x: centerNormView.x * viewSize.width, y: centerNormView.y * viewSize.height)

        // Build 1-pixel step vectors in normalized image coords, then map through transform.
        let cosA = cos(obb.angleRadians)
        let sinA = sin(obb.angleRadians)

        let dirDeltaNorm = CGPoint(x: CGFloat(cosA) / imageW, y: CGFloat(sinA) / imageH)
        let perpDeltaNorm = CGPoint(x: CGFloat(-sinA) / imageW, y: CGFloat(cosA) / imageH)

        let dirEndNormView = CGPoint(x: centerNormImg.x + dirDeltaNorm.x, y: centerNormImg.y + dirDeltaNorm.y)
            .applying(imageToViewTransform)
        let perpEndNormView = CGPoint(x: centerNormImg.x + perpDeltaNorm.x, y: centerNormImg.y + perpDeltaNorm.y)
            .applying(imageToViewTransform)

        let dirVecPx = CGVector(
            dx: (dirEndNormView.x - centerNormView.x) * viewSize.width,
            dy: (dirEndNormView.y - centerNormView.y) * viewSize.height
        )
        let perpVecPx = CGVector(
            dx: (perpEndNormView.x - centerNormView.x) * viewSize.width,
            dy: (perpEndNormView.y - centerNormView.y) * viewSize.height
        )

        let dirPerPixel = max(1e-6, hypot(dirVecPx.dx, dirVecPx.dy))
        let perpPerPixel = max(1e-6, hypot(perpVecPx.dx, perpVecPx.dy))

        let widthPx = dirPerPixel * obb.lengthPx
        let heightPx = perpPerPixel * obb.thicknessPx

        let rotation = CGFloat(atan2(dirVecPx.dy, dirVecPx.dx))

        let labelAnchor = CGPoint(x: centerPx.x, y: centerPx.y - heightPx / 2 - 14)

        return RenderBox(
            centerPx: centerPx,
            widthPx: widthPx,
            heightPx: heightPx,
            rotationRadians: rotation,
            labelAnchor: labelAnchor
        )
    }
    
    var body: some View {
        Group {
            if let obb = orientedRenderBox {
                Rectangle()
                    .stroke(Color.red, lineWidth: 2)
                    .frame(width: obb.widthPx, height: obb.heightPx)
                    .rotationEffect(.radians(obb.rotationRadians))
                    .position(x: obb.centerPx.x, y: obb.centerPx.y)
                    .overlay {
                        Text("\(point.shape.displayName) \(String(format: "%.0f%%", point.brightness * 100))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .position(x: obb.labelAnchor.x, y: obb.labelAnchor.y)
                    }
            } else {
                Rectangle()
                    .stroke(Color.red, lineWidth: 2)
                    .frame(width: frameRect.width, height: frameRect.height)
                    .position(x: frameRect.midX, y: frameRect.midY)
                    .overlay(alignment: .topLeading) {
                        // Brightness and shape indicator
                        Text("\(point.shape.displayName) \(String(format: "%.0f%%", point.brightness * 100))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                            .padding(4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .position(x: frameRect.minX + 30, y: frameRect.minY - 10)
                    }
            }
        }
        .animation(.easeOut(duration: 0.1), value: point.boundingBox)
    }
}

#Preview {
    LaserDetectionOverlay(
        detectedPoints: [
            LaserPoint(
                boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.08),
                brightness: 0.92,
                timestamp: Date(),
                imageSize: CGSize(width: 1920, height: 1440),
                shape: .rounded,
                orientedLineBox: nil
            ),
            LaserPoint(
                boundingBox: CGRect(x: 0.6, y: 0.5, width: 0.05, height: 0.05),
                brightness: 0.87,
                timestamp: Date(),
                imageSize: CGSize(width: 1920, height: 1440),
                shape: .lineSegment,
                orientedLineBox: LaserOrientedLineBox(
                    centerNorm: CGPoint(x: 0.625, y: 0.525),
                    angleRadians: .pi / 4,
                    lengthPx: 400,
                    thicknessPx: 18
                )
            )
        ],
        viewSize: CGSize(width: 400, height: 600),
        laserService: LaserDetectionService(),
        imageToViewTransform: .identity,
        arView: nil,
        onDotLineMeasurement: nil
    )
    .background(Color.gray.opacity(0.3))
}
