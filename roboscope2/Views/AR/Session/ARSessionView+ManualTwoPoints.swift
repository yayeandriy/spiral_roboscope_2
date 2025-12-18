//
//  ARSessionView+ManualTwoPoints.swift
//  roboscope2
//
//  Manual two-point origin placement and movement helpers
//

import SwiftUI
import RealityKit
import ARKit

extension ARSessionView {
    // MARK: - Manual Two-Point Placement
    func enterManualTwoPointsMode() {
        // Clean any existing helper anchors from prior runs
        removeManualAnchors()

        // If we have preserved points from an earlier two-point setup, restore them
        if let p1 = preservedFirstPoint, let p2 = preservedSecondPoint {
            // Restore positions into current editing state
            manualFirstPoint = p1
            manualSecondPoint = p2
            manualFirstPreferredAlignment = preservedFirstPreferredAlignment ?? .horizontal
            manualSecondPreferredAlignment = preservedSecondPreferredAlignment ?? .horizontal

            // Recreate spheres at preserved positions for editing
            placeManualPoint(p1, color: .red, isFirst: true)
            placeManualPoint(p2, color: .blue, isFirst: false)
            manualPlacementState = .readyToApply
        } else {
            // No preserved points: start fresh placement flow
            manualFirstPoint = nil
            manualSecondPoint = nil
            manualFirstPreferredAlignment = nil
            manualSecondPreferredAlignment = nil
            manualPlacementState = .placeFirst
        }
        // Hide markers and gizmo
        markerService.setMarkersVisible(false)
        frameOriginAnchor?.isEnabled = false
        selectedManualPointIndex = nil
        
    }

    func cancelManualTwoPointsMode() {
        manualPlacementState = .inactive
        // Remove helper anchors
        removeManualAnchors()
        // Show markers and gizmo again
        markerService.setMarkersVisible(true)
        frameOriginAnchor?.isEnabled = true
        selectedManualPointIndex = nil
        endManualPointMove()
        
    }

    func manualPlacementButtonTitle() -> String {
        switch manualPlacementState {
        case .placeFirst: return "Place First Point"
        case .placeSecond: return "Place Second Point"
        case .readyToApply: return "Apply"
        case .inactive: return ""
        }
    }

    func manualPlacementPrimaryAction() {
        switch manualPlacementState {
        case .placeFirst:
            if let (p, align) = prioritizedRaycastFromCenter() {
                placeManualPoint(p, color: .red, isFirst: true)
                manualFirstPoint = p
                manualFirstPreferredAlignment = align
                manualPlacementState = .placeSecond
                
            }
        case .placeSecond:
            if let (p, align) = prioritizedRaycastFromCenter() {
                placeManualPoint(p, color: .blue, isFirst: false)
                manualSecondPoint = p
                manualSecondPreferredAlignment = align
                manualPlacementState = .readyToApply
                
            }
        case .readyToApply:
            applyManualTwoPointOrigin()
        case .inactive:
            break
        }
    }

    func raycastFromScreenCenter() -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Prefer existing planes; fall back to estimated
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        
        return nil
    }

    /// Raycast helper with explicit alignment preference. Used by placement and as a fallback.
    func raycastFromScreenCenter(preferredAlignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Prefer existing plane geometry for stability
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Then fall back to estimated plane with the same alignment
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Last resort: existing any, then estimated any
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        
        return nil
    }

    /// Movement-focused raycast: prefer existing plane geometry only; skip if no stable surface under crosshair.
    func raycastFromCenterForMove(preferredAlignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Optional: if needed, allow any alignment on existing planes
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // As a fallback, allow estimated plane with preferred alignment (comment out if too jittery)
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        
        return nil
    }

    // Try horizontal first (floors/tables), then vertical (walls), then any. Returns position and chosen alignment.
    func prioritizedRaycastFromCenter() -> (SIMD3<Float>, ARRaycastQuery.TargetAlignment)? {
        if let p = raycastFromScreenCenter(preferredAlignment: .horizontal) { return (p, .horizontal) }
        if let p = raycastFromScreenCenter(preferredAlignment: .vertical) { return (p, .vertical) }
        if let p = raycastFromScreenCenter() { return (p, .any) }
        return nil
    }

    func placeManualPoint(_ position: SIMD3<Float>, color: UIColor, isFirst: Bool) {
        guard let arView = arView else { return }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        let anchor = AnchorEntity(world: t)
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [SimpleMaterial(color: color, isMetallic: false)])
        sphere.name = isFirst ? "manual_point_1" : "manual_point_2"
        // Enable hit-testing against the sphere to improve selection robustness
        sphere.generateCollisionShapes(recursive: true)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        if isFirst { manualFirstAnchor = anchor } else { manualSecondAnchor = anchor }
    }

    func removeManualAnchors() {
        if let a = manualFirstAnchor { arView?.scene.removeAnchor(a) }
        if let a = manualSecondAnchor { arView?.scene.removeAnchor(a) }
        manualFirstAnchor = nil
        manualSecondAnchor = nil
    }

    func applyManualTwoPointOrigin() {
        guard let p1 = manualFirstPoint, let p2 = manualSecondPoint else { return }
        // Compute yaw so +Z points toward p2 on XZ plane
        let dir = SIMD3<Float>(p2.x - p1.x, 0, p2.z - p1.z)
        var forward = dir
        let len = simd_length(forward)
        if len >= 1e-4 {
            forward /= len
        } else {
            forward = SIMD3<Float>(0, 0, 1)
        }
        let yaw = atan2(forward.x, forward.z)
        let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        var transform = float4x4(rotation)
        transform.columns.3 = SIMD4<Float>(p1.x, p1.y, p1.z, 1)
        
        
        // Apply new FrameOrigin
        frameOriginTransform = transform
        placeFrameOriginGizmo(at: transform)
        updateMarkersForNewFrameOrigin()
        
        // Exit manual mode and restore UI
        cancelManualTwoPointsMode()

        // Persist the two points and their alignments for future edits
        preservedFirstPoint = p1
        preservedSecondPoint = p2
        preservedFirstPreferredAlignment = manualFirstPreferredAlignment
        preservedSecondPreferredAlignment = manualSecondPreferredAlignment
        
    }

    /// Clear both points and restart Two Point placement from the first point
    func clearTwoPointPlacement() {
        // Stop any movement
        endManualPointMove()
        selectedManualPointIndex = nil
        // Remove helper anchors (and spheres)
        removeManualAnchors()
        // Reset current and preserved state so re-entry starts fresh
        manualFirstPoint = nil
        manualSecondPoint = nil
        manualFirstPreferredAlignment = nil
        manualSecondPreferredAlignment = nil
        preservedFirstPoint = nil
        preservedSecondPoint = nil
        preservedFirstPreferredAlignment = nil
        preservedSecondPreferredAlignment = nil
        // Go back to placing the first point
        manualPlacementState = .placeFirst
        
    }

    // MARK: - Manual point selection + moving
    func updateManualPointSelection() {
        guard manualPlacementState != .inactive, let arView = arView, let frame = arView.session.currentFrame else { return }
        // First, try a precise hit-test at the screen center against our manual spheres
        if let hitIdx = manualPointIndexHitAtCenter(arView: arView) {
            if hitIdx != selectedManualPointIndex {
                selectedManualPointIndex = hitIdx
                updateManualPointColors()
            }
            return
        }
        // Fallback: Determine which point (if any) is under crosshair by projecting to screen
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let threshold: CGFloat = 36
        var nearestIndex: Int? = nil
        var nearestDist: CGFloat = .infinity
        if let a1 = manualFirstAnchor {
            let wp = a1.position(relativeTo: nil)
            if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                let d = hypot(sp.x - center.x, sp.y - center.y)
                if d < threshold && d < nearestDist { nearestDist = d; nearestIndex = 1 }
            }
        }
        if let a2 = manualSecondAnchor {
            let wp = a2.position(relativeTo: nil)
            if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                let d = hypot(sp.x - center.x, sp.y - center.y)
                if d < threshold && d < nearestDist { nearestDist = d; nearestIndex = 2 }
            }
        }
        if nearestIndex != selectedManualPointIndex {
            selectedManualPointIndex = nearestIndex
            updateManualPointColors()
        }
    }

    func manualPointIndexHitAtCenter(arView: ARView) -> Int? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // entity(at:) returns the topmost entity with collisions at that screen point
        if let entity = arView.entity(at: center) {
            if entity.name == "manual_point_1" { return 1 }
            if entity.name == "manual_point_2" { return 2 }
            // In case the returned entity is not the sphere but a child/parent, walk up one level
            if let parent = entity.parent {
                if parent.name == "manual_point_1" { return 1 }
                if parent.name == "manual_point_2" { return 2 }
            }
        }
        return nil
    }

    func updateManualPointColors() {
        func setColor(anchor: AnchorEntity?, normalColor: UIColor, selected: Bool) {
            guard let anchor = anchor else { return }
            if let sphere = anchor.children.first(where: { $0.name.hasPrefix("manual_point_") }) as? ModelEntity {
                let color = selected ? UIColor.black : normalColor
                sphere.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
            }
        }
        setColor(anchor: manualFirstAnchor, normalColor: .red, selected: selectedManualPointIndex == 1)
        setColor(anchor: manualSecondAnchor, normalColor: .blue, selected: selectedManualPointIndex == 2)
    }

    func startManualPointMove() {
        guard manualPointMoveTimer == nil else { return }
        // Capture FIXED screen point of the selected SPHERE (child), not the anchor
        // Anchor may still hold the original placement; the sphere is what we actually move
        if let arView, let frame = arView.session.currentFrame, let idx = selectedManualPointIndex {
            let anchor = (idx == 1) ? manualFirstAnchor : manualSecondAnchor
            let sphereName = (idx == 1) ? "manual_point_1" : "manual_point_2"
            if let a = anchor,
               let sphere = a.children.first(where: { $0.name == sphereName }) {
                let wp = sphere.position(relativeTo: nil)
                if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                    fixedManualMoveScreenPoint = sp
                } else {
                    // Fallback to screen center
                    fixedManualMoveScreenPoint = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
                }
            }
        }

        // Run at ~60 Hz for smooth movement
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            if fixedManualMoveScreenPoint != nil {
                moveSelectedPointUsingFixedScreenPoint()
            } else {
                moveSelectedPointToCrossRaycast()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    manualPointMoveTimer = timer
    }

    func endManualPointMove() {
        manualPointMoveTimer?.invalidate()
        manualPointMoveTimer = nil
    fixedManualMoveScreenPoint = nil
    }

    func moveSelectedPointToCrossRaycast() {
        guard let idx = selectedManualPointIndex else { return }
        // Use per-point alignment chosen at placement; fallback to horizontal, then any.
        let preferred: ARRaycastQuery.TargetAlignment = {
            if idx == 1, let a = manualFirstPreferredAlignment { return a }
            if idx == 2, let a = manualSecondPreferredAlignment { return a }
            return .horizontal
        }()
        let newPos = raycastFromCenterForMove(preferredAlignment: preferred)
        guard let newPos else { return }
        // Optional: reject large jumps between discrete ticks
        if let old = (idx == 1 ? manualFirstPoint : manualSecondPoint) {
            let jump = simd_length(newPos - old)
            if jump > 0.5 { return }
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
        if idx == 1 {
            manualFirstPoint = newPos
            if let a = manualFirstAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                // Set the sphere's world transform (avoid anchor composition)
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        } else if idx == 2 {
            
            manualSecondPoint = newPos
            if let a = manualSecondAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                // Set the sphere's world transform (avoid anchor composition)
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        }
    }

    /// Move currently selected point using a FIXED screen point captured at movement start
    func moveSelectedPointUsingFixedScreenPoint() {
        guard let arView, let idx = selectedManualPointIndex, let screenPoint = fixedManualMoveScreenPoint else { return }

        // Use per-point alignment chosen at placement; fallback to horizontal, then any.
        let preferred: ARRaycastQuery.TargetAlignment = {
            if idx == 1, let a = manualFirstPreferredAlignment { return a }
            if idx == 2, let a = manualSecondPreferredAlignment { return a }
            return .horizontal
        }()

        // Try existing plane with preferred alignment first
        func raycast(at p: CGPoint, allowing: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
            guard let q = arView.makeRaycastQuery(from: p, allowing: allowing, alignment: alignment) else { return nil }
            let results = arView.session.raycast(q)
            guard let first = results.first else { return nil }
            let t = first.worldTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }

        let newPos =
            raycast(at: screenPoint, allowing: .existingPlaneGeometry, alignment: preferred) ??
            raycast(at: screenPoint, allowing: .existingPlaneGeometry, alignment: .any) ??
            raycast(at: screenPoint, allowing: .estimatedPlane, alignment: preferred) ??
            raycast(at: screenPoint, allowing: .estimatedPlane, alignment: .any)

        guard let newPos else { return }

        // Optional: reject large jumps
        if let old = (idx == 1 ? manualFirstPoint : manualSecondPoint) {
            let jump = simd_length(newPos - old)
            if jump > 0.5 { return }
        }

        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
        if idx == 1 {
            manualFirstPoint = newPos
            // Move the sphere child in world space (avoid anchor composition)
            if let a = manualFirstAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        } else {
            manualSecondPoint = newPos
            // Move the sphere child in world space (avoid anchor composition)
            if let a = manualSecondAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        }
    }

    func projectWorldToScreen(worldPosition: SIMD3<Float>, frame: ARFrame, arView: ARView) -> CGPoint? {
        let camera = frame.camera
        // Use the current interface orientation instead of hard-coding portrait
        let orientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projectionMatrix = camera.projectionMatrix(for: orientation, viewportSize: arView.bounds.size, zNear: 0.001, zFar: 1000)
        let worldPos4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        let viewPos = viewMatrix * worldPos4
        // Discard points behind the camera
        if viewPos.z > 0 { return nil }
        let projPos = projectionMatrix * viewPos
        guard projPos.w != 0 else { return nil }
        let ndcX = projPos.x / projPos.w
        let ndcY = projPos.y / projPos.w
        let screenX = (ndcX + 1.0) * 0.5 * Float(arView.bounds.width)
        let screenY = (1.0 - ndcY) * 0.5 * Float(arView.bounds.height)
        return CGPoint(x: CGFloat(screenX), y: CGFloat(screenY))
    }
}

extension LaserGuideARSessionView {
    // MARK: - Manual Two-Point Placement
    func enterManualTwoPointsMode() {
        // Clean any existing helper anchors from prior runs
        removeManualAnchors()

        // If we have preserved points from an earlier two-point setup, restore them
        if let p1 = preservedFirstPoint, let p2 = preservedSecondPoint {
            // Restore positions into current editing state
            manualFirstPoint = p1
            manualSecondPoint = p2
            manualFirstPreferredAlignment = preservedFirstPreferredAlignment ?? .horizontal
            manualSecondPreferredAlignment = preservedSecondPreferredAlignment ?? .horizontal

            // Recreate spheres at preserved positions for editing
            placeManualPoint(p1, color: .red, isFirst: true)
            placeManualPoint(p2, color: .blue, isFirst: false)
            manualPlacementState = .readyToApply
        } else {
            // No preserved points: start fresh placement flow
            manualFirstPoint = nil
            manualSecondPoint = nil
            manualFirstPreferredAlignment = nil
            manualSecondPreferredAlignment = nil
            manualPlacementState = .placeFirst
        }
        // Hide markers and gizmo
        markerService.setMarkersVisible(false)
        frameOriginAnchor?.isEnabled = false
        selectedManualPointIndex = nil
    }

    func cancelManualTwoPointsMode() {
        manualPlacementState = .inactive
        // Remove helper anchors
        removeManualAnchors()
        // Show markers and gizmo again
        markerService.setMarkersVisible(true)
        frameOriginAnchor?.isEnabled = true
        selectedManualPointIndex = nil
        endManualPointMove()
    }

    func manualPlacementButtonTitle() -> String {
        switch manualPlacementState {
        case .placeFirst: return "Place First Point"
        case .placeSecond: return "Place Second Point"
        case .readyToApply: return "Apply"
        case .inactive: return ""
        }
    }

    func manualPlacementPrimaryAction() {
        switch manualPlacementState {
        case .placeFirst:
            if let (p, align) = prioritizedRaycastFromCenter() {
                placeManualPoint(p, color: .red, isFirst: true)
                manualFirstPoint = p
                manualFirstPreferredAlignment = align
                manualPlacementState = .placeSecond
            }
        case .placeSecond:
            if let (p, align) = prioritizedRaycastFromCenter() {
                placeManualPoint(p, color: .blue, isFirst: false)
                manualSecondPoint = p
                manualSecondPreferredAlignment = align
                manualPlacementState = .readyToApply
            }
        case .readyToApply:
            applyManualTwoPointOrigin()
        case .inactive:
            break
        }
    }

    func raycastFromScreenCenter() -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Prefer existing planes; fall back to estimated
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }

        return nil
    }

    /// Raycast helper with explicit alignment preference. Used by placement and as a fallback.
    func raycastFromScreenCenter(preferredAlignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Prefer existing plane geometry for stability
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Then fall back to estimated plane with the same alignment
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Last resort: existing any, then estimated any
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }

        return nil
    }

    /// Movement-focused raycast: prefer existing plane geometry only; skip if no stable surface under crosshair.
    func raycastFromCenterForMove(preferredAlignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Optional: if needed, allow any alignment on existing planes
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // As a fallback, allow estimated plane with preferred alignment (comment out if too jittery)
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }

        return nil
    }

    // Try horizontal first (floors/tables), then vertical (walls), then any. Returns position and chosen alignment.
    func prioritizedRaycastFromCenter() -> (SIMD3<Float>, ARRaycastQuery.TargetAlignment)? {
        if let p = raycastFromScreenCenter(preferredAlignment: .horizontal) { return (p, .horizontal) }
        if let p = raycastFromScreenCenter(preferredAlignment: .vertical) { return (p, .vertical) }
        if let p = raycastFromScreenCenter() { return (p, .any) }
        return nil
    }

    func placeManualPoint(_ position: SIMD3<Float>, color: UIColor, isFirst: Bool) {
        guard let arView = arView else { return }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        let anchor = AnchorEntity(world: t)
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [SimpleMaterial(color: color, isMetallic: false)])
        sphere.name = isFirst ? "manual_point_1" : "manual_point_2"
        // Enable hit-testing against the sphere to improve selection robustness
        sphere.generateCollisionShapes(recursive: true)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        if isFirst { manualFirstAnchor = anchor } else { manualSecondAnchor = anchor }
    }

    func removeManualAnchors() {
        if let a = manualFirstAnchor { arView?.scene.removeAnchor(a) }
        if let a = manualSecondAnchor { arView?.scene.removeAnchor(a) }
        manualFirstAnchor = nil
        manualSecondAnchor = nil
    }

    func applyManualTwoPointOrigin() {
        guard let p1 = manualFirstPoint, let p2 = manualSecondPoint else { return }
        // Compute yaw so +Z points toward p2 on XZ plane
        let dir = SIMD3<Float>(p2.x - p1.x, 0, p2.z - p1.z)
        var forward = dir
        let len = simd_length(forward)
        if len >= 1e-4 {
            forward /= len
        } else {
            forward = SIMD3<Float>(0, 0, 1)
        }
        let yaw = atan2(forward.x, forward.z)
        let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        var transform = float4x4(rotation)
        transform.columns.3 = SIMD4<Float>(p1.x, p1.y, p1.z, 1)

        // Apply new FrameOrigin
        frameOriginTransform = transform
        placeFrameOriginGizmo(at: transform)
        updateMarkersForNewFrameOrigin()

        // Exit manual mode and restore UI
        cancelManualTwoPointsMode()

        // Persist the two points and their alignments for future edits
        preservedFirstPoint = p1
        preservedSecondPoint = p2
        preservedFirstPreferredAlignment = manualFirstPreferredAlignment
        preservedSecondPreferredAlignment = manualSecondPreferredAlignment
    }

    /// Clear both points and restart Two Point placement from the first point
    func clearTwoPointPlacement() {
        // Stop any movement
        endManualPointMove()
        selectedManualPointIndex = nil
        // Remove helper anchors (and spheres)
        removeManualAnchors()
        // Reset current and preserved state so re-entry starts fresh
        manualFirstPoint = nil
        manualSecondPoint = nil
        manualFirstPreferredAlignment = nil
        manualSecondPreferredAlignment = nil
        preservedFirstPoint = nil
        preservedSecondPoint = nil
        preservedFirstPreferredAlignment = nil
        preservedSecondPreferredAlignment = nil
        // Go back to placing the first point
        manualPlacementState = .placeFirst
    }

    // MARK: - Manual point selection + moving
    func updateManualPointSelection() {
        guard manualPlacementState != .inactive, let arView = arView, let frame = arView.session.currentFrame else { return }
        // First, try a precise hit-test at the screen center against our manual spheres
        if let hitIdx = manualPointIndexHitAtCenter(arView: arView) {
            if hitIdx != selectedManualPointIndex {
                selectedManualPointIndex = hitIdx
                updateManualPointColors()
            }
            return
        }
        // Fallback: Determine which point (if any) is under crosshair by projecting to screen
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let threshold: CGFloat = 36
        var nearestIndex: Int? = nil
        var nearestDist: CGFloat = .infinity
        if let a1 = manualFirstAnchor {
            let wp = a1.position(relativeTo: nil)
            if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                let d = hypot(sp.x - center.x, sp.y - center.y)
                if d < threshold && d < nearestDist { nearestDist = d; nearestIndex = 1 }
            }
        }
        if let a2 = manualSecondAnchor {
            let wp = a2.position(relativeTo: nil)
            if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                let d = hypot(sp.x - center.x, sp.y - center.y)
                if d < threshold && d < nearestDist { nearestDist = d; nearestIndex = 2 }
            }
        }
        if nearestIndex != selectedManualPointIndex {
            selectedManualPointIndex = nearestIndex
            updateManualPointColors()
        }
    }

    func manualPointIndexHitAtCenter(arView: ARView) -> Int? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // entity(at:) returns the topmost entity with collisions at that screen point
        if let entity = arView.entity(at: center) {
            if entity.name == "manual_point_1" { return 1 }
            if entity.name == "manual_point_2" { return 2 }
            // In case the returned entity is not the sphere but a child/parent, walk up one level
            if let parent = entity.parent {
                if parent.name == "manual_point_1" { return 1 }
                if parent.name == "manual_point_2" { return 2 }
            }
        }
        return nil
    }

    func updateManualPointColors() {
        func setColor(anchor: AnchorEntity?, normalColor: UIColor, selected: Bool) {
            guard let anchor = anchor else { return }
            if let sphere = anchor.children.first(where: { $0.name.hasPrefix("manual_point_") }) as? ModelEntity {
                let color = selected ? UIColor.black : normalColor
                sphere.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
            }
        }
        setColor(anchor: manualFirstAnchor, normalColor: .red, selected: selectedManualPointIndex == 1)
        setColor(anchor: manualSecondAnchor, normalColor: .blue, selected: selectedManualPointIndex == 2)
    }

    func startManualPointMove() {
        guard manualPointMoveTimer == nil else { return }
        // Capture FIXED screen point of the selected SPHERE (child), not the anchor
        // Anchor may still hold the original placement; the sphere is what we actually move
        if let arView, let frame = arView.session.currentFrame, let idx = selectedManualPointIndex {
            let anchor = (idx == 1) ? manualFirstAnchor : manualSecondAnchor
            let sphereName = (idx == 1) ? "manual_point_1" : "manual_point_2"
            if let a = anchor,
               let sphere = a.children.first(where: { $0.name == sphereName }) {
                let wp = sphere.position(relativeTo: nil)
                if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                    fixedManualMoveScreenPoint = sp
                } else {
                    // Fallback to screen center
                    fixedManualMoveScreenPoint = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
                }
            }
        }

        // Run at ~60 Hz for smooth movement
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            if fixedManualMoveScreenPoint != nil {
                moveSelectedPointUsingFixedScreenPoint()
            } else {
                moveSelectedPointToCrossRaycast()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualPointMoveTimer = timer
    }

    func endManualPointMove() {
        manualPointMoveTimer?.invalidate()
        manualPointMoveTimer = nil
        fixedManualMoveScreenPoint = nil
    }

    func moveSelectedPointToCrossRaycast() {
        guard let idx = selectedManualPointIndex else { return }
        // Use per-point alignment chosen at placement; fallback to horizontal, then any.
        let preferred: ARRaycastQuery.TargetAlignment = {
            if idx == 1, let a = manualFirstPreferredAlignment { return a }
            if idx == 2, let a = manualSecondPreferredAlignment { return a }
            return .horizontal
        }()
        let newPos = raycastFromCenterForMove(preferredAlignment: preferred)
        guard let newPos else { return }
        // Optional: reject large jumps between discrete ticks
        if let old = (idx == 1 ? manualFirstPoint : manualSecondPoint) {
            let jump = simd_length(newPos - old)
            if jump > 0.5 { return }
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
        if idx == 1 {
            manualFirstPoint = newPos
            if let a = manualFirstAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                // Set the sphere's world transform (avoid anchor composition)
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        } else if idx == 2 {
            manualSecondPoint = newPos
            if let a = manualSecondAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                // Set the sphere's world transform (avoid anchor composition)
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        }
    }

    /// Move currently selected point using a FIXED screen point captured at movement start
    func moveSelectedPointUsingFixedScreenPoint() {
        guard let arView, let idx = selectedManualPointIndex, let screenPoint = fixedManualMoveScreenPoint else { return }

        // Use per-point alignment chosen at placement; fallback to horizontal, then any.
        let preferred: ARRaycastQuery.TargetAlignment = {
            if idx == 1, let a = manualFirstPreferredAlignment { return a }
            if idx == 2, let a = manualSecondPreferredAlignment { return a }
            return .horizontal
        }()

        // Try existing plane with preferred alignment first
        func raycast(at p: CGPoint, allowing: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
            guard let q = arView.makeRaycastQuery(from: p, allowing: allowing, alignment: alignment) else { return nil }
            let results = arView.session.raycast(q)
            guard let first = results.first else { return nil }
            let t = first.worldTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }

        let newPos =
            raycast(at: screenPoint, allowing: .existingPlaneGeometry, alignment: preferred) ??
            raycast(at: screenPoint, allowing: .existingPlaneGeometry, alignment: .any) ??
            raycast(at: screenPoint, allowing: .estimatedPlane, alignment: preferred) ??
            raycast(at: screenPoint, allowing: .estimatedPlane, alignment: .any)

        guard let newPos else { return }

        // Optional: reject large jumps
        if let old = (idx == 1 ? manualFirstPoint : manualSecondPoint) {
            let jump = simd_length(newPos - old)
            if jump > 0.5 { return }
        }

        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
        if idx == 1 {
            manualFirstPoint = newPos
            // Move the sphere child in world space (avoid anchor composition)
            if let a = manualFirstAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        } else {
            manualSecondPoint = newPos
            // Move the sphere child in world space (avoid anchor composition)
            if let a = manualSecondAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
        }
    }

    func projectWorldToScreen(worldPosition: SIMD3<Float>, frame: ARFrame, arView: ARView) -> CGPoint? {
        let camera = frame.camera
        // Use the current interface orientation instead of hard-coding portrait
        let orientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projectionMatrix = camera.projectionMatrix(for: orientation, viewportSize: arView.bounds.size, zNear: 0.001, zFar: 1000)
        let worldPos4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        let viewPos = viewMatrix * worldPos4
        // Discard points behind the camera
        if viewPos.z > 0 { return nil }
        let projPos = projectionMatrix * viewPos
        guard projPos.w != 0 else { return nil }
        let ndcX = projPos.x / projPos.w
        let ndcY = projPos.y / projPos.w
        let screenX = (ndcX + 1.0) * 0.5 * Float(arView.bounds.width)
        let screenY = (1.0 - ndcY) * 0.5 * Float(arView.bounds.height)
        return CGPoint(x: CGFloat(screenX), y: CGFloat(screenY))
    }
}
