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

/// Detected laser point in camera frame
struct LaserPoint: Identifiable {
    let id = UUID()
    let boundingBox: CGRect  // Normalized coordinates (0-1)
    let brightness: Float
    let timestamp: Date
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
    var maxDetections: Int = 1
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

            // Fast peak-based tracker: pick the brightest local peak (optionally within a ROI around last hit).
            let point = self.detectPrimaryBrightSpot(
                in: pixelBuffer,
                brightnessThreshold: brightnessThreshold,
                previousCenterNorm: trackedCenter
            )

            DispatchQueue.main.async {
                if let point {
                    self.detectedPoints = [point]
                    self.lastTrackedCenterNorm = CGPoint(x: point.boundingBox.midX, y: point.boundingBox.midY)
                } else {
                    self.detectedPoints = []
                    self.lastTrackedCenterNorm = nil
                }
                _ = maxDetections // keep snapshot to avoid unused warnings if changed later
            }
        }
    }
    
    /// Detect the primary bright spot with low latency.
    /// Uses luma plane and a "peakiness" check to reject broad bright areas.
    private func detectPrimaryBrightSpot(
        in pixelBuffer: CVPixelBuffer,
        brightnessThreshold: Float,
        previousCenterNorm: CGPoint?
    ) -> LaserPoint? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // ARKit camera frames are typically 420f/420v (bi-planar YCbCr). Use plane 0 (luma) as "brightness".
        let useLumaPlane = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        guard useLumaPlane, CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            // Unsupported format for now.
                        return nil
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

        guard bestX >= 0, bestY >= 0 else { return nil }

        // Refine bounding box around the peak by expanding within a limited window.
        let windowRadius = 28
        let localThreshold = max(Int(thresholdByte), Int(bestLuma) - 28)

        var minX = bestX
        var maxX = bestX
        var minY = bestY
        var maxY = bestY

        let wMinX = max(0, bestX - windowRadius)
        let wMaxX = min(width - 1, bestX + windowRadius)
        let wMinY = max(0, bestY - windowRadius)
        let wMaxY = min(height - 1, bestY + windowRadius)

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
        let pad = 6
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
        if size < minBlobSize || size > min(maxBlobSize, 0.08) { return nil }

        return LaserPoint(
            boundingBox: rectNorm,
            brightness: Float(bestLuma) / 255.0,
            timestamp: Date()
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
