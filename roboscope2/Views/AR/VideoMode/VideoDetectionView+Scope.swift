//
//  VideoDetectionView+Scope.swift
//  roboscope2
//
//  Auto-scope detection logic for VideoDetectionView.
//  Mirrors the algorithm in LaserGuideARSessionView+Scoping.swift but without AR side-effects.
//

import QuartzCore

extension VideoDetectionView {

    // MARK: - Constants

    var videoScopeDistanceToleranceMeters: Float { 0.03 }

    // MARK: - Scope logic

    /// Processes raw ML detections: applies filters, updates 2-D accumulator for overlay,
    /// performs per-frame measurement + immediate origin placement (when enabled), and
    /// appends a history record.
    func processDetections(_ rawDetections: [LaserMLDetection]) {
        let newDetections = filterLineOverDot(rawDetections)

        // --- 2-D accumulator update (for overlay visualization only) ---
        let maxFrames = max(1, settings.videoModeAccumulatorFrames)
        var acc = frameAccumulator
        acc.append(newDetections)
        if acc.count > maxFrames { acc.removeFirst(acc.count - maxFrames) }
        frameAccumulator = acc
        let merged = laserDetectionMergeFrames(acc)
        let mergedHasDot  = merged.contains { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
        let mergedHasLine = merged.contains { $0.classIndex == 1 || $0.label.lowercased().contains("line") }
        if mergedHasDot && mergedHasLine {
            emptyDetectionFrames = 0
            accumulatedDetections = merged
        } else {
            emptyDetectionFrames += 1
            if emptyDetectionFrames > 2 * maxFrames {
                accumulatedDetections = []
            } else {
                accumulatedDetections = merged
            }
        }

        // --- Per-frame measurement → immediate origin placement ---
        if settings.usePerFrame3DPlacement, !hasFoundOrigin {
            let dotDets  = newDetections.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
            let lineDets = newDetections.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }
            if let bestDot = dotDets.max(by: { $0.confidence < $1.confidence }),
               let bestLine = lineDets.max(by: { $0.confidence < $1.confidence }) {

                let t = videoImageToViewTransform
                let dotNorm = CGPoint(x: bestDot.boundingBox.midX, y: bestDot.boundingBox.midY).applying(t)
                let lineNorm = CGPoint(x: bestLine.boundingBox.midX, y: bestLine.boundingBox.midY).applying(t)
                guard abs(dotNorm.y - lineNorm.y) <= 0.5 else { return }

                let dx = dotNorm.x - lineNorm.x
                let dy = dotNorm.y - lineNorm.y
                let dNorm = sqrt(dx * dx + dy * dy)
                let dMeters = Float(dNorm) * settings.videoModeDistanceScale
                let measurement = LaserDotLineMeasurement(
                    dotWorld: SIMD3<Float>(Float(dotNorm.x), 0, Float(dotNorm.y)),
                    lineWorld: SIMD3<Float>(Float(lineNorm.x), 0, Float(lineNorm.y)),
                    distanceMeters: dMeters
                )
                latestMeasurement = measurement
                maybeScope(measurement)
            }
        }

        // --- History record ---
        guard !newDetections.isEmpty else { return }
        let dotDets  = newDetections.filter { $0.label == "dot"  || $0.classIndex == 0 }
        let lineDets = newDetections.filter { $0.label == "line" || $0.classIndex == 1 }
        let bestDot  = dotDets.max(by:  { $0.confidence < $1.confidence })
        let bestLine = lineDets.max(by: { $0.confidence < $1.confidence })
        let t = videoImageToViewTransform
        let vp = viewportSize.width > 0 ? viewportSize : CGSize(width: 390, height: 844)
        let lineToDotRatio: Float? = {
            guard let d = bestDot, let l = bestLine else { return nil }
            let dotLong  = laserDetectionLongestSidePixels(d.boundingBox, transform: t, viewport: vp)
            let lineLong = laserDetectionLongestSidePixels(l.boundingBox, transform: t, viewport: vp)
            guard dotLong > 0 else { return nil }
            return lineLong / dotLong
        }()
        let mergedDots  = merged.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }.count
        let mergedLines = merged.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }.count
        let accumulatedRatio: Float? = {
            let mLine = merged.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }
                .max(by: { $0.confidence < $1.confidence })
            let mDot  = merged.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
                .max(by: { $0.confidence < $1.confidence })
            let dot = bestDot ?? mDot
            guard let d = dot, let l = mLine else { return nil }
            let dotLong  = laserDetectionLongestSidePixels(d.boundingBox, transform: t, viewport: vp)
            let lineLong = laserDetectionLongestSidePixels(l.boundingBox, transform: t, viewport: vp)
            guard dotLong > 0 else { return nil }
            return lineLong / dotLong
        }()
        let record = DetectionFrameRecord(
            timestamp: Date(),
            dots: dotDets.count,
            lines: lineDets.count,
            otherCount: newDetections.filter { ($0.classIndex ?? -1) > 1 }.count,
            distanceMeters: latestMeasurement?.distanceMeters,
            lineToDotSizeRatio: lineToDotRatio,
            accumulatedDots: mergedDots,
            accumulatedLines: mergedLines,
            accumulatorFramesUsed: acc.filter { !$0.isEmpty }.count,
            accumulatedLineToDotRatio: accumulatedRatio
        )
        detectionHistory.append(record)
        if detectionHistory.count > 50 { detectionHistory.removeFirst(detectionHistory.count - 50) }
    }

    func maybeScope(_ measurement: LaserDotLineMeasurement?) {
        guard !hasFoundOrigin else { return }
        guard let measurement else { return }

        // Match measurement against any known segment; trigger immediately if within tolerance.
        guard let candidate = candidateSegment(for: measurement.distanceMeters),
              candidate.delta <= videoScopeDistanceToleranceMeters else { return }

        DispatchQueue.main.async {
            self.hasFoundOrigin = true
            self.foundSegment = candidate.segment
            self.pipeline.stop()
        }
    }

    func resetScope() {}

    func resetDetection() {
        hasFoundOrigin = false
        foundSegment = nil
        latestMeasurement = nil
        frameAccumulator = []
        accumulatedDetections = []
        emptyDetectionFrames = 0
        resetScope()
        pipeline.start()
    }

    // MARK: - Segment matching

    func candidateSegment(for distanceMeters: Float) -> (key: String, segment: LaserGuideGridSegment, delta: Float)? {
        guard let laserGuide, !laserGuide.grid.isEmpty else { return nil }
        guard let best = laserGuide.grid.min(by: {
            abs(Float($0.segmentLength) - distanceMeters) < abs(Float($1.segmentLength) - distanceMeters)
        }) else { return nil }
        let delta = abs(Float(best.segmentLength) - distanceMeters)
        let key = "x=\(best.x),z=\(best.z),len=\(best.segmentLength)"
        return (key: key, segment: best, delta: delta)
    }
}
