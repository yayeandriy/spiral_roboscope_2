//
//  LaserDetectionOverlay.swift
//  roboscope2
//
//  Overlay view showing detected laser points with bounding boxes
//

import SwiftUI

struct LaserDetectionOverlay: View {
    let detectedPoints: [LaserPoint]
    let viewSize: CGSize
    @ObservedObject var laserService: LaserDetectionService
    /// Maps normalized image coordinates to normalized view coordinates.
    let imageToViewTransform: CGAffineTransform
    @State private var showControls = false
    
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
            }
            .allowsHitTesting(showControls) // Only intercept touches when controls are visible
        }
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
        imageToViewTransform: .identity
    )
    .background(Color.gray.opacity(0.3))
}
