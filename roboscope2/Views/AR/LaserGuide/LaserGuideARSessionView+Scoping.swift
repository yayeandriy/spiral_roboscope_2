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

    func maybeAutoScope(_ measurement: LaserDotLineMeasurement?) {
        guard !hasAutoScoped else { return }

        // Reset stability when there is no measurement or the distance is out of tolerance.
        guard let measurement,
              let candidate = candidateSegment(for: measurement.distanceMeters),
              candidate.delta <= laserGuideDistanceToleranceMeters else {
            if originStabilityStartTime != 0 {
                originStabilityStartTime = 0
                originStabilityProgress = 0
            }
            return
        }

        let now = CACurrentMediaTime()

        // Start the stability clock on the first in-tolerance frame.
        if originStabilityStartTime == 0 {
            originStabilityStartTime = now
            print("[LaserGuideSnap] Stability clock started, candidate delta=\(String(format: "%.3f", candidate.delta))m")
        }

        let elapsed = now - originStabilityStartTime
        let required: TimeInterval = 1.0
        originStabilityProgress = min(1.0, elapsed / required)

        // Require 1 second of continuous stability before placing origin.
        guard elapsed >= required else { return }

        // Reset stability state before placing.
        originStabilityStartTime = 0
        originStabilityProgress = 0

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
        print("[LaserGuideSnap] snapFrameOriginToAlignDot called")
        print("[LaserGuideSnap]   dotWorld: \(dotWorld)")
        print("[LaserGuideSnap]   lineWorld: \(lineWorld)")
        print("[LaserGuideSnap]   segment: x=\(segment.x), z=\(segment.z)")

        // Compute direction first so we can orient the crosses
        let R = lineWorld - dotWorld
        let R_xz = SIMD2<Float>(R.x, R.z)
        var r = normalize(R_xz)

        if let cameraTransform = arView?.session.currentFrame?.camera.transform {
            let camForward = SIMD2<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.z)
            if dot(r, camForward) < 0 { r = -r }
        }

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

        // Compute origin position
        let S = SIMD2<Float>(Float(segment.x), Float(segment.z))
        let d = length(S)
        let offset_xz = r * d
        let O = SIMD3<Float>(dotWorld.x - offset_xz.x, dotWorld.y, dotWorld.z - offset_xz.y)

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
