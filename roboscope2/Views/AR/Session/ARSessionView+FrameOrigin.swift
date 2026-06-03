//
//  ARSessionView+FrameOrigin.swift
//  roboscope2
//
//  Frame Origin gizmo placement and updates
//

import SwiftUI
import RealityKit
import ARKit

extension ARSessionView {
    // MARK: - Frame Origin Gizmo
    func placeFrameOriginGizmo(at transform: simd_float4x4) {
        guard let arView = arView else { return }
        
        // Remove existing frame origin if any
        if let existingAnchor = frameOriginAnchor {
            arView.scene.removeAnchor(existingAnchor)
        }
        
        // Create anchor at the transformed origin
        let anchor = AnchorEntity(world: transform)
        
        // White axes — thin lines with dots at tips
        let axisLength: Float = 0.5     // 50cm axes
        let axisRadius: Float = 0.0015  // ~1.5mm thin
        let dotRadius: Float = 0.015    // small dots at axis tips
        let axisMaterial = UnlitMaterial(color: .white)
        
        // X-axis
        let xAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [axisMaterial]
        )
        xAxis.position = SIMD3<Float>(axisLength/2, 0, 0)
        xAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(0, 0, 1))
        
        // Y-axis
        let yAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [axisMaterial]
        )
        yAxis.position = SIMD3<Float>(0, axisLength/2, 0)
        
        // Z-axis
        let zAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [axisMaterial]
        )
        zAxis.position = SIMD3<Float>(0, 0, axisLength/2)
        zAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1, 0, 0))
        
        // Dots at axis tips
        let xTip = ModelEntity(mesh: .generateSphere(radius: dotRadius), materials: [axisMaterial])
        xTip.position = SIMD3<Float>(axisLength, 0, 0)
        
        let yTip = ModelEntity(mesh: .generateSphere(radius: dotRadius), materials: [axisMaterial])
        yTip.position = SIMD3<Float>(0, axisLength, 0)
        
        // Z-axis arrow only (no dot)
        let arrowHeight: Float = 0.05
        let arrowRadius: Float = 0.018
        let zArrow = ModelEntity(
            mesh: .generateCone(height: arrowHeight, radius: arrowRadius),
            materials: [axisMaterial]
        )
        zArrow.position = SIMD3<Float>(0, 0, axisLength + arrowHeight / 2)
        zArrow.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))

        // Center dot (slightly larger)
        let centerDot = ModelEntity(mesh: .generateSphere(radius: dotRadius * 1.4), materials: [axisMaterial])
        
        // Add all components to anchor
        anchor.addChild(xAxis)
        anchor.addChild(yAxis)
        anchor.addChild(zAxis)
        anchor.addChild(xTip)
        anchor.addChild(yTip)
        anchor.addChild(zArrow)
        anchor.addChild(centerDot)
        
        // Add to scene
        arView.scene.addAnchor(anchor)
        frameOriginAnchor = anchor
    }
    
    /// Drop FrameOrigin on the floor at screen center using raycast
    func dropFrameOriginOnFloor() {
        guard let arView = arView else { return }
        
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .horizontal) {
            let results = arView.session.raycast(query)
            if let firstResult = results.first {
                frameOriginTransform = firstResult.worldTransform
                placeFrameOriginGizmo(at: firstResult.worldTransform)
                updateMarkersForNewFrameOrigin()
                return
            }
        }
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .horizontal) {
            let results = arView.session.raycast(query)
            if let firstResult = results.first {
                frameOriginTransform = firstResult.worldTransform
                placeFrameOriginGizmo(at: firstResult.worldTransform)
                updateMarkersForNewFrameOrigin()
                return
            }
        }
    }

    /// Start auto-dropping the FrameOrigin with retries until a plane is found or attempts are exhausted
    func startAutoDropFrameOrigin(maxAttempts: Int = 15, interval: TimeInterval = 0.3) {
        // Prevent multiple timers
        autoDropTimer?.invalidate()
        autoDropAttempts = 0

        func attempt() {
            autoDropAttempts += 1
            let before = autoDropAttempts
            dropFrameOriginOnFloor()
            // Heuristic: if we have a non-identity transform on the gizmo anchor, consider it a success
            if let anchor = frameOriginAnchor {
                let t = anchor.transform.matrix
                let translation = t.columns.3
                let hasMoved = !(translation.x == 0 && translation.y == 0 && translation.z == 0)
                if hasMoved {
                    autoDropTimer?.invalidate()
                    autoDropTimer = nil
                    return
                }
            }
            if before >= maxAttempts {
                autoDropTimer?.invalidate()
                autoDropTimer = nil
                
            }
        }

        // First immediate attempt
        attempt()
        // Schedule subsequent attempts
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            attempt()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDropTimer = timer
    }

    /// Ensure the FrameOrigin gizmo is present; if it's been detached from the scene, re-add it
    func ensureFrameOriginGizmoPresent() {
        guard let arView, let anchor = frameOriginAnchor else { return }
        // Only re-add to the scene if it somehow got detached; do not change its transform
        if anchor.parent == nil {
            arView.scene.addAnchor(anchor)
        }
    }
    
    /// Update the FrameOrigin gizmo to match where the model is positioned
    /// Called automatically via frameOriginTransform didSet observer
    func updateFrameOriginGizmoPosition() {
        guard let anchor = frameOriginAnchor else { return }
        anchor.transform = Transform(matrix: frameOriginTransform)
        
    }
}

extension LaserGuideARSessionView {
    // MARK: - Frame Origin Gizmo
    func placeFrameOriginGizmo(at transform: simd_float4x4) {
        guard let arView = arView else { return }

        // Remove existing frame origin if any
        if let existingAnchor = frameOriginAnchor {
            arView.scene.removeAnchor(existingAnchor)
        }

        // Create anchor at world origin
        let anchor = AnchorEntity(world: .zero)
        // Hide the origin gizmo while in detection mode
        anchor.isEnabled = hasAutoScoped
        
        // Set the full transform (position + rotation)
        anchor.transform = Transform(matrix: transform)
        
        let pos = anchor.position(relativeTo: nil)
        print("[LaserGuideSnap] placeFrameOriginGizmo: worldPosition=\(pos)")

        // White axes — thin lines with dots at tips
        let axisLength: Float = 0.5     // 50cm axes
        let axisRadius: Float = 0.0015  // ~1.5mm thin
        let dotRadius: Float = 0.015    // small dots at axis tips
        let axisMaterial = UnlitMaterial(color: .white)

        // X-axis
        let xAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [axisMaterial]
        )
        xAxis.position = SIMD3<Float>(axisLength/2, 0, 0)
        xAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(0, 0, 1))

        // Y-axis
        let yAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [axisMaterial]
        )
        yAxis.position = SIMD3<Float>(0, axisLength/2, 0)

        // Z-axis
        let zAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [axisMaterial]
        )
        zAxis.position = SIMD3<Float>(0, 0, axisLength/2)
        zAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1, 0, 0))

        // Dots at X and Y tips; Z gets an arrow
        let xTip = ModelEntity(mesh: .generateSphere(radius: dotRadius), materials: [axisMaterial])
        xTip.position = SIMD3<Float>(axisLength, 0, 0)

        let yTip = ModelEntity(mesh: .generateSphere(radius: dotRadius), materials: [axisMaterial])
        yTip.position = SIMD3<Float>(0, axisLength, 0)

        // Z-axis arrow only (no dot)
        let arrowHeight: Float = 0.05
        let arrowRadius: Float = 0.018
        let zArrow = ModelEntity(
            mesh: .generateCone(height: arrowHeight, radius: arrowRadius),
            materials: [axisMaterial]
        )
        zArrow.position = SIMD3<Float>(0, 0, axisLength + arrowHeight / 2)
        zArrow.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))

        // Center dot (slightly larger)
        let centerDot = ModelEntity(mesh: .generateSphere(radius: dotRadius * 1.4), materials: [axisMaterial])

        // Add all components to anchor
        anchor.addChild(xAxis)
        anchor.addChild(yAxis)
        anchor.addChild(zAxis)
        anchor.addChild(xTip)
        anchor.addChild(yTip)
        anchor.addChild(zArrow)
        anchor.addChild(centerDot)

        // Add to scene
        arView.scene.addAnchor(anchor)
        frameOriginAnchor = anchor
    }

    /// Drop FrameOrigin on the floor at screen center using raycast
    func dropFrameOriginOnFloor() {
        guard let arView = arView else {
            return
        }

        // Raycast from screen center downward to find floor
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)

        // Try raycasting to existing horizontal planes (floor detection)
        if let query = arView.makeRaycastQuery(
            from: screenCenter,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        ) {
            let results = arView.session.raycast(query)

            if let firstResult = results.first {
                // Found a horizontal plane (floor)
                let hitTransform = firstResult.worldTransform

                // Update the frame origin transform
                frameOriginTransform = hitTransform

                // Update the visual gizmo
                placeFrameOriginGizmo(at: hitTransform)

                // Update all existing markers to new coordinate system
                updateMarkersForNewFrameOrigin()

                return
            }
        }

        // Fallback: raycast to estimated plane if no detected planes yet
        if let query = arView.makeRaycastQuery(
            from: screenCenter,
            allowing: .estimatedPlane,
            alignment: .horizontal
        ) {
            let results = arView.session.raycast(query)

            if let firstResult = results.first {
                let hitTransform = firstResult.worldTransform

                frameOriginTransform = hitTransform
                placeFrameOriginGizmo(at: hitTransform)
                updateMarkersForNewFrameOrigin()

                return
            }
        }
    }

    /// Start auto-dropping the FrameOrigin with retries until a plane is found or attempts are exhausted
    func startAutoDropFrameOrigin(maxAttempts: Int = 15, interval: TimeInterval = 0.3) {
        // Prevent multiple timers
        autoDropTimer?.invalidate()
        autoDropAttempts = 0

        func attempt() {
            autoDropAttempts += 1
            let before = autoDropAttempts
            dropFrameOriginOnFloor()
            // Heuristic: if we have a non-identity transform on the gizmo anchor, consider it a success
            if let anchor = frameOriginAnchor {
                let t = anchor.transform.matrix
                let translation = t.columns.3
                let hasMoved = !(translation.x == 0 && translation.y == 0 && translation.z == 0)
                if hasMoved {
                    autoDropTimer?.invalidate()
                    autoDropTimer = nil
                    return
                }
            }
            if before >= maxAttempts {
                autoDropTimer?.invalidate()
                autoDropTimer = nil
            }
        }

        // First immediate attempt
        attempt()
        // Schedule subsequent attempts
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            attempt()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDropTimer = timer
    }

    /// Ensure the FrameOrigin gizmo is present; if it's been detached from the scene, re-add it
    func ensureFrameOriginGizmoPresent() {
        guard let arView, let anchor = frameOriginAnchor else { return }
        // Only re-add to the scene if it somehow got detached; do not change its transform
        if anchor.parent == nil {
            arView.scene.addAnchor(anchor)
        }
    }

    /// Update the FrameOrigin gizmo to match where the model is positioned
    /// Called automatically via frameOriginTransform didSet observer
    func updateFrameOriginGizmoPosition() {
        guard let anchor = frameOriginAnchor else {
            print("[LaserGuideSnap] updateFrameOriginGizmoPosition: NO ANCHOR!")
            return
        }
        // Keep visibility in sync with mode
        anchor.isEnabled = hasAutoScoped
        let before = anchor.transform.matrix.columns.3
        anchor.transform = Transform(matrix: frameOriginTransform)
        let after = anchor.transform.matrix.columns.3
        print("[LaserGuideSnap] updateFrameOriginGizmoPosition:")
        print("[LaserGuideSnap]   BEFORE: \(before)")
        print("[LaserGuideSnap]   AFTER:  \(after)")
        print("[LaserGuideSnap]   anchor.isAnchored: \(anchor.isAnchored)")
        print("[LaserGuideSnap]   anchor.isEnabled: \(anchor.isEnabled)")
    }
}
