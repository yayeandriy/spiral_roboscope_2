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
import QuartzCore

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
struct LaserOrientedLineBox: Equatable {
    /// Center in normalized image coordinates (0..1).
    let centerNorm: CGPoint
    /// Line direction angle in image pixel coordinate space (radians).
    let angleRadians: CGFloat
    /// Length of the line in image pixels (major axis).
    let lengthPx: CGFloat
    /// Thickness of the line in image pixels (minor axis).
    let thicknessPx: CGFloat
}

struct LaserPoint: Identifiable, Equatable {
    let id = UUID()
    let boundingBox: CGRect  // Normalized coordinates (0-1) in camera image space
    let brightness: Float
    let timestamp: Date
    let imageSize: CGSize  // Camera image dimensions for coordinate mapping
    let shape: LaserSpotShape  // Shape classification
    /// Optional oriented geometry for line segments.
    /// When present, overlay can render an object-aligned (rotated) box.
    let orientedLineBox: LaserOrientedLineBox?
    
    static func == (lhs: LaserPoint, rhs: LaserPoint) -> Bool {
        lhs.id == rhs.id
    }
}

/// Service for detecting laser points from camera frames
class LaserDetectionService: ObservableObject {
    @Published var detectedPoints: [LaserPoint] = []
    @Published var isDetecting = false
    /// Max allowed world-space Y delta (meters) between the chosen dot and line.
    /// Used by UI overlay filtering (default 0.20m = 20cm).
    @Published var maxDotLineYDeltaMeters: Float = 0.20
    
    // Detection parameters (adjustable via UI)
    /// Normalized luma threshold (0..1). Higher = fewer detections.
    @Published var brightnessThreshold: Float = 0.90
    /// If true, detect by hue proximity (ignores brightness threshold).
    @Published var useHueDetection: Bool = false
    /// Target hue in 0..1 (0=red, ~0.33=green, ~0.66=blue).
    @Published var targetHue: Float = 0.0
    /// Minimum normalized size for detected spots (filters noise).
    @Published var minBlobSize: CGFloat = 0.002
    /// Line shape threshold: higher values require more elongation.
    @Published var lineAnisotropyThreshold: Double = 6.0
    /// Normalized size filters for final bounding boxes.
    var maxBlobSize: CGFloat = 0.15
    /// Max number of boxes to display.
    /// Note: overlay further filters to max one dot + one line.
    var maxDetections: Int = 6
    private var lastProcessTime: TimeInterval = 0
    private let processingInterval: TimeInterval = 1.0 / 30.0  // Up to ~30Hz
    private let processingQueue = DispatchQueue(label: "LaserGuide.LaserDetection", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isProcessingFrame = false
    private var lastTrackedCenterNorm: CGPoint? = nil
    private var detectionGeneration: UInt64 = 0

    private struct Peak {
        let x: Int
        let y: Int
        /// Either luma (brightness mode) or hue score (hue mode), 0..255.
        let value: UInt8
    }
    
    /// Process AR frame to detect laser points
    func processFrame(_ frame: ARFrame) {
        guard isDetecting else { return }

        // Use a stable wall-clock timer here rather than ARFrame.timestamp.
        // Some SDK/toolchain combinations expose `timestamp` as `Duration`, which can cause
        // type-mismatch errors when compared to `TimeInterval`.
        let currentTime = CACurrentMediaTime()
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
        let generation = detectionGeneration
        let brightnessThreshold = self.brightnessThreshold
        let maxDetections = self.maxDetections
        let trackedCenter = self.lastTrackedCenterNorm
        let minBlobSize = self.minBlobSize
        let maxBlobSize = self.maxBlobSize
        let lineAnisotropyThreshold = self.lineAnisotropyThreshold
        let useHueDetection = self.useHueDetection
        let targetHue = self.targetHue

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
                previousCenterNorm: trackedCenter,
                minBlobSize: minBlobSize,
                maxBlobSize: maxBlobSize,
                lineAnisotropyThreshold: lineAnisotropyThreshold,
                useHueDetection: useHueDetection,
                targetHue: targetHue
            )

            DispatchQueue.main.async {
                // Drop stale results after stop/restart.
                guard self.isDetecting, self.detectionGeneration == generation else {
                    return
                }
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
        previousCenterNorm: CGPoint?,
        minBlobSize: CGFloat,
        maxBlobSize: CGFloat,
        lineAnisotropyThreshold: Double,
        useHueDetection: Bool,
        targetHue: Float
    ) -> [LaserPoint] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // ARKit camera frames are typically 420f/420v (bi-planar YCbCr). Use plane 0 (luma) as "brightness".
        let useLumaPlane = (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
            (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

          let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
          guard useLumaPlane, planeCount >= 1,
              let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            // Unsupported format for now.
            return []
        }
        
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yBuffer = yBaseAddress.assumingMemoryBound(to: UInt8.self)

        // Optional chroma plane (CbCr) for hue-based detection.
        let cbcrBaseAddress: UnsafeMutableRawPointer?
        let cbcrBytesPerRow: Int
        let cbcrWidth: Int
        let cbcrHeight: Int
        if useHueDetection {
            guard planeCount >= 2,
                  let addr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
                // Hue detection requested but chroma plane not available.
                return []
            }
            cbcrBaseAddress = addr
            cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            cbcrWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            cbcrHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        } else {
            cbcrBaseAddress = nil
            cbcrBytesPerRow = 0
            cbcrWidth = 0
            cbcrHeight = 0
        }

        @inline(__always) func lumaAt(_ x: Int, _ y: Int) -> UInt8 {
            let xx = max(0, min(width - 1, x))
            let yy = max(0, min(height - 1, y))
            return yBuffer[yy * yBytesPerRow + xx]
        }

        @inline(__always) func hueFromRGB(_ r: Float, _ g: Float, _ b: Float) -> Float {
            let maxV = max(r, max(g, b))
            let minV = min(r, min(g, b))
            let delta = maxV - minV
            if delta <= 1e-6 { return 0.0 }

            var h: Float
            if maxV == r {
                h = (g - b) / delta
                if h < 0 { h += 6 }
            } else if maxV == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            return (h / 6.0)
        }

        @inline(__always) func hueDistance(_ a: Float, _ b: Float) -> Float {
            let d = abs(a - b)
            return min(d, 1.0 - d)
        }

        @inline(__always) func hueScoreAt(_ x: Int, _ y: Int) -> UInt8 {
            guard let cbcrBaseAddress else { return 0 }
            let xx = max(0, min(width - 1, x))
            let yy = max(0, min(height - 1, y))

            // 420 bi-planar chroma is half resolution.
            let cX = max(0, min(cbcrWidth - 1, xx / 2))
            let cY = max(0, min(cbcrHeight - 1, yy / 2))
            let cbcr = cbcrBaseAddress.assumingMemoryBound(to: UInt8.self)
            let idx = (cY * cbcrBytesPerRow) + (cX * 2)
            let cb = Float(cbcr[idx + 0]) - 128.0
            let cr = Float(cbcr[idx + 1]) - 128.0

            // Reject extremely low-chroma pixels (avoids random hue noise).
            let chromaMag = sqrt(cb * cb + cr * cr)
            if chromaMag < 18.0 { return 0 }

            // Convert YCbCr -> RGB (approx). Using Y for conversion only, not for thresholding.
            let yv = Float(lumaAt(xx, yy))
            var r = yv + (1.402 * cr)
            var g = yv - (0.344136 * cb) - (0.714136 * cr)
            var b = yv + (1.772 * cb)

            r = max(0.0, min(255.0, r))
            g = max(0.0, min(255.0, g))
            b = max(0.0, min(255.0, b))

            let hue = hueFromRGB(r / 255.0, g / 255.0, b / 255.0)
            let dist = hueDistance(hue, max(0.0, min(1.0, targetHue)))

            // Fixed tolerance: user selects the hue; detector matches near it.
            let tolerance: Float = 0.06
            if dist > tolerance { return 0 }
            let score = 1.0 - (dist / tolerance)
            return UInt8(max(0.0, min(255.0, score * 255.0)))
        }

        @inline(__always) func valueAt(_ x: Int, _ y: Int) -> UInt8 {
            useHueDetection ? hueScoreAt(x, y) : lumaAt(x, y)
        }

        let thresholdByte: UInt8
        if useHueDetection {
            // Threshold in hue-score space (0..255). Higher = stricter hue match.
            thresholdByte = 150
        } else {
            thresholdByte = UInt8(max(0, min(255, Int(brightnessThreshold * 255.0))))
        }
        let step = 4

        // Line detectability tweaks:
        // The line often fails the local "peakiness" check because nearby samples can still fall on the line.
        // We'll run a separate coarse scan for line candidates when the peak-based method yields no line.
        let lineThresholdByte = UInt8(max(0, Int(thresholdByte) - 18)) // slightly more permissive than dot

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
        var bestValue: UInt8 = 0

        for y in stride(from: roiMinY, through: roiMaxY, by: step) {
            for x in stride(from: roiMinX, through: roiMaxX, by: step) {
                let center = valueAt(x, y)
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
                    sum += Int(valueAt(x + dx, y + dy))
                }
                let neighborMean = sum / offsets.count
                if Int(center) - neighborMean < minPeakDelta { continue }

                if center > bestValue {
                    bestValue = center
                    bestX = x
                    bestY = y
                }
            }
        }

        // If ROI scan failed, fall back to a full-frame scan (still cheap at step=4).
        if bestX < 0 {
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let center = valueAt(x, y)
                    if center < thresholdByte { continue }

                    let offsets = [
                        ( neighborRadius, 0), (-neighborRadius, 0),
                        (0,  neighborRadius), (0, -neighborRadius),
                        ( neighborRadius,  neighborRadius), ( neighborRadius, -neighborRadius),
                        (-neighborRadius,  neighborRadius), (-neighborRadius, -neighborRadius)
                    ]
                    var sum = 0
                    for (dx, dy) in offsets {
                        sum += Int(valueAt(x + dx, y + dy))
                    }
                    let neighborMean = sum / offsets.count
                    if Int(center) - neighborMean < minPeakDelta { continue }

                    if center > bestValue {
                        bestValue = center
                        bestX = x
                        bestY = y
                    }
                }
            }
        }

        guard bestX >= 0, bestY >= 0 else { return [] }
        
        // Collect multiple peaks with minimum separation
        var peaks: [Peak] = [Peak(x: bestX, y: bestY, value: bestValue)]
        let minSeparation = 80  // Min pixel distance between peaks
        
        // Find additional peaks
        // When tracking is enabled we still need to find BOTH dot + line, which can be far apart.
        // So we scan the ROI first for stability, then allow a full-frame pass for additional peaks.
        let scanRegion = previousCenterNorm != nil ?
            [(roiMinX, roiMaxX, roiMinY, roiMaxY), (0, width - 1, 0, height - 1)] :
            [(0, width - 1, 0, height - 1)]
        
        for (minX, maxX, minY, maxY) in scanRegion {
            for y in stride(from: minY, through: maxY, by: step) {
                for x in stride(from: minX, through: maxX, by: step) {
                    let center = valueAt(x, y)
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
                        sum += Int(valueAt(x + dx, y + dy))
                    }
                    let neighborMean = sum / offsets.count
                    if Int(center) - neighborMean < minPeakDelta { continue }
                    
                    peaks.append(Peak(x: x, y: y, value: center))
                    if peaks.count >= 8 { break }  // Limit search
                }
                if peaks.count >= 8 { break }
            }
            if peaks.count >= 8 { break }
        }

        // If ROI tracking is enabled, the peak scan may never look outside the ROI.
        // Add a coarse full-frame line scan to keep line detection reliable.
        if let linePeak = findBestLinePeak(
            width: width,
            height: height,
            valueAt: valueAt,
            thresholdByte: lineThresholdByte
        ) {
            // Only add if it's not too close to an existing peak.
            var tooClose = false
            for peak in peaks {
                let dx = linePeak.x - peak.x
                let dy = linePeak.y - peak.y
                if dx * dx + dy * dy < minSeparation * minSeparation {
                    tooClose = true
                    break
                }
            }
            if !tooClose {
                peaks.append(linePeak)
            }
        }

        // Convert peaks to LaserPoints
        var points: [LaserPoint] = []
        let baseWindowRadius = 28
        let basePad = 6

        // Line fitting parameters.
        // Note: the laser line has a consistent physical length; in image space it still varies
        // with distance/perspective, but this minimum prevents the detector from returning tiny
        // sub-segments when thresholding only captures part of the line.
        let lineFitWindowRadius = 140
        let lineFitStep = 2
        let lineMinLengthNorm: CGFloat = 0.12
        let lineMinThicknessNorm: CGFloat = 0.006
        let lineMaxSizeNorm: CGFloat = 0.35
        
        for peak in peaks {
            // Refine bounding box around this peak
            let localThreshold = max(Int(thresholdByte), Int(peak.value) - 28)
            
            var minX = peak.x
            var maxX = peak.x
            var minY = peak.y
            var maxY = peak.y
            
            let wMinX = max(0, peak.x - baseWindowRadius)
            let wMaxX = min(width - 1, peak.x + baseWindowRadius)
            let wMinY = max(0, peak.y - baseWindowRadius)
            let wMaxY = min(height - 1, peak.y + baseWindowRadius)

            // Track simple second-order moments in the base window for robust line-vs-dot classification.
            var count = 0
            var sumX: Double = 0
            var sumY: Double = 0
            var sumXX: Double = 0
            var sumYY: Double = 0
            var sumXY: Double = 0

            for y in wMinY...wMaxY {
                for x in wMinX...wMaxX {
                    if Int(valueAt(x, y)) >= localThreshold {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }

                        count += 1
                        let xd = Double(x)
                        let yd = Double(y)
                        sumX += xd
                        sumY += yd
                        sumXX += xd * xd
                        sumYY += yd * yd
                        sumXY += xd * yd
                    }
                }
            }

            // Pad slightly, and clamp.
            minX = max(0, minX - basePad)
            maxX = min(width - 1, maxX + basePad)
            minY = max(0, minY - basePad)
            maxY = min(height - 1, maxY + basePad)
            
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

            // Classify using anisotropy of the pixel cloud (robust to diagonal lines).
            var isLineCandidate = false
            if count >= 20 {
                let invN = 1.0 / Double(count)
                let meanX = sumX * invN
                let meanY = sumY * invN
                let sxx = max(0.0, (sumXX * invN) - (meanX * meanX))
                let syy = max(0.0, (sumYY * invN) - (meanY * meanY))
                let sxy = (sumXY * invN) - (meanX * meanY)

                let trace = sxx + syy
                let det = (sxx * syy) - (sxy * sxy)
                let disc = max(0.0, (trace * trace) / 4.0 - det)
                let root = sqrt(disc)
                let lambda1 = (trace / 2.0) + root
                let lambda2 = max(1e-6, (trace / 2.0) - root)

                let anisotropy = lambda1 / lambda2
                isLineCandidate = anisotropy >= lineAnisotropyThreshold
            }

            // Reject boxes that are too big (broad bright areas) or too tiny.
            // Allow larger size for lines (since line length can be substantial in image space).
            let size = max(rectNorm.width, rectNorm.height)
            let maxAllowedSize = isLineCandidate ? min(maxBlobSize, lineMaxSizeNorm) : min(maxBlobSize, 0.08)
            if size < minBlobSize || size > maxAllowedSize { continue }

            var finalRectNorm = rectNorm
            var shape: LaserSpotShape = isLineCandidate ? .lineSegment : .rounded
            var orientedLineBox: LaserOrientedLineBox? = nil

            // For line candidates, refit in a larger window and enforce a minimum length.
            if isLineCandidate {
                if let fitted = fitLineBoundingBox(
                    peakX: peak.x,
                    peakY: peak.y,
                    width: width,
                    height: height,
                    valueAt: valueAt,
                    thresholdByte: thresholdByte,
                    peakValue: peak.value,
                    windowRadius: lineFitWindowRadius,
                    step: lineFitStep,
                    minLengthNorm: lineMinLengthNorm,
                    minThicknessNorm: lineMinThicknessNorm
                ) {
                    let fittedSize = max(fitted.rectNorm.width, fitted.rectNorm.height)
                    if fittedSize >= minBlobSize && fittedSize <= min(maxBlobSize, lineMaxSizeNorm) {
                        finalRectNorm = fitted.rectNorm
                        orientedLineBox = LaserOrientedLineBox(
                            centerNorm: fitted.centerNorm,
                            angleRadians: fitted.angleRadians,
                            lengthPx: fitted.lengthPx,
                            thicknessPx: fitted.thicknessPx
                        )
                    }
                }

                // Re-evaluate: diagonal lines can become near-square in axis-aligned bbox; keep as line
                // as long as the refit succeeded (or base anisotropy said "line").
                shape = .lineSegment
            }
            
            points.append(LaserPoint(
                boundingBox: finalRectNorm,
                brightness: Float(peak.value) / 255.0,
                timestamp: Date(),
                imageSize: CGSize(width: width, height: height),
                shape: shape,
                orientedLineBox: orientedLineBox
            ))
        }
        
        // Merge nearby line detections
        points = mergeNearbyLines(points)
        
        // Sort by brightness
        points.sort { $0.brightness > $1.brightness }
        
        return points
    }

    /// Coarse scan for a laser line candidate.
    /// Looks for elongated bright pixel clouds (high anisotropy) without requiring a local maximum.
    private func findBestLinePeak(
        width: Int,
        height: Int,
        valueAt: (Int, Int) -> UInt8,
        thresholdByte: UInt8
    ) -> Peak? {
        // Coarse sampling for performance.
        let scanStep = 18
        let windowRadius = 24
        let windowStep = 6
        let minCount = 14
        let anisotropyThreshold: Double = 4.0

        var best: Peak? = nil
        var bestScore: Double = 0

        for y in stride(from: 0, to: height, by: scanStep) {
            for x in stride(from: 0, to: width, by: scanStep) {
                let center = valueAt(x, y)
                if center < thresholdByte { continue }

                let minX = max(0, x - windowRadius)
                let maxX = min(width - 1, x + windowRadius)
                let minY = max(0, y - windowRadius)
                let maxY = min(height - 1, y + windowRadius)

                var count = 0
                var sumX: Double = 0
                var sumY: Double = 0
                var sumXX: Double = 0
                var sumYY: Double = 0
                var sumXY: Double = 0

                for yy in stride(from: minY, through: maxY, by: windowStep) {
                    for xx in stride(from: minX, through: maxX, by: windowStep) {
                        if valueAt(xx, yy) >= thresholdByte {
                            count += 1
                            let xd = Double(xx)
                            let yd = Double(yy)
                            sumX += xd
                            sumY += yd
                            sumXX += xd * xd
                            sumYY += yd * yd
                            sumXY += xd * yd
                        }
                    }
                }

                if count < minCount { continue }

                let invN = 1.0 / Double(count)
                let meanX = sumX * invN
                let meanY = sumY * invN
                let sxx = max(0.0, (sumXX * invN) - (meanX * meanX))
                let syy = max(0.0, (sumYY * invN) - (meanY * meanY))
                let sxy = (sumXY * invN) - (meanX * meanY)

                let trace = sxx + syy
                let det = (sxx * syy) - (sxy * sxy)
                let disc = max(0.0, (trace * trace) / 4.0 - det)
                let root = sqrt(disc)
                let lambda1 = (trace / 2.0) + root
                let lambda2 = max(1e-6, (trace / 2.0) - root)
                let anisotropy = lambda1 / lambda2

                if anisotropy < anisotropyThreshold { continue }

                let score = Double(center) * anisotropy
                if score > bestScore {
                    bestScore = score
                    best = Peak(x: Int(meanX.rounded()), y: Int(meanY.rounded()), value: center)
                }
            }
        }

        return best
    }

    private struct LineFitResult {
        let rectNorm: CGRect
        let centerNorm: CGPoint
        let angleRadians: CGFloat
        let lengthPx: CGFloat
        let thicknessPx: CGFloat
    }

    private func fitLineBoundingBox(
        peakX: Int,
        peakY: Int,
        width: Int,
        height: Int,
        valueAt: (Int, Int) -> UInt8,
        thresholdByte: UInt8,
        peakValue: UInt8,
        windowRadius: Int,
        step: Int,
        minLengthNorm: CGFloat,
        minThicknessNorm: CGFloat
    ) -> LineFitResult? {
        // Use a slightly more permissive threshold to include dimmer parts of the line.
        let localThreshold = max(Int(thresholdByte), Int(peakValue) - 40)

        let minX = max(0, peakX - windowRadius)
        let maxX = min(width - 1, peakX + windowRadius)
        let minY = max(0, peakY - windowRadius)
        let maxY = min(height - 1, peakY + windowRadius)

        var count = 0
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXX: Double = 0
        var sumYY: Double = 0
        var sumXY: Double = 0

        for y in stride(from: minY, through: maxY, by: step) {
            for x in stride(from: minX, through: maxX, by: step) {
                if Int(valueAt(x, y)) >= localThreshold {
                    count += 1
                    let xd = Double(x)
                    let yd = Double(y)
                    sumX += xd
                    sumY += yd
                    sumXX += xd * xd
                    sumYY += yd * yd
                    sumXY += xd * yd
                }
            }
        }

        guard count >= 30 else { return nil }

        let invN = 1.0 / Double(count)
        let meanX = sumX * invN
        let meanY = sumY * invN
        let sxx = max(0.0, (sumXX * invN) - (meanX * meanX))
        let syy = max(0.0, (sumYY * invN) - (meanY * meanY))
        let sxy = (sumXY * invN) - (meanX * meanY)

        // Principal direction angle.
        let angle = 0.5 * atan2(2.0 * sxy, sxx - syy)
        let dirX = cos(angle)
        let dirY = sin(angle)
        let perpX = -dirY
        let perpY = dirX

        var minAlong = Double.greatestFiniteMagnitude
        var maxAlong = -Double.greatestFiniteMagnitude
        var minPerp = Double.greatestFiniteMagnitude
        var maxPerp = -Double.greatestFiniteMagnitude

        for y in stride(from: minY, through: maxY, by: step) {
            for x in stride(from: minX, through: maxX, by: step) {
                if Int(valueAt(x, y)) >= localThreshold {
                    let dx = Double(x) - meanX
                    let dy = Double(y) - meanY
                    let along = dx * dirX + dy * dirY
                    let perp = dx * perpX + dy * perpY
                    if along < minAlong { minAlong = along }
                    if along > maxAlong { maxAlong = along }
                    if perp < minPerp { minPerp = perp }
                    if perp > maxPerp { maxPerp = perp }
                }
            }
        }

        let observedLengthPx = max(0.0, maxAlong - minAlong)
        let observedThicknessPx = max(0.0, maxPerp - minPerp)

        let minLenPx = Double(minLengthNorm) * Double(min(width, height))
        let minThickPx = Double(minThicknessNorm) * Double(min(width, height))

        let lengthPx = max(observedLengthPx, minLenPx)
        let thicknessPx = max(observedThicknessPx, minThickPx)

        let absDirX = abs(dirX)
        let absDirY = abs(dirY)
        let absPerpX = abs(perpX)
        let absPerpY = abs(perpY)

        let boxWidthPx = absDirX * lengthPx + absPerpX * thicknessPx
        let boxHeightPx = absDirY * lengthPx + absPerpY * thicknessPx

        // Add a little padding.
        let padPx = 6.0
        let halfW = (boxWidthPx / 2.0) + padPx
        let halfH = (boxHeightPx / 2.0) + padPx

        let cx = meanX
        let cy = meanY

        let x0 = max(0.0, cx - halfW)
        let y0 = max(0.0, cy - halfH)
        let x1 = min(Double(width - 1), cx + halfW)
        let y1 = min(Double(height - 1), cy + halfH)

        guard x1 > x0, y1 > y0 else { return nil }

        let rectNorm = CGRect(
            x: CGFloat(x0) / CGFloat(width),
            y: CGFloat(y0) / CGFloat(height),
            width: CGFloat(x1 - x0) / CGFloat(width),
            height: CGFloat(y1 - y0) / CGFloat(height)
        )

        return LineFitResult(
            rectNorm: rectNorm,
            centerNorm: CGPoint(x: CGFloat(cx) / CGFloat(width), y: CGFloat(cy) / CGFloat(height)),
            angleRadians: CGFloat(angle),
            lengthPx: CGFloat(lengthPx),
            thicknessPx: CGFloat(thicknessPx)
        )
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
        
        let hasAnyLine = points.contains(where: { $0.shape == .lineSegment })
        let shape: LaserSpotShape = hasAnyLine ? .lineSegment : .rounded

        let bestOrientedLine = points
            .filter { $0.shape == .lineSegment }
            .max(by: { $0.brightness < $1.brightness })?.orientedLineBox
        
        return LaserPoint(
            boundingBox: mergedRect,
            brightness: avgBrightness,
            timestamp: Date(),
            imageSize: points[0].imageSize,
            shape: shape,
            orientedLineBox: bestOrientedLine
        )
    }
    
    /// Start detecting laser points
    func startDetection() {
        detectionGeneration &+= 1
        isDetecting = true
        detectedPoints = []
        lastProcessTime = 0
        lastTrackedCenterNorm = nil
        print("[LaserGuide] Detection started")
    }
    
    /// Stop detecting laser points
    func stopDetection() {
        detectionGeneration &+= 1
        isDetecting = false
        detectedPoints = []
        lastTrackedCenterNorm = nil
        print("[LaserGuide] Detection stopped")
    }
    
    /// Get the most prominent detected point
    func getPrimaryLaserPoint() -> LaserPoint? {
        // Return brightest point
        return detectedPoints.max(by: { $0.brightness < $1.brightness })
    }
}

