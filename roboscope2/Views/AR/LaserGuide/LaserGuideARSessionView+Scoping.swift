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

extension LaserGuideARSessionView {

    func maybeAutoScope(_ measurement: LaserDotLineMeasurement?) {
        guard !hasAutoScoped else { return }
        guard let measurement else { return }

        // Match measurement against any known segment; snap immediately if within tolerance.
        guard let candidate = candidateSegment(for: measurement.distanceMeters),
              candidate.delta <= laserGuideDistanceToleranceMeters else { return }

        let now = CACurrentMediaTime()
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

            // After auto-scope, show origin gizmo again.
            frameOriginAnchor?.isEnabled = true

            // After auto-scope, show debug spheres again.
            debugDotAnchor?.isEnabled = true
            debugLineAnchor?.isEnabled = true

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

    func snapFrameOriginToAlignDot(dotWorld: SIMD3<Float>, lineWorld: SIMD3<Float>, segment: LaserGuideGridSegment) {
        print("[LaserGuideSnap] snapFrameOriginToAlignDot called")
        print("[LaserGuideSnap]   dotWorld: \(dotWorld)")
        print("[LaserGuideSnap]   lineWorld: \(lineWorld)")
        print("[LaserGuideSnap]   segment: x=\(segment.x), z=\(segment.z)")

        // Place debug spheres at raycast hit positions
        placeDebugSphere(at: dotWorld, color: .red, anchorState: $debugDotAnchor)
        placeDebugSphere(at: lineWorld, color: .green, anchorState: $debugLineAnchor)

        // 1. Direction vector R = N - D (from dot to line)
        let R = lineWorld - dotWorld
        let R_xz = SIMD2<Float>(R.x, R.z)
        var r = normalize(R_xz)  // normalized direction in XZ plane

        print("[LaserGuideSnap]   R (dot→line): \(R)")
        print("[LaserGuideSnap]   r (normalized XZ): \(r)")

        // Ensure the frame's +Z points AWAY from the camera (into the scene).
        // In ARKit the camera looks down its local -Z, so the "forward" direction in world
        // space is -(camera.transform.columns.2).xyz.
        if let cameraTransform = arView?.session.currentFrame?.camera.transform {
            let camForward = SIMD2<Float>(-cameraTransform.columns.2.x, -cameraTransform.columns.2.z)
            if dot(r, camForward) < 0 {
                // r is pointing toward the camera — flip it so +Z goes into the scene.
                r = -r
                print("[LaserGuideSnap]   r flipped to agree with camera forward")
            }
        }

        // 2. Distance d = |S| = magnitude of segment position
        let S = SIMD2<Float>(Float(segment.x), Float(segment.z))
        let d = length(S)

        print("[LaserGuideSnap]   S (segment XZ): \(S)")
        print("[LaserGuideSnap]   d (|S|): \(d)")

        // 3. Origin position: O = D - r*d (origin is behind the dot, so dot is at +Z in local)
        let offset_xz = r * d
        let O = SIMD3<Float>(dotWorld.x - offset_xz.x, dotWorld.y, dotWorld.z - offset_xz.y)

        print("[LaserGuideSnap]   offset (r*d): \(offset_xz)")
        print("[LaserGuideSnap]   O (origin pos): \(O)")

        // 4. Rotation: Z-axis aligned with R (dot→line direction)
        let newZ = SIMD3<Float>(r.x, 0, r.y)  // direction from dot to line
        let newX = SIMD3<Float>(r.y, 0, -r.x)  // perpendicular in XZ plane
        let newY = SIMD3<Float>(0, 1, 0)  // Y is up

        print("[LaserGuideSnap]   rotation: X=\(newX), Y=\(newY), Z=\(newZ)")

        // 5. Build transform
        var newTransform = matrix_identity_float4x4
        newTransform.columns.0 = SIMD4<Float>(newX.x, newX.y, newX.z, 0)
        newTransform.columns.1 = SIMD4<Float>(newY.x, newY.y, newY.z, 0)
        newTransform.columns.2 = SIMD4<Float>(newZ.x, newZ.y, newZ.z, 0)
        newTransform.columns.3 = SIMD4<Float>(O.x, O.y, O.z, 1)

        // Apply
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

    func placeDebugSphere(at position: SIMD3<Float>, color: UIColor, anchorState: Binding<AnchorEntity?>) {
        // These spheres are only useful for debugging the snap; hide them during detection mode.
        guard let arView = arView else { return }

        // Remove existing debug sphere
        if let existing = anchorState.wrappedValue {
            arView.scene.removeAnchor(existing)
        }

        // Create new sphere at position
        let anchor = AnchorEntity(world: position)
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.03),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchorState.wrappedValue = anchor

        // Only show debug spheres once we have auto-scoped.
        anchor.isEnabled = hasAutoScoped

        print("[LaserGuideSnap] Debug sphere (\(color == .red ? "RED/dot" : "GREEN/line")) placed at \(position)")
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
