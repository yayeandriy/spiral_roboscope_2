//
//  LaserDetectionService.swift
//  roboscope2
//
//  Detects bright spots (laser points) in camera frames
//

import Foundation
import ARKit
import UIKit
import Combine

/// Shape classification for detected spots
enum LaserSpotShape {
    case rounded      // Circular or square-ish spot (laser dot)
    case lineSegment  // Narrow rectangle (laser line)
    
    var displayName: String {
        switch self {
        case .rounded: return "Dot"
        case .lineSegment: return "Line"
        }
    }
}

/// Detected laser point in camera frame
struct LaserPoint: Identifiable, Equatable {
    let id = UUID()
    let boundingBox: CGRect  // Normalized coordinates (0-1) in camera image space
    let brightness: Float
    let timestamp: Date
    let imageSize: CGSize  // Camera image dimensions for coordinate mapping
    let shape: LaserSpotShape  // Shape classification
    
    static func == (lhs: LaserPoint, rhs: LaserPoint) -> Bool {
        lhs.id == rhs.id
    }
}

/// Service for detecting laser points from camera frames
class LaserDetectionService: ObservableObject {
    @Published var detectedPoints: [LaserPoint] = []
    @Published var isDetecting = false
    
    // Detection parameters
    /// Normalized luma threshold (0..1). Higher = fewer detections.
    var brightnessThreshold: Float = 0.90
    /// Normalized size filters for final bounding boxes.
    var minBlobSize: CGFloat = 0.002
    var maxBlobSize: CGFloat = 0.15
    /// Max number of boxes to display.
    var maxDetections: Int = 3
    private var lastProcessTime: TimeInterval = 0
    private let processingInterval: TimeInterval = 1.0 / 30.0  // Up to ~30Hz
    private let processingQueue = DispatchQueue(label: "LaserGuide.LaserDetection", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isProcessingFrame = false
    private var lastTrackedCenterNorm: CGPoint? = nil
    
    /// Process AR frame to detect laser points
    func processFrame(_ frame: ARFrame) {
        guard isDetecting else { return }
        
        let currentTime = frame.timestamp
        guard currentTime - lastProcessTime >= processingInterval else { return }
        lastProcessTime = currentTime
        
        // Get camera image
        let pixelBuffer = frame.capturedImage

        // Avoid queue backlogs: if a frame is already being processed, drop this one.
        stateLock.lock()
        if isProcessingFrame {
            stateLock.unlock()
            return
        }
        isProcessingFrame = true
        stateLock.unlock()

        // Pass pixel buffer across the DispatchQueue boundary via an unmanaged pointer to avoid
        // Swift 6 Sendable warnings/errors for CVPixelBuffer in @Sendable closures.
        let pixelBufferOpaque = Unmanaged.passRetained(pixelBuffer).toOpaque()

        // Snapshot parameters to avoid races while the slider changes.
        let brightnessThreshold = self.brightnessThreshold
        let maxDetections = self.maxDetections
        let trackedCenter = self.lastTrackedCenterNorm

        processingQueue.async { [weak self] in
            defer {
                self?.stateLock.lock()
                self?.isProcessingFrame = false
                self?.stateLock.unlock()
            }
            guard let self else { return }

            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBufferOpaque).takeRetainedValue()

            // Fast peak-based tracker: pick multiple brightest local peaks.
            let points = self.detectPrimaryBrightSpot(
                in: pixelBuffer,
                brightnessThreshold: brightnessThreshold,
                previousCenterNorm: trackedCenter
            )

            DispatchQueue.main.async {
                if !points.isEmpty {
                    self.detectedPoints = Array(points.prefix(maxDetections))
                    // Track the brightest one for ROI
                    if let first = points.first {
                        self.lastTrackedCenterNorm = CGPoint(x: first.boundingBox.midX, y: first.boundingBox.midY)
                    }
                } else {
                    self.detectedPoints = []
                    self.lastTrackedCenterNorm = nil
                }
            }
        }
    }
    
    /// Detect bright spots with low latency.
    /// Uses luma plane and a "peakiness" check to reject broad bright areas.
    private func detectPrimaryBrightSpot(
        in pixelBuffer: CVPixelBuffer,
        brightnessThreshold: Float,
        previousCenterNorm: CGPoint?
    ) -> [LaserPoint] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // ARKit camera frames are typically 420f/420v (bi-planar YCbCr). Use plane 0 (luma) as "brightness".
        let useLumaPlane = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        guard useLumaPlane, CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            // Unsupported format for now.
            return []
        }
        
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yBuffer = yBaseAddress.assumingMemoryBound(to: UInt8.self)

        @inline(__always) func lumaAt(_ x: Int, _ y: Int) -> UInt8 {
            let xx = max(0, min(width - 1, x))
            let yy = max(0, min(height - 1, y))
            return yBuffer[yy * yBytesPerRow + xx]
        }

        let thresholdByte = UInt8(max(0, min(255, Int(brightnessThreshold * 255.0))))
        let step = 4

        // ROI around last detection to keep tracking responsive while moving.
        let roiHalfSizeNorm: CGFloat = 0.18
        var roiMinX = 0
        var roiMinY = 0
        var roiMaxX = width - 1
        var roiMaxY = height - 1
        if let previousCenterNorm {
            let cx = Int(previousCenterNorm.x * CGFloat(width))
            let cy = Int(previousCenterNorm.y * CGFloat(height))
            let halfW = Int(roiHalfSizeNorm * CGFloat(width))
            let halfH = Int(roiHalfSizeNorm * CGFloat(height))
            roiMinX = max(0, cx - halfW)
            roiMaxX = min(width - 1, cx + halfW)
            roiMinY = max(0, cy - halfH)
            roiMaxY = min(height - 1, cy + halfH)
        }

        // Peakiness check: require center to stand out from nearby samples.
        let neighborRadius = 12
        let minPeakDelta: Int = 18  // ~7% luma delta

        var bestX = -1
        var bestY = -1
        var bestLuma: UInt8 = 0

        for y in stride(from: roiMinY, through: roiMaxY, by: step) {
            for x in stride(from: roiMinX, through: roiMaxX, by: step) {
                let center = lumaAt(x, y)
                if center < thresholdByte { continue }

                // Sample 8 points around at a fixed radius.
                let offsets = [
                    ( neighborRadius, 0), (-neighborRadius, 0),
                    (0,  neighborRadius), (0, -neighborRadius),
                    ( neighborRadius,  neighborRadius), ( neighborRadius, -neighborRadius),
                    (-neighborRadius,  neighborRadius), (-neighborRadius, -neighborRadius)
                ]
                var sum = 0
                for (dx, dy) in offsets {
                    sum += Int(lumaAt(x + dx, y + dy))
                }
                let neighborMean = sum / offsets.count
                if Int(center) - neighborMean < minPeakDelta { continue }

                if center > bestLuma {
                    bestLuma = center
                    bestX = x
                    bestY = y
                }
            }
        }

        // If ROI scan failed, fall back to a full-frame scan (still cheap at step=4).
        if bestX < 0 {
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let center = lumaAt(x, y)
                    if center < thresholdByte { continue }

                    let offsets = [
                        ( neighborRadius, 0), (-neighborRadius, 0),
                        (0,  neighborRadius), (0, -neighborRadius),
                        ( neighborRadius,  neighborRadius), ( neighborRadius, -neighborRadius),
                        (-neighborRadius,  neighborRadius), (-neighborRadius, -neighborRadius)
                    ]
                    var sum = 0
                    for (dx, dy) in offsets {
                        sum += Int(lumaAt(x + dx, y + dy))
                    }
                    let neighborMean = sum / offsets.count
                    if Int(center) - neighborMean < minPeakDelta { continue }

                    if center > bestLuma {
                        bestLuma = center
                        bestX = x
                        bestY = y
                    }
                }
            }
        }

        guard bestX >= 0, bestY >= 0 else { return [] }
        
        // Collect multiple peaks with minimum separation
        struct Peak {
            let x: Int
            let y: Int
            let luma: UInt8
        }
        
        var peaks: [Peak] = [Peak(x: bestX, y: bestY, luma: bestLuma)]
        let minSeparation = 80  // Min pixel distance between peaks
        
        // Find additional peaks
        let scanRegion = previousCenterNorm != nil ? 
            [(roiMinX, roiMaxX, roiMinY, roiMaxY)] : 
            [(0, width - 1, 0, height - 1)]
        
        for (minX, maxX, minY, maxY) in scanRegion {
            for y in stride(from: minY, through: maxY, by: step) {
                for x in stride(from: minX, through: maxX, by: step) {
                    let center = lumaAt(x, y)
                    if center < thresholdByte { continue }
                    
                    // Check if too close to existing peaks
                    var tooClose = false
                    for peak in peaks {
                        let dx = x - peak.x
                        let dy = y - peak.y
                        if dx * dx + dy * dy < minSeparation * minSeparation {
                            tooClose = true
                            break
                        }
                    }
                    if tooClose { continue }
                    
                    // Check peakiness
                    let offsets = [
                        ( neighborRadius, 0), (-neighborRadius, 0),
                        (0,  neighborRadius), (0, -neighborRadius),
                        ( neighborRadius,  neighborRadius), ( neighborRadius, -neighborRadius),
                        (-neighborRadius,  neighborRadius), (-neighborRadius, -neighborRadius)
                    ]
                    var sum = 0
                    for (dx, dy) in offsets {
                        sum += Int(lumaAt(x + dx, y + dy))
                    }
                    let neighborMean = sum / offsets.count
                    if Int(center) - neighborMean < minPeakDelta { continue }
                    
                    peaks.append(Peak(x: x, y: y, luma: center))
                    if peaks.count >= 5 { break }  // Limit search
                }
                if peaks.count >= 5 { break }
            }
            if peaks.count >= 5 { break }
        }

        // Convert peaks to LaserPoints
        var points: [LaserPoint] = []
        let windowRadius = 28
        let pad = 6
        
        for peak in peaks {
            // Refine bounding box around this peak
            let localThreshold = max(Int(thresholdByte), Int(peak.luma) - 28)
            
            var minX = peak.x
            var maxX = peak.x
            var minY = peak.y
            var maxY = peak.y
            
            let wMinX = max(0, peak.x - windowRadius)
            let wMaxX = min(width - 1, peak.x + windowRadius)
            let wMinY = max(0, peak.y - windowRadius)
            let wMaxY = min(height - 1, peak.y + windowRadius)
            
            for y in wMinY...wMaxY {
                for x in wMinX...wMaxX {
                    if Int(lumaAt(x, y)) >= localThreshold {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
            
            // Pad slightly, and clamp.
            minX = max(0, minX - pad)
            maxX = min(width - 1, maxX + pad)
            minY = max(0, minY - pad)
            maxY = min(height - 1, maxY + pad)
            
            let rectPx = CGRect(
                x: CGFloat(minX),
                y: CGFloat(minY),
                width: CGFloat(max(1, maxX - minX)),
                height: CGFloat(max(1, maxY - minY))
            )
            
            let rectNorm = CGRect(
                x: rectPx.minX / CGFloat(width),
                y: rectPx.minY / CGFloat(height),
                width: rectPx.width / CGFloat(width),
                height: rectPx.height / CGFloat(height)
            )
            
            // Reject boxes that are too big (broad bright areas) or too tiny.
            let size = max(rectNorm.width, rectNorm.height)
            if size < minBlobSize || size > min(maxBlobSize, 0.08) { continue }
            
            // Classify shape based on aspect ratio
            let aspectRatio = max(rectNorm.width, rectNorm.height) / min(rectNorm.width, rectNorm.height)
            let shape: LaserSpotShape = aspectRatio > 1.5 ? .lineSegment : .rounded
            
            points.append(LaserPoint(
                boundingBox: rectNorm,
                brightness: Float(peak.luma) / 255.0,
                timestamp: Date(),
                imageSize: CGSize(width: width, height: height),
                shape: shape
            ))
        }
        
        // Merge nearby line detections
        points = mergeNearbyLines(points)
        
        // Sort by brightness
        points.sort { $0.brightness > $1.brightness }
        
        return points
    }
    
    /// Merge nearby line segments into single detections
    private func mergeNearbyLines(_ points: [LaserPoint]) -> [LaserPoint] {
        var result: [LaserPoint] = []
        var processed: Set<Int> = []
        
        for i in 0..<points.count {
            if processed.contains(i) { continue }
            
            let point = points[i]
            
            // Only merge line segments, not dots
            if point.shape != .lineSegment {
                result.append(point)
                processed.insert(i)
                continue
            }
            
            // Find nearby lines to merge
            var toMerge: [LaserPoint] = [point]
            processed.insert(i)
            
            for j in (i+1)..<points.count {
                if processed.contains(j) { continue }
                
                let other = points[j]
                if other.shape != .lineSegment { continue }
                
                // Check if lines are close enough to merge
                let distance = distanceBetweenRects(point.boundingBox, other.boundingBox)
                let avgSize = (max(point.boundingBox.width, point.boundingBox.height) + 
                              max(other.boundingBox.width, other.boundingBox.height)) / 2
                
                // Merge if distance is less than 2x the average size
                if distance < avgSize * 2.0 {
                    toMerge.append(other)
                    processed.insert(j)
                }
            }
            
            // If multiple lines found, merge them
            if toMerge.count > 1 {
                let merged = mergeLaserPoints(toMerge)
                result.append(merged)
            } else {
                result.append(point)
            }
        }
        
        return result
    }
    
    /// Calculate distance between two rectangles
    private func distanceBetweenRects(_ rect1: CGRect, _ rect2: CGRect) -> CGFloat {
        let center1 = CGPoint(x: rect1.midX, y: rect1.midY)
        let center2 = CGPoint(x: rect2.midX, y: rect2.midY)
        let dx = center1.x - center2.x
        let dy = center1.y - center2.y
        return sqrt(dx * dx + dy * dy)
    }
    
    /// Merge multiple laser points into one
    private func mergeLaserPoints(_ points: [LaserPoint]) -> LaserPoint {
        guard !points.isEmpty else {
            fatalError("Cannot merge empty array")
        }
        
        // Find bounding box that encompasses all points
        var minX = points[0].boundingBox.minX
        var minY = points[0].boundingBox.minY
        var maxX = points[0].boundingBox.maxX
        var maxY = points[0].boundingBox.maxY
        var totalBrightness: Float = 0
        
        for point in points {
            minX = min(minX, point.boundingBox.minX)
            minY = min(minY, point.boundingBox.minY)
            maxX = max(maxX, point.boundingBox.maxX)
            maxY = max(maxY, point.boundingBox.maxY)
            totalBrightness += point.brightness
        }
        
        let mergedRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        
        // Average brightness
        let avgBrightness = totalBrightness / Float(points.count)
        
        // Reclassify shape based on merged box
        let aspectRatio = max(mergedRect.width, mergedRect.height) / min(mergedRect.width, mergedRect.height)
        let shape: LaserSpotShape = aspectRatio > 1.5 ? .lineSegment : .rounded
        
        return LaserPoint(
            boundingBox: mergedRect,
            brightness: avgBrightness,
            timestamp: Date(),
            imageSize: points[0].imageSize,
            shape: shape
        )
    }
    
    /// Start detecting laser points
    func startDetection() {
        isDetecting = true
        detectedPoints = []
        stateLock.lock()
        isProcessingFrame = false
        stateLock.unlock()
        lastTrackedCenterNorm = nil
        print("[LaserGuide] Detection started")
    }
    
    /// Stop detecting laser points
    func stopDetection() {
        isDetecting = false
        detectedPoints = []
        stateLock.lock()
        isProcessingFrame = false
        stateLock.unlock()
        lastTrackedCenterNorm = nil
        print("[LaserGuide] Detection stopped")
    }
    
    /// Get the most prominent detected point
    func getPrimaryLaserPoint() -> LaserPoint? {
        // Return brightest point
        return detectedPoints.max(by: { $0.brightness < $1.brightness })
    }
}

