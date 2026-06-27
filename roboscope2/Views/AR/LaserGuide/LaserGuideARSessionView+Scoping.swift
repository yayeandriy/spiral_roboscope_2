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
        guard isPlacementButtonHeld else { return }
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

            // During hold-to-place, keep gizmo/markers hidden; stopPlacement() will show them.
            if !isPlacementButtonHeld {
                frameOriginAnchor?.isEnabled = true
                debugDotAnchor?.isEnabled = true
                debugLineAnchor?.isEnabled = true
                removeDotCone()
                Task { @MainActor in
                    markerService.setMarkersVisible(true)
                }
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
        if let h = arView.raycast(from: centerPx, allowing: .existingPlaneGeometry, alignment: .any).first {
            hit = h; hitKind = "existingPlane"
        } else if let h = arView.raycast(from: centerPx, allowing: .estimatedPlane, alignment: .any).first {
            hit = h; hitKind = "estimatedPlane"
        } else if let h = arView.raycast(from: centerPx, allowing: .existingPlaneInfinite, alignment: .any).first {
            hit = h; hitKind = "infinitePlane"
        }

        guard let hit else {
            logAlways("RAYCAST MISS  class=\(detection.label) conf=\(String(format:"%.2f",detection.confidence)) normImg=(\(String(format:"%.3f",bbox.midX)),\(String(format:"%.3f",bbox.midY))) normView=(\(String(format:"%.3f",centerNormView.x)),\(String(format:"%.3f",centerNormView.y))) screenPt=(\(String(format:"%.0f",centerPx.x)),\(String(format:"%.0f",centerPx.y)))")
            return nil
        }
        let world = hit.worldTransform.columns.3
        let pos = SIMD3<Float>(world.x, world.y, world.z)
        guard !pos.x.isNaN, !pos.y.isNaN, !pos.z.isNaN else {
            logAlways("RAYCAST NaN  class=\(detection.label) kind=\(hitKind) — discarding hit")
            return nil
        }
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
            logAlways("PHASE1 trying dot  conf=\(String(format:"%.2f",bestDot.confidence)) bbox=(\(String(format:"%.3f",bestDot.boundingBox.midX)),\(String(format:"%.3f",bestDot.boundingBox.midY))) size=(\(String(format:"%.3f",bestDot.boundingBox.width)),\(String(format:"%.3f",bestDot.boundingBox.height)))")

            guard let dotWorld = raycastDetection(bestDot, transform: transform, viewportSize: viewportSize) else { return }
            lockedDotWorld = dotWorld
            placeDotCone(at: dotWorld)
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
        if settings.useYDeltaCheck {
            guard yDelta <= mlDetection.maxDotLineYDeltaMeters else {
                logAlways("PHASE2 REJECTED  yDelta=\(String(format:"%.3f",yDelta)) > tolerance=\(String(format:"%.3f",mlDetection.maxDotLineYDeltaMeters))")
                return
            }
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
        // --- Step 1: compute direction from dot → line (short baseline, always available) ---
        let R = lineWorld - dotWorld
        let R_xz = SIMD2<Float>(R.x, R.z)
        let rawLen = simd_distance(dotWorld, lineWorld)
        var r = normalize(R_xz)
        print("[OriginTrace] ★ DIRECTION  dot→line=(\(String(format:"%.3f",R.x)),\(String(format:"%.3f",R.z))) rawLen=\(String(format:"%.3f",rawLen))m  dir=(\(String(format:"%.3f",r.x)),\(String(format:"%.3f",r.y)))")

        // --- Step 2: try to improve direction using the long baseline between
        //     the most-distant anchors known for this run.
        //
        //     Each anchor's world_position is where the laser DOT was detected,
        //     i.e. the same coordinate that dotWorld carries for the current snap.
        //     Sorting by local_z and taking near/far gives a baseline proportional
        //     to the physical distance between two table levels — often 16 m+,
        //     versus the ~0.5 m dot→line baseline.  Angular errors shrink by the
        //     same ratio, eliminating the position drift seen at far segments.
        //
        //     Sources of known positions (union for this run):
        //       • AnchorService.shared.anchors  — already persisted to the API
        //       • pendingAnchor                 — snapped but not yet committed
        //       • current snap (dotWorld)       — the point being placed right now
        // -----------------------------------------------------------------------
        // Minimum local_z gap between the two reference anchors to trust the baseline.
        // Must exceed the largest segment_length (dot→line distance) by a meaningful margin
        // so the anchor baseline actually outperforms dot→line.  0.5 m is ~3× the
        // typical segment_length (0.15–0.45 m) and covers the Room test (1.65 m gap).
        let minBaselineMeters: Double = 0.5

        struct AnchorPoint { let localZ: Double; let xz: SIMD2<Float>; let source: String }
        var points: [AnchorPoint] = []

        // Persisted anchors for this run
        let allCached = AnchorService.shared.anchors
        let forRun = allCached.filter { $0.run == currentRun }
        print("[BaselineDBG] currentRun=\(currentRun)  cachedTotal=\(allCached.count)  forRun=\(forRun.count)")
        for a in forRun {
            let xz = SIMD2<Float>(Float(a.worldPosition[0]), Float(a.worldPosition[2]))
            print("[BaselineDBG]   PERSISTED  localZ=\(String(format:"%.4f",a.localZ))  worldPos=[\(String(format:"%.3f",a.worldPosition[0])),\(String(format:"%.3f",a.worldPosition[1])),\(String(format:"%.3f",a.worldPosition[2]))]  xz=(\(String(format:"%.3f",xz.x)),\(String(format:"%.3f",xz.y)))")
            points.append(AnchorPoint(localZ: a.localZ, xz: xz, source: "persisted"))
        }
        // Pending anchor from the previous snap (not yet sent to the API)
        if let p = pendingAnchor {
            let xz = SIMD2<Float>(p.position.x, p.position.z)
            print("[BaselineDBG]   PENDING  run=\(p.run)  localZ=\(String(format:"%.4f",p.localZ))  pos=(\(String(format:"%.3f",p.position.x)),\(String(format:"%.3f",p.position.y)),\(String(format:"%.3f",p.position.z)))  xz=(\(String(format:"%.3f",xz.x)),\(String(format:"%.3f",xz.y)))  runMatch=\(p.run == currentRun)")
            if p.run == currentRun {
                points.append(AnchorPoint(localZ: p.localZ, xz: xz, source: "pending"))
            }
        } else {
            print("[BaselineDBG]   PENDING  nil")
        }
        // Current snap
        let currentXZ = SIMD2<Float>(dotWorld.x, dotWorld.z)
        print("[BaselineDBG]   CURRENT  localZ=\(String(format:"%.4f",segment.z))  dotWorld=(\(String(format:"%.3f",dotWorld.x)),\(String(format:"%.3f",dotWorld.y)),\(String(format:"%.3f",dotWorld.z)))  xz=(\(String(format:"%.3f",currentXZ.x)),\(String(format:"%.3f",currentXZ.y)))")
        points.append(AnchorPoint(localZ: segment.z, xz: currentXZ, source: "current"))

        // Deduplicate by local_z (keep first occurrence — they should be the same point)
        var seen = Set<Double>()
        let unique = points.filter { seen.insert($0.localZ).inserted }
        print("[BaselineDBG] points=\(points.count)  unique=\(unique.count)")

        if unique.count >= 2 {
            let sorted = unique.sorted { $0.localZ < $1.localZ }
            let near   = sorted.first!
            let far    = sorted.last!
            let baseline = far.localZ - near.localZ

            print("[BaselineDBG] near=[\(near.source)] localZ=\(String(format:"%.4f",near.localZ)) xz=(\(String(format:"%.3f",near.xz.x)),\(String(format:"%.3f",near.xz.y)))  far=[\(far.source)] localZ=\(String(format:"%.4f",far.localZ)) xz=(\(String(format:"%.3f",far.xz.x)),\(String(format:"%.3f",far.xz.y)))  baseline=\(String(format:"%.3f",baseline))m")

            if baseline >= minBaselineMeters {
                let d = far.xz - near.xz
                let dLen = simd_length(d)
                print("[BaselineDBG] d=(\(String(format:"%.3f",d.x)),\(String(format:"%.3f",d.y)))  dLen=\(String(format:"%.3f",dLen))m")
                if dLen > 0.05 {   // sanity: at least 5 cm world-space separation
                    let r_anchors = d / dLen
                    print("[OriginTrace] ★ DIRECTION  overriding with anchor baseline: nearZ=\(String(format:"%.2f",near.localZ))m farZ=\(String(format:"%.2f",far.localZ))m baseline=\(String(format:"%.2f",baseline))m worldSep=\(String(format:"%.3f",dLen))m  dir=(\(String(format:"%.3f",r_anchors.x)),\(String(format:"%.3f",r_anchors.y)))")
                    r = r_anchors
                } else {
                    print("[OriginTrace] ★ DIRECTION  anchor baseline too short in world space (\(String(format:"%.3f",dLen))m) — keeping dot→line")
                }
            } else {
                print("[OriginTrace] ★ DIRECTION  anchor baseline \(String(format:"%.2f",baseline))m < \(minBaselineMeters)m minimum — keeping dot→line")
            }
        } else {
            print("[BaselineDBG] only \(unique.count) unique point(s) — cannot form baseline")
        }

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

        // "TIP" badge at the Z-arrow tip of the red reference cross
        refTipBadgeText = "TIP"
        let tipLocal = SIMD4<Float>(0, 0.005, 0.25 + 0.04, 1) // yOffset + armLen + arrowHeight from makeReferenceCross
        let tipWorld4 = rotMatrix * tipLocal
        let tipWorld = SIMD3<Float>(tipWorld4.x, tipWorld4.y, tipWorld4.z) + dotWorld
        updateBadgeScreenPoint(world: tipWorld + SIMD3<Float>(0, 0.03, 0), setter: { refTipBadgeScreenPoint = $0 })

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
            mesh: .generateSphere(radius: 0.04),
            materials: [UnlitMaterial(color: color)]
        )
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchorState.wrappedValue = anchor
        print("[DebugDot] placed \(name) at \(position)")
    }

    /// Places or moves a small red cone at `position` to mark the detected laser dot's 3-D location.
    /// The cone is created on first call and then repositioned on every subsequent call.
    func placeDotCone(at position: SIMD3<Float>) {
        guard let arView else { return }
        guard !position.x.isNaN, !position.y.isNaN, !position.z.isNaN else {
            print("[DotCone] skipping NaN position")
            return
        }

        if let existing = dotConeAnchor {
            // Reuse the existing anchor — just move it.
            existing.transform.translation = position
        } else {
            // First call: create cone + anchor and add to scene.
            let coneHeight: Float = 0.025   // 2.5 cm tall
            let coneRadius: Float = 0.010   // 1.0 cm base radius
            let material = UnlitMaterial(color: UIColor(red: 1.0, green: 0.08, blue: 0.08, alpha: 1.0))
            let cone = ModelEntity(
                mesh: .generateCone(height: coneHeight, radius: coneRadius),
                materials: [material]
            )
            // Tip points up by default; rotate 180° so tip points down toward the surface.
            cone.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            // Offset so the tip sits exactly at the raycasted surface position.
            cone.position = SIMD3<Float>(0, coneHeight / 2, 0)

            let anchor = AnchorEntity(world: position)
            anchor.addChild(cone)
            arView.scene.addAnchor(anchor)
            dotConeAnchor = anchor
            print("[DotCone] placed at \(position)")
        }
    }

    /// Removes the dot-indicator cone from the scene.
    func removeDotCone() {
        guard let arView, let anchor = dotConeAnchor else {
            dotConeAnchor = nil
            return
        }
        arView.scene.removeAnchor(anchor)
        dotConeAnchor = nil
        print("[DotCone] removed")
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
