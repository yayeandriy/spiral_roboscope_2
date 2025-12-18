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
        
        // Create coordinate axes (RealityKit version)
        let axisLength: Float = 0.5  // 50cm axes
        let axisRadius: Float = 0.01  // 1cm thick
        
        // X-axis (Red)
        let xAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        xAxis.position = SIMD3<Float>(axisLength/2, 0, 0)
        xAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(0, 0, 1))
        
        // Y-axis (Green)
        let yAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        yAxis.position = SIMD3<Float>(0, axisLength/2, 0)
        
        // Z-axis (Blue)
        let zAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .blue, isMetallic: false)]
        )
        zAxis.position = SIMD3<Float>(0, 0, axisLength/2)
        zAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1, 0, 0))
        
        // Add axis labels with spheres at the tips
        let sphereRadius: Float = 0.03
        
        let xTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        xTip.position = SIMD3<Float>(axisLength, 0, 0)
        
        let yTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        yTip.position = SIMD3<Float>(0, axisLength, 0)
        
        let zTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .blue, isMetallic: false)]
        )
        zTip.position = SIMD3<Float>(0, 0, axisLength)
        
        // Center sphere (white/yellow to mark origin)
        let centerSphere = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius * 1.5),
            materials: [SimpleMaterial(color: .yellow, isMetallic: false)]
        )
        
        // Add all components to anchor
        anchor.addChild(xAxis)
        anchor.addChild(yAxis)
        anchor.addChild(zAxis)
        anchor.addChild(xTip)
        anchor.addChild(yTip)
        anchor.addChild(zTip)
        anchor.addChild(centerSphere)
        
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
                
                // NOTE: Reference model anchor is automatically updated via frameOriginTransform didSet
                
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
                
                // NOTE: Reference model anchor is automatically updated via frameOriginTransform didSet
                
                return
            }
        }
        
        // No floor found
        
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

        // Create anchor at the transformed origin
        let anchor = AnchorEntity(world: transform)

        // Create coordinate axes (RealityKit version)
        let axisLength: Float = 0.5  // 50cm axes
        let axisRadius: Float = 0.01  // 1cm thick

        // X-axis (Red)
        let xAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        xAxis.position = SIMD3<Float>(axisLength/2, 0, 0)
        xAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(0, 0, 1))

        // Y-axis (Green)
        let yAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        yAxis.position = SIMD3<Float>(0, axisLength/2, 0)

        // Z-axis (Blue)
        let zAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .blue, isMetallic: false)]
        )
        zAxis.position = SIMD3<Float>(0, 0, axisLength/2)
        zAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1, 0, 0))

        // Add axis labels with spheres at the tips
        let sphereRadius: Float = 0.03

        let xTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        xTip.position = SIMD3<Float>(axisLength, 0, 0)

        let yTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        yTip.position = SIMD3<Float>(0, axisLength, 0)

        let zTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .blue, isMetallic: false)]
        )
        zTip.position = SIMD3<Float>(0, 0, axisLength)

        // Center sphere (white/yellow to mark origin)
        let centerSphere = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius * 1.5),
            materials: [SimpleMaterial(color: .yellow, isMetallic: false)]
        )

        // Add all components to anchor
        anchor.addChild(xAxis)
        anchor.addChild(yAxis)
        anchor.addChild(zAxis)
        anchor.addChild(xTip)
        anchor.addChild(yTip)
        anchor.addChild(zTip)
        anchor.addChild(centerSphere)

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
        guard let anchor = frameOriginAnchor else { return }
        anchor.transform = Transform(matrix: frameOriginTransform)
    }
}
