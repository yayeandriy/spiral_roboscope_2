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
    var videoScopeAllowedJitterMeters: Float { 0.01 }
    var videoScopeAllowedGapSeconds: TimeInterval { 0.25 }
    var videoScopeMinSamples: Int { 8 }
    var videoScopeStableSeconds: TimeInterval { Double(settings.laserGuideAutoScopeStableSeconds) }

    // MARK: - Scope logic

    func maybeScope(_ measurement: LaserDotLineMeasurement?) {
        guard !hasFoundOrigin else { return }

        let now = CACurrentMediaTime()

        if measurement == nil {
            if autoScopeLastSeenTime > 0, now - autoScopeLastSeenTime > videoScopeAllowedGapSeconds {
                resetScope()
            }
            return
        }
        guard let measurement else { return }
        autoScopeLastSeenTime = now

        // Must match a known segment within tolerance.
        guard let candidate = candidateSegment(for: measurement.distanceMeters),
              candidate.delta <= videoScopeDistanceToleranceMeters else {
            resetScope()
            return
        }

        // Segment consistency across the stability window.
        if autoScopeCandidateKey != candidate.key {
            autoScopeCandidateKey = candidate.key
            autoScopeSamples = []
        }

        autoScopeSamples.append((t: now, d: measurement.distanceMeters))
        autoScopeSamples = autoScopeSamples.filter { now - $0.t <= videoScopeStableSeconds }

        guard autoScopeSamples.count >= videoScopeMinSamples else { return }
        guard let first = autoScopeSamples.first, let last = autoScopeSamples.last else { return }
        guard last.t - first.t >= videoScopeStableSeconds * 0.9 else { return }

        // Require distances to be stable (low jitter).
        let distances = autoScopeSamples.map { $0.d }
        let minD = distances.min() ?? measurement.distanceMeters
        let maxD = distances.max() ?? measurement.distanceMeters
        guard (maxD - minD) <= (videoScopeAllowedJitterMeters * 2) else { return }

        // All checks passed — signal that origin would be placed.
        DispatchQueue.main.async {
            self.hasFoundOrigin = true
            self.foundSegment = candidate.segment
            self.pipeline.stop()
        }
    }

    func resetScope() {
        autoScopeCandidateKey = nil
        autoScopeSamples = []
        autoScopeLastSeenTime = 0
    }

    func resetDetection() {
        hasFoundOrigin = false
        foundSegment = nil
        latestMeasurement = nil
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
