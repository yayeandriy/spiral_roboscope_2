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
            print("[LaserGuideSnap] autoRestartThreshold set to \(String(format: "%.2f", autoScopeRestartThresholdZMeters ?? 0))m (floor=\(String(format: "%.1f", settings.laserGuideMinAnchorAutoRestartDistanceMeters))m)")

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
                anchorBaselineLineAnchor?.isEnabled = true
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
        // --- Step 1: compute direction from dot → line.
        //     Used ONLY for the very first anchor of a run (no other anchors to
        //     compare against yet). All subsequent anchors derive their Z+
        //     direction from the anchor baseline below and IGNORE this value.
        let R = lineWorld - dotWorld
        let R_xz = SIMD2<Float>(R.x, R.z)
        let rawLen = simd_distance(dotWorld, lineWorld)
        var r = normalize(R_xz)
        print("[Snap] dot→line direction: d=(\(String(format:"%.3f",R.x)),\(String(format:"%.3f",R.z))) len=\(String(format:"%.3f",rawLen))m dir=(\(String(format:"%.3f",r.x)),\(String(format:"%.3f",r.y)))")

        // --- Step 2: for the 2nd+ anchor in a run, replace the dot→line
        //     direction with the anchor baseline.
        //
        //     Per spec:
        //       • 1st anchor  → oriented toward line detection (dot→line)
        //       • 2nd+ anchor → Z+ = direction from the anchor with the SMALLEST
        //                       local_z toward the anchor with the LARGEST
        //                       local_z (line detection is ignored entirely).
        //
        //     Each anchor's world_position is where the laser DOT was detected,
        //     i.e. the same coordinate that dotWorld carries for the current snap.
        //     The anchor baseline is far longer than dot→line, so it also has
        //     much smaller angular error.
        //
        //     Sources of known positions (union for this run):
        //       • runAnchors     — every successful snap in this run
        //       • current snap   — the point being placed right now
        // -----------------------------------------------------------------------

        // Collect known dot positions for the current run from the LOCAL in-memory
        // history (no API/AnchorService dependency). The dictionary is keyed by
        // local_z so each table row has at most one position.
        struct AnchorPoint { let localZ: Double; let world: SIMD3<Float>; let source: String }
        var points: [AnchorPoint] = []

        for (z, pos) in runAnchors {
            // The current snap will be merged in below — skip the same-z entry here.
            if z == segment.z { continue }
            points.append(AnchorPoint(
                localZ: z,
                world: pos,
                source: "history"
            ))
        }
        // Current snap (always wins for its own local_z because runAnchors hasn't
        // been updated yet — that happens in stopPlacement after we return).
        points.append(AnchorPoint(
            localZ: segment.z,
            world: dotWorld,
            source: "current"
        ))

        print("[Snap] run=\(currentRun) historyEntries=\(runAnchors.count) points=\(points.count)")
        for p in points.sorted(by: { $0.localZ < $1.localZ }) {
            print("[Snap]   [\(p.source)] localZ=\(String(format:"%.4f",p.localZ)) world=(\(String(format:"%.3f",p.world.x)),\(String(format:"%.3f",p.world.y)),\(String(format:"%.3f",p.world.z)))")
        }

        var dirMethod = "dot→line"
        if points.count >= 2 {
            let sorted = points.sorted { $0.localZ < $1.localZ }
            let A1 = sorted.first!   // smallest local_z
            let A2 = sorted.last!    // largest local_z
            let baseline = A2.localZ - A1.localZ

            let dXZ = SIMD2<Float>(A2.world.x - A1.world.x, A2.world.z - A1.world.z)
            let dLen = simd_length(dXZ)
            // Tiny epsilon avoids a divide-by-zero only; we do NOT fall back to
            // dot→line even for short baselines — the spec mandates anchor-only
            // direction for 2nd+ anchors.
            if dLen > 1e-4 {
                let r_anchors = dXZ / dLen
                let dotProd = simd_dot(r, r_anchors)
                let angleDeg = acos(max(-1, min(1, dotProd))) * (180.0 / Float.pi)
                print("[Snap] BASELINE  A1[\(A1.source)] z=\(String(format:"%.2f",A1.localZ)) world=(\(String(format:"%.3f",A1.world.x)),\(String(format:"%.3f",A1.world.y)),\(String(format:"%.3f",A1.world.z)))  →  A2[\(A2.source)] z=\(String(format:"%.2f",A2.localZ)) world=(\(String(format:"%.3f",A2.world.x)),\(String(format:"%.3f",A2.world.y)),\(String(format:"%.3f",A2.world.z)))  gap=\(String(format:"%.2f",baseline))m worldDist=\(String(format:"%.3f",dLen))m  dir=(\(String(format:"%.3f",r_anchors.x)),\(String(format:"%.3f",r_anchors.y)))  (dot→line was \(String(format:"%.0f",angleDeg))° off, ignored)")
                r = r_anchors
                dirMethod = "anchor-baseline"
            } else {
                print("[Snap] BASELINE  world dist \(String(format:"%.5f",dLen))m below epsilon — anchors coincide in XZ; keeping dot→line as a safety")
            }

            // Debug: draw a green line in WORLD between A1 and A2 so we can
            // visually verify the anchor baseline. Uses raw world coordinates
            // only — independent of any frame origin rotation.
            placeAnchorBaselineLine(from: A1.world, to: A2.world)
        } else {
            print("[Snap] BASELINE  only 1 point in run — using dot→line (first anchor case)")
            removeAnchorBaselineLine()
        }

        let S = SIMD2<Float>(Float(segment.x), Float(segment.z))
        let segLen = simd_length(S)
        let offset_xz = r * segLen
        let O = SIMD3<Float>(dotWorld.x - offset_xz.x, dotWorld.y, dotWorld.z - offset_xz.y)
        print("[Snap] RESULT  method=\(dirMethod)  segZ=\(String(format:"%.2f",segment.z))m  dotWorld=(\(String(format:"%.3f",dotWorld.x)),\(String(format:"%.3f",dotWorld.y)),\(String(format:"%.3f",dotWorld.z)))  frameZ+=(\(String(format:"%.3f",r.x)),0,\(String(format:"%.3f",r.y)))  origin=(\(String(format:"%.3f",O.x)),\(String(format:"%.3f",O.y)),\(String(format:"%.3f",O.z)))")

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

        // Capture the old transform BEFORE overwriting it — needed to rebase
        // existing markers from the old coordinate system to the new one.
        let oldTransform = frameOriginTransform
        let isFirstAnchor = runAnchors.isEmpty

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

        if isFirstAnchor {
            // First anchor: re-render ARKit markers using the new (first) origin.
            // Markers from a previous session are stored relative to whatever
            // frame was active then — this corrects them to the new frame.
            updateMarkersForNewFrameOrigin()
            print("[LaserGuideSnap]   snap complete (markers: ARKit re-rendered, first anchor)")
        } else {
            // 2nd+ anchor: the frame origin has been refined.
            // Re-express every existing marker's stored local coords in the new
            // (more accurate) coordinate system so that all markers in the
            // session use a consistent frame, regardless of which anchor level
            // was active when each was placed.
            // Formula: newLocal = newTransform.inverse × (oldTransform × oldLocal)
            rebaseMarkersToCurrentFrame(oldTransform: oldTransform, newTransform: newTransform)
            print("[LaserGuideSnap]   snap complete (markers: rebasing to new frame, subsequent anchor)")
        }
    }

    /// Re-expresses all persisted markers' local coordinates from `oldTransform`
    /// into `newTransform`, then patches them in the backend.
    ///
    /// Each marker's local coords (p1–p4) were stored as:
    ///   localOld = oldTransform.inverse × worldPos
    ///
    /// We want them expressed in the new frame:
    ///   localNew = newTransform.inverse × worldPos
    ///           = newTransform.inverse × (oldTransform × localOld)
    ///
    /// This keeps a single consistent coordinate system across all anchor levels
    /// so the portal renders all markers in the same space.
    func rebaseMarkersToCurrentFrame(oldTransform: simd_float4x4, newTransform: simd_float4x4) {
        Task {
            do {
                let persisted = try await markerApi.getMarkersForSession(session.id)
                guard !persisted.isEmpty else {
                    print("[Rebase] no existing markers to rebase")
                    return
                }

                let newInv = newTransform.inverse

                for marker in persisted {
                    guard marker.points.count == 4 else { continue }

                    let newPoints: [SIMD3<Float>] = marker.points.map { oldLocal in
                        // old local → world → new local
                        let worldH = oldTransform * SIMD4<Float>(oldLocal.x, oldLocal.y, oldLocal.z, 1)
                        let newH   = newInv * worldH
                        // Preserve the canonical table-position Z exactly.
                        // Z is the physical position along the laser guide (e.g. 1.5m) and
                        // must stay stable across anchor refinements so the portal displays
                        // the marker at the correct guide position.  X and Y are updated
                        // because the lateral offset and height adjust as the frame is
                        // refined (the X-axis rotates slightly with each direction update,
                        // and the origin Y shifts with the current dot's height).
                        return SIMD3<Float>(newH.x, newH.y, oldLocal.z)
                    }

                    let update = UpdateMarker(
                        points: newPoints,
                        version: marker.version
                    )

                    do {
                        _ = try await markerApi.updateMarker(id: marker.id, update: update)
                        print("[Rebase] marker \(marker.id) rebased successfully")
                    } catch {
                        print("[Rebase] marker \(marker.id) rebase failed: \(error)")
                    }
                }

                // After rebasing backend coords, refresh ARKit visuals so they match.
                await MainActor.run {
                    updateMarkersForNewFrameOrigin()
                }
            } catch {
                print("[Rebase] failed to fetch markers: \(error)")
            }
        }
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

    /// Draws (or replaces) a green line in WORLD between two anchor positions.
    /// Used purely as a debug visual to confirm the anchor baseline used for the
    /// frame origin Z+ direction — independent of any frame origin orientation.
    func placeAnchorBaselineLine(from: SIMD3<Float>, to: SIMD3<Float>) {
        guard let arView else { return }
        guard !from.x.isNaN, !from.y.isNaN, !from.z.isNaN,
              !to.x.isNaN, !to.y.isNaN, !to.z.isNaN else { return }

        if let existing = anchorBaselineLineAnchor {
            arView.scene.removeAnchor(existing)
            anchorBaselineLineAnchor = nil
        }

        let dir = to - from
        let len = simd_length(dir)
        guard len > 0.0001 else { return }

        let green = UIColor(red: 0.0, green: 1.0, blue: 0.2, alpha: 1.0)

        // Thicker than the existing yellow measurement line so it stands out.
        let line = ModelEntity(
            mesh: .generateCylinder(height: len, radius: 0.003),
            materials: [UnlitMaterial(color: green)]
        )
        let mid = (from + to) / 2
        line.position = mid
        let up = normalize(dir)
        let yAxis = SIMD3<Float>(0, 1, 0)
        let crossVal = cross(yAxis, up)
        if simd_length(crossVal) > 0.0001 {
            let axis = normalize(crossVal)
            let angle = acos(max(-1, min(1, dot(yAxis, up))))
            line.orientation = simd_quatf(angle: angle, axis: axis)
        }
        line.name = "anchor_baseline_line"

        // Small spheres at both endpoints so we can see the exact anchor
        // positions the algorithm is using.
        let endpointMat = UnlitMaterial(color: green)
        let sphereFrom = ModelEntity(
            mesh: .generateSphere(radius: 0.012),
            materials: [endpointMat]
        )
        sphereFrom.position = from
        let sphereTo = ModelEntity(
            mesh: .generateSphere(radius: 0.012),
            materials: [endpointMat]
        )
        sphereTo.position = to

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(line)
        anchor.addChild(sphereFrom)
        anchor.addChild(sphereTo)
        arView.scene.addAnchor(anchor)
        anchorBaselineLineAnchor = anchor

        print("[Snap] BASELINE LINE drawn  from=(\(String(format:"%.3f",from.x)),\(String(format:"%.3f",from.y)),\(String(format:"%.3f",from.z)))  to=(\(String(format:"%.3f",to.x)),\(String(format:"%.3f",to.y)),\(String(format:"%.3f",to.z)))  len=\(String(format:"%.3f",len))m")
    }

    /// Removes the green anchor-baseline debug line from the scene.
    func removeAnchorBaselineLine() {
        guard let arView, let anchor = anchorBaselineLineAnchor else {
            anchorBaselineLineAnchor = nil
            return
        }
        arView.scene.removeAnchor(anchor)
        anchorBaselineLineAnchor = nil
    }

    /// Renders a blue sphere at every world position in `runAnchors` whose
    /// local_z is NOT in `excluding`. The excluded local_z is typically the
    /// current snap (which is shown by `debugLineAnchor` / dot cone) — this
    /// keeps the visual distinction "yellow = current, blue = history".
    func refreshHistoryAnchorDots(excluding: Set<Double> = []) {
        guard let arView else { return }

        if let existing = historyAnchorDotsAnchor {
            arView.scene.removeAnchor(existing)
            historyAnchorDotsAnchor = nil
        }

        let entries = runAnchors.filter { !excluding.contains($0.key) }
        guard !entries.isEmpty else { return }

        let anchor = AnchorEntity(world: .zero)
        let blueMat = UnlitMaterial(color: UIColor(red: 0.2, green: 0.55, blue: 1.0, alpha: 1.0))

        for (z, pos) in entries {
            guard !pos.x.isNaN, !pos.y.isNaN, !pos.z.isNaN else { continue }
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.018),
                materials: [blueMat]
            )
            sphere.position = pos
            sphere.name = "anchor_history_z=\(z)"
            anchor.addChild(sphere)
        }

        arView.scene.addAnchor(anchor)
        historyAnchorDotsAnchor = anchor

        print("[Snap] HISTORY DOTS rendered for \(entries.count) anchor(s):")
        for (z, pos) in entries.sorted(by: { $0.key < $1.key }) {
            print("[Snap]   z=\(String(format:"%.2f",z))m  world=(\(String(format:"%.3f",pos.x)),\(String(format:"%.3f",pos.y)),\(String(format:"%.3f",pos.z)))")
        }
    }

    /// Removes the persistent blue dots for history anchors.
    func removeHistoryAnchorDots() {
        guard let arView, let anchor = historyAnchorDotsAnchor else {
            historyAnchorDotsAnchor = nil
            return
        }
        arView.scene.removeAnchor(anchor)
        historyAnchorDotsAnchor = nil
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
