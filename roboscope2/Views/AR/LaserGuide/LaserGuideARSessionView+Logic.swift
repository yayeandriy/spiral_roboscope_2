//
//  LaserGuideARSessionView+Logic.swift
//  roboscope2
//
//  Core detection and AR logic methods for LaserGuideARSessionView.
//

import SwiftUI
import RealityKit
import ARKit
import UIKit
import Combine
import QuartzCore

extension LaserGuideARSessionView {

    func saveMLDetectionSettings() {
        let settings = LaserMLDetectionSettings(
            confidenceThreshold: mlDetection.confidenceThreshold,
            useROI: mlDetection.useROI,
            roiSize: mlDetection.roiSize,
            maxDetections: mlDetection.maxDetections
        )
        SpaceMLDetectionSettingsStore.shared.save(spaceId: session.spaceId, settings: settings)
    }

    func applyMLDetectionSettings(_ settings: LaserMLDetectionSettings) {
        mlDetection.confidenceThreshold = settings.confidenceThreshold
        mlDetection.useROI = settings.useROI
        mlDetection.roiSize = settings.roiSize
        mlDetection.maxDetections = settings.maxDetections
    }

    func startARSession() {
        captureSession.start()
        isSessionActive = true
    }

    /// Downloads (or reuses) the Space's ML model and assigns it to `mlDetection`.
    /// Sets `isLoadingModel` / `modelLoadError` for UI feedback.
    @MainActor
    func loadModelForSession() async {
        guard let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) else {
            mlModelLoadError = "Space not found for this session."
            return
        }
        isLoadingMLModel = true
        mlModelLoadError = nil
        do {
            let url = try await MLModelDownloadService.shared.ensureModelForSpace(space)
            mlDetection.setModelURL(url)
        } catch {
            mlModelLoadError = error.localizedDescription
        }
        isLoadingMLModel = false
    }

    @MainActor
    func fetchLaserGuideIfNeeded() async {
        guard laserGuide == nil else { return }
        do {
            laserGuideFetchError = nil
            laserGuide = try await LaserGuideService.shared.fetchLaserGuide(spaceId: session.spaceId)
            print("[LaserGuideSnap] Fetched guide with \(laserGuide?.grid.count ?? 0) segments")
            laserGuide?.grid.forEach { seg in
                print("[LaserGuideSnap]   Segment: x=\(seg.x), z=\(seg.z), length=\(seg.segmentLength)")
            }
        } catch {
            print("[LaserGuideSnap] Fetch failed: \(error)")
            laserGuideFetchError = error.localizedDescription
            laserGuide = nil
        }
    }

    @discardableResult
    func applyLaserGuideIfPossible(_ measurement: LaserDotLineMeasurement?) -> LaserGuideGridSegment? {
        guard let measurement else {
            print("[LaserGuideSnap] No measurement")
            return nil
        }
        guard let laserGuide else {
            print("[LaserGuideSnap] No laser guide loaded")
            return nil
        }
        guard !laserGuide.grid.isEmpty else {
            print("[LaserGuideSnap] Grid is empty")
            return nil
        }

        let now = CACurrentMediaTime()
        guard now - lastLaserGuideSnapTime >= laserGuideSnapCooldownSeconds else {
            print("[LaserGuideSnap] Cooldown active (last snap \(now - lastLaserGuideSnapTime)s ago)")
            return nil
        }

        print("[LaserGuideSnap] Measurement: dot=\(measurement.dotWorld), line=\(measurement.lineWorld), dist=\(measurement.distanceMeters)m")

        // Match distance to any segment length.
        if let best = laserGuide.grid.min(by: {
            abs(Float($0.segmentLength) - measurement.distanceMeters) < abs(Float($1.segmentLength) - measurement.distanceMeters)
        }) {
            let delta = abs(Float(best.segmentLength) - measurement.distanceMeters)
            print("[LaserGuideSnap] Best match: segment(x=\(best.x), z=\(best.z), len=\(best.segmentLength)), delta=\(delta)m, tolerance=\(laserGuideDistanceToleranceMeters)m")

            guard delta <= laserGuideDistanceToleranceMeters else {
                print("[LaserGuideSnap] Delta exceeds tolerance, skipping snap")
                return nil
            }

            print("[LaserGuideSnap] ✓ Snapping origin to align dot at segment (x=\(best.x), z=\(best.z))")
            snapFrameOriginToAlignDot(dotWorld: measurement.dotWorld, lineWorld: measurement.lineWorld, segment: best)
            lastLaserGuideSnapTime = now
            return best
        } else {
            print("[LaserGuideSnap] No segments to match")
            return nil
        }
    }

    func enterDetectionMode() {
        // Restart AR tracking so detection restarts in a fresh AR world.
        captureSession.restart()

        hasAutoScoped = false
        latestLaserMeasurement = nil
        lastLaserGuideSnapTime = 0
        autoScopedDotWorld = nil
        autoScopedAtTime = 0
        autoScopedDotLocalZ = nil
        autoScopeRestartThresholdZMeters = nil
        autoScopedSegment = nil

        // In detection mode we hide the origin gizmo + any debug detection spheres.
        frameAccumulator = []
        accumulatedDetections = []
        emptyDetectionFrames = 0
        originStabilityStartTime = 0
        originStabilityProgress = 0

        frameOriginAnchor?.isEnabled = false
        originZBadgeText = nil
        originZBadgeScreenPoint = nil
        refZBadgeText = nil
        refZBadgeScreenPoint = nil

        Task { @MainActor in
            markerService.setMarkersVisible(false)
        }

        pipeline.start()
    }

    func computeAutoRestartThresholdZ(for segment: LaserGuideGridSegment) -> Float? {
        guard let laserGuide, laserGuide.grid.count >= 2 else { return nil }

        // Prefer neighbors with the same X (typical "column" alignment), but fall back to any segment.
        let xEpsilon: Double = 1e-4
        let sameX = laserGuide.grid.filter { abs($0.x - segment.x) <= xEpsilon }
        let pool = (sameX.count >= 2) ? sameX : laserGuide.grid

        let z0 = segment.z
        let deltas = pool
            .map { abs($0.z - z0) }
            .filter { $0 > 1e-6 }

        guard let minDelta = deltas.min() else { return nil }
        return 0.75 * Float(minDelta)
    }

    func candidateSegment(for distanceMeters: Float) -> (key: String, segment: LaserGuideGridSegment, delta: Float)? {
        guard let laserGuide, !laserGuide.grid.isEmpty else { return nil }
        guard let best = laserGuide.grid.min(by: {
            abs(Float($0.segmentLength) - distanceMeters) < abs(Float($1.segmentLength) - distanceMeters)
        }) else {
            return nil
        }
        let delta = abs(Float(best.segmentLength) - distanceMeters)
        let key = "x=\(best.x),z=\(best.z),len=\(best.segmentLength)"
        return (key: key, segment: best, delta: delta)
    }
}
