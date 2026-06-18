//
//  LaserGuideARSessionView+Scoping.swift
//  roboscope2
//
//  Auto-scope, return-to-detection, snap, debug, and session-end logic for LaserGuideARSessionView.
//

import SwiftUI
import RealityKit
import ARKit
import UIKit
import Combine
import QuartzCore
import AudioToolbox

extension LaserGuideARSessionView {

    /// Per-frame immediate origin placement — no stability delay.
    /// Called from the accumulator when the current frame has both dot and line 3-D positions.
    func placeOriginImmediately(_ measurement: LaserDotLineMeasurement) {
        guard !hasAutoScoped else { return }

        guard let candidate = candidateSegment(for: measurement.distanceMeters) else {
            logAlways("SEGMENT no match  dist=\(String(format:"%.3f",measurement.distanceMeters))m")
            return
        }

        guard candidate.delta <= laserGuideDistanceToleranceMeters else {
            logAlways("SEGMENT out of tolerance  dist=\(String(format:"%.3f",measurement.distanceMeters))m segment=\(candidate.key) delta=\(String(format:"%.3f",candidate.delta))m tolerance=\(String(format:"%.3f",laserGuideDistanceToleranceMeters))m")
            return
        }

        let now = CACurrentMediaTime()
        print("[OriginTrace] ★ SEGMENT MATCH  dist=\(String(format:"%.3f",measurement.distanceMeters))m segment=\(candidate.key) delta=\(String(format:"%.3f",candidate.delta))m")

        if let snappedSegment = applyLaserGuideIfPossible(measurement) {
            autoScopedDotWorld = measurement.dotWorld
            autoScopedAtTime = now
            autoScopedSegment = snappedSegment

            // Store dot Z in FrameOrigin coordinates (after snap).
            let inv = frameOriginTransform.inverse
            let dotLocal = inv * SIMD4<Float>(measurement.dotWorld.x, measurement.dotWorld.y, measurement.dotWorld.z, 1)
            autoScopedDotLocalZ = dotLocal.z

            // Dynamic restart threshold: half of the Z spacing to the nearest neighbor segment.
            autoScopeRestartThresholdZMeters = computeAutoRestartThresholdZ(for: snappedSegment)

            hasAutoScoped = true
            lockedDotWorld = nil  // release the two-phase lock

            // Strong haptic + sound feedback so the operator feels the snap.
            let haptic = UINotificationFeedbackGenerator()
            haptic.notificationOccurred(.success)
            AudioServicesPlaySystemSound(1519)

            // After auto-scope, show origin gizmo again.
            frameOriginAnchor?.isEnabled = true

            Task { @MainActor in
                markerService.setMarkersVisible(true)
            }

            pipeline.stop()
        }
    }

    // MARK: - Origin trace (throttled logging)

    /// Timestamp of last origin-trace log line; used to throttle to ~1 log/s.
    private static var lastOriginTraceLog: TimeInterval = 0

    /// Log only every ~1 second to keep console readable.  Always logs on state transitions
    /// (star-prefixed lines).
    private func logTT(_ message: String) {
        let now = CACurrentMediaTime()
        if now - Self.lastOriginTraceLog >= 1.0 {
            Self.lastOriginTraceLog = now
            print("[OriginTrace] \(message)")
        }
    }

    private func logAlways(_ message: String) {
        print("[OriginTrace] ★ \(message)")
    }

    /// Performs a raycast from a 2-D detection's bounding-box center to get a 3-D world position.
    func raycastDetection(_ detection: LaserMLDetection) -> SIMD3<Float>? {
        raycastDetection(detection, transform: imageToViewTransform, viewportSize: viewportSize)
    }

    /// Raycast using explicit transform and viewport (for use with a specific frame's data).
    func raycastDetection(_ detection: LaserMLDetection, transform: CGAffineTransform, viewportSize: CGSize) -> SIMD3<Float>? {
        guard let arView else { return nil }
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }

        let bbox = detection.boundingBox
        let centerNormImg = CGPoint(x: bbox.midX, y: bbox.midY)
        let centerNormView = centerNormImg.applying(transform)
        let centerPx = CGPoint(
            x: centerNormView.x * viewportSize.width,
            y: centerNormView.y * viewportSize.height
        )

        // Camera position for distance reference
        let camPos: SIMD3<Float>? = {
            guard let frame = arView.session.currentFrame else { return nil }
            let c = frame.camera.transform.columns.3
            return SIMD3<Float>(c.x, c.y, c.z)
        }()

        var hitKind = "none"
        var hit: ARRaycastResult?
        let existingHits = arView.raycast(from: centerPx, allowing: .existingPlaneGeometry, alignment: .any)
        if let h = existingHits.first { hit = h; hitKind = "existingPlane" }
        else if let h = arView.raycast(from: centerPx, allowing: .estimatedPlane, alignment: .any).first { hit = h; hitKind = "estimatedPlane" }

        guard let hit else {
            logTT("RAYCAST MISS  class=\(detection.label) conf=\(String(format:"%.2f",detection.confidence)) normImg=(\(String(format:"%.3f",bbox.midX)),\(String(format:"%.3f",bbox.midY))) normView=(\(String(format:"%.3f",centerNormView.x)),\(String(format:"%.3f",centerNormView.y))) screenPt=(\(String(format:"%.0f",centerPx.x)),\(String(format:"%.0f",centerPx.y)))")
            return nil
        }
        let world = hit.worldTransform.columns.3
        let pos = SIMD3<Float>(world.x, world.y, world.z)
        let dist = camPos.map { simd_distance(pos, $0) }
        let distStr = dist.map { String(format:"%.3f", $0) } ?? "?"
        let arBounds = arView.bounds.size
        logAlways("RAYCAST HIT \(hitKind) class=\(detection.label) cam=(\(camPos.map{"\(String(format:"%.3f",$0.x)),\(String(format:"%.3f",$0.y)),\(String(format:"%.3f",$0.z))"} ?? "?")) hit=(\(String(format:"%.3f",pos.x)),\(String(format:"%.3f",pos.y)),\(String(format:"%.3f",pos.z))) distFromCam=\(distStr)m bbox=\(String(format:"%.3f",bbox.midX)),\(String(format:"%.3f",bbox.midY)) screenPt=(\(String(format:"%.0f",centerPx.x)),\(String(format:"%.0f",centerPx.y))) viewport=\(viewportSize) arViewBounds=\(arBounds)")
        return pos
    }

    /// Two-phase origin placement: phase 1 locks the dot's 3-D position; phase 2 finds the
    /// line and immediately places the origin.  This avoids the "both in one frame" requirement
    /// that caused raycasts to hit random geometry when only one class was visible.
    func tryPlaceOriginFromDetections(
        _ detections: [LaserMLDetection],
        transform: CGAffineTransform,
        viewportSize: CGSize
    ) {
        let filtered = filterLineOverDot(detections)
        let dotCount  = filtered.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }.count
        let lineCount = filtered.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }.count

        if lockedDotWorld == nil {
            // Phase 1 — lock the dot.
            let dotDets = filtered.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
            guard let bestDot = dotDets.max(by: { $0.confidence < $1.confidence }) else {
                logTT("PHASE1 no dot  totalDet=\(filtered.count) dots=\(dotCount) lines=\(lineCount)")
                return
            }
            logTT("PHASE1 trying dot  conf=\(String(format:"%.2f",bestDot.confidence)) bbox=(\(String(format:"%.3f",bestDot.boundingBox.midX)),\(String(format:"%.3f",bestDot.boundingBox.midY))) size=(\(String(format:"%.3f",bestDot.boundingBox.width)),\(String(format:"%.3f",bestDot.boundingBox.height)))")

            // Screen-center proximity gate: reject dots whose bbox center is far from
            // the reticle center.  The user naturally aims the reticle at the dot, so a
            // large offset indicates a false positive on a different surface.
            let bboxNormCenter = CGPoint(x: bestDot.boundingBox.midX, y: bestDot.boundingBox.midY)
            let bboxViewCenter = bboxNormCenter.applying(transform)
            let bboxPx = CGPoint(x: bboxViewCenter.x * viewportSize.width, y: bboxViewCenter.y * viewportSize.height)
            let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let pxDelta = hypot(bboxPx.x - screenCenter.x, bboxPx.y - screenCenter.y)
            let maxPxDelta: CGFloat = 150
            guard pxDelta <= maxPxDelta else {
                logAlways("PHASE1 REJECTED (off-center)  bboxPx=(\(String(format:"%.0f",bboxPx.x)),\(String(format:"%.0f",bboxPx.y))) screenCenter=(\(String(format:"%.0f",screenCenter.x)),\(String(format:"%.0f",screenCenter.y))) Δ=\(String(format:"%.0f",pxDelta))px > \(String(format:"%.0f",maxPxDelta))px")
                return
            }

            guard let dotWorld = raycastDetection(bestDot, transform: transform, viewportSize: viewportSize) else { return }
            lockedDotWorld = dotWorld
            logAlways("DOT LOCKED  world=(\(String(format:"%.3f",dotWorld.x)),\(String(format:"%.3f",dotWorld.y)),\(String(format:"%.3f",dotWorld.z)))")
            return
        }

        // Phase 2 — dot is locked, look for the line.
        guard let dotWorld = lockedDotWorld else { return }
        let lineDets = filtered.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }
        guard let bestLine = lineDets.max(by: { $0.confidence < $1.confidence }) else {
            logTT("PHASE2 no line  dotLocked=true  dots=\(dotCount) lines=\(lineCount)")
            return
        }
        logTT("PHASE2 trying line  conf=\(String(format:"%.2f",bestLine.confidence)) bbox=(\(String(format:"%.3f",bestLine.boundingBox.midX)),\(String(format:"%.3f",bestLine.boundingBox.midY)))")
        guard let lineWorld = raycastDetection(bestLine, transform: transform, viewportSize: viewportSize) else { return }

        let yDelta = abs(lineWorld.y - dotWorld.y)
        guard yDelta <= mlDetection.maxDotLineYDeltaMeters else {
            logAlways("PHASE2 REJECTED  yDelta=\(String(format:"%.3f",yDelta)) > tolerance=\(String(format:"%.3f",mlDetection.maxDotLineYDeltaMeters))")
            return
        }

        let dx = dotWorld.x - lineWorld.x
        let dy = dotWorld.y - lineWorld.y
        let dz = dotWorld.z - lineWorld.z
        let distance = sqrt(dx * dx + dy * dy + dz * dz)
        let measurement = LaserDotLineMeasurement(
            dotWorld: dotWorld,
            lineWorld: lineWorld,
            distanceMeters: distance
        )
        latestLaserMeasurement = measurement
        logAlways("MEASURE  dot=(\(String(format:"%.3f",dotWorld.x)),\(String(format:"%.3f",dotWorld.y)),\(String(format:"%.3f",dotWorld.z))) line=(\(String(format:"%.3f",lineWorld.x)),\(String(format:"%.3f",lineWorld.y)),\(String(format:"%.3f",lineWorld.z))) dist=\(String(format:"%.3f",distance))m")
        placeOriginImmediately(measurement)
    }

    func maybeReturnToDetectionIfUserMovedAway(_ frame: ARFrame) {
        guard hasAutoScoped, let dotLocalZ = autoScopedDotLocalZ else { return }

        // Compute camera Z in FrameOrigin coordinates.
        let cameraTransform = frame.camera.transform
        let cameraWorld = SIMD4<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z,
            1
        )
        let inv = frameOriginTransform.inverse
        let cameraLocal = inv * cameraWorld

        let dz = abs(cameraLocal.z - dotLocalZ)
        let thresholdZ = autoScopeRestartThresholdZMeters ?? Float(settings.laserGuideAutoRestartDistanceMeters)
        guard dz > thresholdZ else { return }

        let now = CACurrentMediaTime()
        let secondsSinceScope = autoScopedAtTime > 0 ? (now - autoScopedAtTime) : 0
        print("[LaserGuideSnap] Auto-return to detection: |ΔZ|=\(String(format: "%.2f", dz))m after \(String(format: "%.2f", secondsSinceScope))s (thresholdZ \(String(format: "%.2f", thresholdZ))m)")

        DispatchQueue.main.async {
            self.enterDetectionMode()
        }
    }

    private func updateBadgeScreenPoint(world: SIMD3<Float>, setter: (CGPoint) -> Void) {
        guard let arView, let frame = arView.session.currentFrame,
              let sp = projectWorldToScreen(worldPosition: world, frame: frame, arView: arView) else { return }
        setter(sp)
    }

    func snapFrameOriginToAlignDot(dotWorld: SIMD3<Float>, lineWorld: SIMD3<Float>, segment: LaserGuideGridSegment) {
        // Compute direction from dot → line
        let R = lineWorld - dotWorld
        let R_xz = SIMD2<Float>(R.x, R.z)
        let rawLen = simd_length(R)
        let r = normalize(R_xz)
        print("[OriginTrace] ★ DIRECTION  dot→line=(\(String(format:"%.3f",R.x)),\(String(format:"%.3f",R.z))) rawLen=\(String(format:"%.3f",rawLen))m  dir=(\(String(format:"%.3f",r.x)),\(String(format:"%.3f",r.y)))")

        let S = SIMD2<Float>(Float(segment.x), Float(segment.z))
        let segLen = simd_length(S)
        let offset_xz = r * segLen
        let O = SIMD3<Float>(dotWorld.x - offset_xz.x, dotWorld.y, dotWorld.z - offset_xz.y)
        print("[OriginTrace] ★ ORIGIN  dotWorld=(\(String(format:"%.3f",dotWorld.x)),\(String(format:"%.3f",dotWorld.y)),\(String(format:"%.3f",dotWorld.z)))  dir=(\(String(format:"%.3f",r.x)),\(String(format:"%.3f",r.y)))  segXZ=(\(segment.x),\(segment.z)) len=\(String(format:"%.3f",segLen))  offset=(\(String(format:"%.3f",offset_xz.x)),\(String(format:"%.3f",offset_xz.y)))  origin=(\(String(format:"%.3f",O.x)),\(String(format:"%.3f",O.y)),\(String(format:"%.3f",O.z)))")

        let newZ = SIMD3<Float>(r.x, 0, r.y)
        let newX = SIMD3<Float>(r.y, 0, -r.x)
        let newY = SIMD3<Float>(0, 1, 0)

        // Build rotation matrix
        var rotMatrix = matrix_identity_float4x4
        rotMatrix.columns.0 = SIMD4<Float>(newX.x, newX.y, newX.z, 0)
        rotMatrix.columns.1 = SIMD4<Float>(newY.x, newY.y, newY.z, 0)
        rotMatrix.columns.2 = SIMD4<Float>(newZ.x, newZ.y, newZ.z, 0)

        // Place reference cross (red) at dot position only
        placeReferenceCross(at: dotWorld, name: "ref_dot",
                            color: UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0),
                            orientation: rotMatrix, anchorState: $debugDotAnchor)

        // Debug: bright yellow sphere at dotWorld (no rotation) so we can see the
        // exact raycast hit point independent of the cross orientation.
        placeDebugDot(at: dotWorld, name: "debug_dot_sphere",
                       color: UIColor.yellow, anchorState: $debugLineAnchor)

        // Z distance badge at red cross (dot→origin)
        let zDist = simd_distance(dotWorld, O)
        if zDist < 1.0 {
            refZBadgeText = "Z: \(String(format: "%.0f", zDist * 100)) cm"
        } else {
            refZBadgeText = "Z: \(String(format: "%.2f", zDist))m"
        }
        let dotBadgeWorld = dotWorld + SIMD3<Float>(0, 0.15, 0)
        updateBadgeScreenPoint(world: dotBadgeWorld, setter: { refZBadgeScreenPoint = $0 })

        // Origin Z badge
        originZBadgeText = "Z: \(String(format: "%.2f", autoScopedDotLocalZ ?? 0))m"
        updateBadgeScreenPoint(world: O + SIMD3<Float>(0, 0.08, 0), setter: { originZBadgeScreenPoint = $0 })

        var newTransform = rotMatrix
        newTransform.columns.3 = SIMD4<Float>(O.x, O.y, O.z, 1)

        frameOriginTransform = newTransform
        print("[LaserGuideSnap]   ✓ frameOriginTransform updated")

        // Verification: transform dot back to local coords and check if it matches segment
        let inverseTransform = newTransform.inverse
        let dotHomogeneous = SIMD4<Float>(dotWorld.x, dotWorld.y, dotWorld.z, 1)
        let dotLocal = inverseTransform * dotHomogeneous
        let dotLocalXZ = SIMD2<Float>(dotLocal.x, dotLocal.z)
        let segmentXZ = SIMD2<Float>(Float(segment.x), Float(segment.z))
        let error = length(dotLocalXZ - segmentXZ)

        print("[LaserGuideSnap]   VERIFICATION:")
        print("[LaserGuideSnap]     dotLocal: x=\(dotLocal.x), z=\(dotLocal.z)")
        print("[LaserGuideSnap]     segment:  x=\(segment.x), z=\(segment.z)")
        print("[LaserGuideSnap]     error (XZ distance): \(error)m")

        if frameOriginAnchor == nil {
            print("[LaserGuideSnap]   placing gizmo (was nil)")
            placeFrameOriginGizmo(at: frameOriginTransform)
        } else {
            print("[LaserGuideSnap]   recreating gizmo at new position")
            placeFrameOriginGizmo(at: frameOriginTransform)
        }
        updateMarkersForNewFrameOrigin()
        print("[LaserGuideSnap]   snap complete")
    }

    func placeReferenceCross(at position: SIMD3<Float>, name: String, color: UIColor, orientation: simd_float4x4, anchorState: Binding<AnchorEntity?>) {
        guard let arView = arView else { return }

        if let existing = anchorState.wrappedValue {
            arView.scene.removeAnchor(existing)
        }

        // Build transform with position + orientation
        var t = orientation
        t.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)

        let anchor = AnchorEntity(world: t)
        let cross = ManualPointHelpers.makeReferenceCross(name: name, color: color)
        anchor.addChild(cross)
        arView.scene.addAnchor(anchor)
        anchorState.wrappedValue = anchor
        print("[RefCross] placed \(name) at \(position) aligned to origin Z")
    }

    /// Places a simple sphere at a world position — no rotation, just a bright dot.
    private func placeDebugDot(at position: SIMD3<Float>, name: String, color: UIColor, anchorState: Binding<AnchorEntity?>) {
        guard let arView = arView else { return }
        if let existing = anchorState.wrappedValue {
            arView.scene.removeAnchor(existing)
        }
        let anchor = AnchorEntity(world: position)
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.02),
            materials: [UnlitMaterial(color: color)]
        )
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchorState.wrappedValue = anchor
        print("[DebugDot] placed \(name) at \(position)")
    }

    func endARSession() {
        captureSession.stop()
        isSessionActive = false
    }

    func completeSession() async {
        do {
            _ = try await workSessionService.completeSession(
                id: session.id,
                version: session.version
            )

            endARSession()
            dismiss()
        } catch {
            errorMessage = "Failed to complete session: \(error.localizedDescription)"
        }
    }
}
