//
//  LaserDetectionOverlay.swift
//  roboscope2
//
//  Overlay view showing detected laser points with bounding boxes
//

import SwiftUI
import RealityKit
import ARKit

struct LaserDetectionOverlay: View {
    let detectedPoints: [LaserPoint]
    let viewSize: CGSize
    @ObservedObject var laserService: LaserDetectionService
    /// Maps normalized image coordinates to normalized view coordinates.
    let imageToViewTransform: CGAffineTransform
    let arView: ARView?
    @State private var showControls = false
    @State private var measuredDistance: Float?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Toggle controls button
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showControls.toggle()
                        } label: {
                            Image(systemName: showControls ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial)
                                )
                        }
                        .padding(.top, 100)
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
                
                // Threshold slider
                if showControls {
                    VStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Text("Brightness Threshold")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            
                            HStack {
                                Text("\(Int(laserService.brightnessThreshold * 100))%")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.yellow)
                                    .frame(width: 40)
                                
                                Slider(value: $laserService.brightnessThreshold, in: 0.5...0.99)
                                    .tint(.yellow)
                                
                                Text("Points: \(detectedPoints.count)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.yellow)
                                    .frame(width: 70)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 120)
                    }
                }
                
                // Bounding boxes
                ForEach(detectedPoints) { point in
                    LaserBoundingBox(
                        point: point,
                        viewSize: geometry.size
                        , imageToViewTransform: imageToViewTransform
                    )
                }
                
                // Distance measurement display
                if let distance = measuredDistance {
                    VStack {
                        Spacer()
                        Text(String(format: "%.2f m", distance))
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundColor(.yellow)
                            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                            .padding(.bottom, 40)
                    }
                }
            }
            .allowsHitTesting(showControls) // Only intercept touches when controls are visible
            .onChange(of: detectedPoints) { _, newPoints in
                measureDistanceBetweenPoints(newPoints, viewSize: geometry.size)
            }
        }
    }
    
    /// Measure real-world distance between detected laser points using raycasts
    private func measureDistanceBetweenPoints(_ points: [LaserPoint], viewSize: CGSize) {
        guard let arView = arView, points.count >= 2 else {
            measuredDistance = nil
            return
        }
        
        // Get screen positions of the two brightest points
        let sortedPoints = points.sorted { $0.brightness > $1.brightness }
        let point1 = sortedPoints[0]
        let point2 = sortedPoints[1]
        
        // Get center positions in normalized image coordinates
        let center1NormImg = CGPoint(x: point1.boundingBox.midX, y: point1.boundingBox.midY)
        let center2NormImg = CGPoint(x: point2.boundingBox.midX, y: point2.boundingBox.midY)
        
        // Transform to normalized view coordinates
        let center1NormView = center1NormImg.applying(imageToViewTransform)
        let center2NormView = center2NormImg.applying(imageToViewTransform)
        
        // Convert to pixel coordinates
        let center1Px = CGPoint(
            x: center1NormView.x * viewSize.width,
            y: center1NormView.y * viewSize.height
        )
        let center2Px = CGPoint(
            x: center2NormView.x * viewSize.width,
            y: center2NormView.y * viewSize.height
        )
        
        // Perform raycasts from these screen positions
        let results1 = arView.raycast(from: center1Px, allowing: .existingPlaneGeometry, alignment: .any)
        let results2 = arView.raycast(from: center2Px, allowing: .existingPlaneGeometry, alignment: .any)
        
        // If no plane hits, try estimatedPlane
        let hit1 = results1.first ?? arView.raycast(from: center1Px, allowing: .estimatedPlane, alignment: .any).first
        let hit2 = results2.first ?? arView.raycast(from: center2Px, allowing: .estimatedPlane, alignment: .any).first
        
        guard let worldPos1 = hit1?.worldTransform.columns.3,
              let worldPos2 = hit2?.worldTransform.columns.3 else {
            measuredDistance = nil
            return
        }
        
        // Calculate 3D distance
        let dx = worldPos1.x - worldPos2.x
        let dy = worldPos1.y - worldPos2.y
        let dz = worldPos1.z - worldPos2.z
        let distance = sqrt(dx * dx + dy * dy + dz * dz)
        
        measuredDistance = distance
    }
}

struct LaserBoundingBox: View {
    let point: LaserPoint
    let viewSize: CGSize
    let imageToViewTransform: CGAffineTransform
    
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
    
    var body: some View {
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
                shape: .rounded
            ),
            LaserPoint(
                boundingBox: CGRect(x: 0.6, y: 0.5, width: 0.05, height: 0.05),
                brightness: 0.87,
                timestamp: Date(),
                imageSize: CGSize(width: 1920, height: 1440),
                shape: .lineSegment
            )
        ],
        viewSize: CGSize(width: 400, height: 600),
        laserService: LaserDetectionService(),
        imageToViewTransform: .identity,
        arView: nil
    )
    .background(Color.gray.opacity(0.3))
}
