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
        print("[LaserGuideML] loadModelForSession: started spaceId=\(session.spaceId)")
        guard let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) else {
            print("[LaserGuideML] loadModelForSession: space not found")
            mlModelLoadError = "Space not found for this session."
            return
        }
        print("[LaserGuideML] loadModelForSession: space found, mlModelUrl=\(space.mlModelUrl ?? "nil")")
        isLoadingMLModel = true
        mlModelLoadError = nil
        do {
            let url = try await MLModelDownloadService.shared.ensureModelForSpace(space)
            print("[LaserGuideML] loadModelForSession: model ready at \(url.lastPathComponent)")
            mlDetection.setModelURL(url)
        } catch {
            print("[LaserGuideML] loadModelForSession: FAILED \(error)")
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
        lockedDotWorld = nil
        originStabilityStartTime = 0
        originStabilityProgress = 0

        frameOriginAnchor?.isEnabled = false
        originZBadgeText = nil
        originZBadgeScreenPoint = nil
        refZBadgeText = nil
        refZBadgeScreenPoint = nil
        refTipBadgeText = nil
        refTipBadgeScreenPoint = nil
        removeDotCone()

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

    /// Processes raw ML detections: applies filters, updates 2-D accumulator for overlay,
    /// performs per-frame 3-D raycast + immediate origin placement (when enabled), and
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

        // --- History record ---
        guard !newDetections.isEmpty else { return }
        let dotDets  = newDetections.filter { $0.label == "dot"  || $0.classIndex == 0 }
        let lineDets = newDetections.filter { $0.label == "line" || $0.classIndex == 1 }
        let bestDot  = dotDets.max(by: { $0.confidence < $1.confidence })
        let bestLine = lineDets.max(by: { $0.confidence < $1.confidence })
        let t = imageToViewTransform
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
            distanceMeters: latestLaserMeasurement?.distanceMeters,
            lineToDotSizeRatio: lineToDotRatio,
            accumulatedDots: mergedDots,
            accumulatedLines: mergedLines,
            accumulatorFramesUsed: acc.filter { !$0.isEmpty }.count,
            accumulatedLineToDotRatio: accumulatedRatio
        )
        detectionHistory.append(record)
        if detectionHistory.count > 50 { detectionHistory.removeFirst(detectionHistory.count - 50) }
    }

    /// Processes an AR frame update — routes pixels through the ML pipeline, handles
    /// auto-return-to-detection, badge positioning, transform updates, and edge checks.
    func processFrameUpdate() {
        guard let arView, let frame = arView.session.currentFrame else { return }

        let interfaceOrientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        pipeline.processPixelBuffer(
            frame.capturedImage,
            orientation: Self.cgImageOrientation(for: interfaceOrientation)
        )

        // After auto-scope, monitor how far the user moves away from the scoped dot.
        maybeReturnToDetectionIfUserMovedAway(frame)

        // Keep Z-distance badges pinned to world positions as camera moves.
        if hasAutoScoped {
            refreshBadgePositions()
        }

        // Map normalized image coordinates -> normalized view coordinates.
        // Use arView.bounds, NOT viewportSize, because the ARView fills the entire
        // screen (including behind safe areas), while GeometryReader's size excludes
        // safe-area insets.  A mismatch here causes raycast screen points to be offset.
        let arSize = arView.bounds.size
        if arSize.width > 0 && arSize.height > 0 {
            imageToViewTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: arSize)
        }

        // --- 3-D per-frame raycast using the CURRENT frame's transform ---
        // Use per-frame detections when available; fall back to accumulated so a dot that
        // flickered in a previous frame (still visible in the accumulator) still triggers Phase 1.
        if settings.usePerFrame3DPlacement, !hasAutoScoped {
            let detectionsForPlacement = mlDetection.detections.isEmpty ? accumulatedDetections : mlDetection.detections
            tryPlaceOriginFromDetections(
                detectionsForPlacement,
                transform: imageToViewTransform,
                viewportSize: arSize
            )
        }

        // Check if target crosses an object edge (throttled ~4x/sec)
        if hasAutoScoped && manualPlacementState == .inactive {
            let now = CACurrentMediaTime()
            if now - lastEdgeCheckTime > 0.25 {
                lastEdgeCheckTime = now
                markerService.updateTargetEdgeState(targetCorners: getTargetRectCorners())
            }
        }
    }
}
