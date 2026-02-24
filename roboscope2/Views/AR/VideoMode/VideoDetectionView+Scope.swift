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
