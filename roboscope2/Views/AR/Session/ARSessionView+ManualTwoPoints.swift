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
            manualFirstPoint = p1
            manualSecondPoint = p2
            manualFirstPreferredAlignment = preservedFirstPreferredAlignment ?? .horizontal
            manualSecondPreferredAlignment = preservedSecondPreferredAlignment ?? .horizontal

            // Recreate disks + vertical lines at preserved positions
            placeManualPoint(p1, alignment: manualFirstPreferredAlignment ?? .horizontal, isFirst: true)
            placeManualPoint(p2, alignment: manualSecondPreferredAlignment ?? .horizontal, isFirst: false)
            // Show fixed measurement between the two points
            updateMeasurementVisuals(from: p1, to: p2)
            manualPlacementState = .readyToApply
        } else {
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

        // Start reticle tracking
        startReticleTracking()
    }

    func cancelManualTwoPointsMode() {
        manualPlacementState = .inactive
        stopReticleTracking()
        removeManualAnchors()
        removeMeasurementVisuals()
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
                placeManualPoint(p, alignment: align, isFirst: true)
                manualFirstPoint = p
                manualFirstPreferredAlignment = align
                manualPlacementState = .placeSecond
            }
        case .placeSecond:
            if let (p, align) = prioritizedRaycastFromCenter() {
                placeManualPoint(p, alignment: align, isFirst: false)
                manualSecondPoint = p
                manualSecondPreferredAlignment = align
                if let p1 = manualFirstPoint {
                    updateMeasurementVisuals(from: p1, to: p)
                }
                manualPlacementState = .readyToApply
            }
        case .readyToApply:
            applyManualTwoPointOrigin()
        case .inactive:
            break
        }
    }

    /// The screen point where the crosshair lives (offset from screen center).
    private func crossCenter() -> CGPoint {
        guard let arView else { return .zero }
        return CGPoint(x: arView.bounds.midX, y: arView.bounds.midY + 40)
    }

    func raycastFromScreenCenter() -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let pt = crossCenter()
        if let query = arView.makeRaycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: pt, allowing: .estimatedPlane, alignment: .any) {
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
        let pt = crossCenter()
        if let query = arView.makeRaycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Then fall back to estimated plane with the same alignment
        if let query = arView.makeRaycastQuery(from: pt, allowing: .estimatedPlane, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Last resort: existing any, then estimated any
        if let query = arView.makeRaycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: pt, allowing: .estimatedPlane, alignment: .any) {
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
        let pt = crossCenter()
        if let query = arView.makeRaycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Optional: if needed, allow any alignment on existing planes
        if let query = arView.makeRaycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // As a fallback, allow estimated plane with preferred alignment (comment out if too jittery)
        if let query = arView.makeRaycastQuery(from: pt, allowing: .estimatedPlane, alignment: preferredAlignment) {
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

    func placeManualPoint(_ position: SIMD3<Float>, alignment: ARRaycastQuery.TargetAlignment, isFirst: Bool) {
        guard let arView = arView else { return }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)

        switch alignment {
        case .horizontal: break
        case .vertical:
            t = t * float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)))
        case .any: break
        @unknown default: break
        }

        let anchor = AnchorEntity(world: t)

        // Dashed cross reference (1m, red/blue)
        let color: UIColor = isFirst
            ? UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
            : UIColor(red: 0.2, green: 0.4, blue: 1.0, alpha: 1.0)
        let cross = ManualPointHelpers.makeReferenceCross(
            name: isFirst ? "manual_point_1" : "manual_point_2",
            color: color
        )
        anchor.addChild(cross)

        arView.scene.addAnchor(anchor)
        if isFirst {
            if let old = manualFirstAnchor { arView.scene.removeAnchor(old) }
            manualFirstAnchor = anchor
        } else {
            if let old = manualSecondAnchor { arView.scene.removeAnchor(old) }
            manualSecondAnchor = anchor
        }

        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
    }

    func removeManualAnchors() {
        if let a = manualFirstAnchor { arView?.scene.removeAnchor(a) }
        if let a = manualSecondAnchor { arView?.scene.removeAnchor(a) }
        manualFirstAnchor = nil
        manualSecondAnchor = nil
    }

    func removeMeasurementVisuals() {
        if let a = measurementLineAnchor { arView?.scene.removeAnchor(a) }
        if let a = measurementBadgeAnchor { arView?.scene.removeAnchor(a) }
        measurementLineAnchor = nil
        measurementBadgeAnchor = nil
        measurementDistanceText = nil
        measurementBadgeScreenPoint = nil
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
        endManualPointMove()
        selectedManualPointIndex = nil
        stopReticleTracking()
        removeManualAnchors()
        removeMeasurementVisuals()
        manualFirstPoint = nil
        manualSecondPoint = nil
        manualFirstPreferredAlignment = nil
        manualSecondPreferredAlignment = nil
        preservedFirstPoint = nil
        preservedSecondPoint = nil
        preservedFirstPreferredAlignment = nil
        preservedSecondPreferredAlignment = nil
        manualPlacementState = .placeFirst
        // Restart reticle for fresh placement
        startReticleTracking()
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
        // Disks are now solid white UnlitMaterial — no per-point colour coding.
        // Selection is indicated by the existing hit-test + move flow.
    }

    // MARK: - Reticle tracking

    func startReticleTracking() {
        guard reticleTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            updateReticle()
        }
        RunLoop.main.add(timer, forMode: .common)
        reticleTimer = timer
    }

    func stopReticleTracking() {
        reticleTimer?.invalidate()
        reticleTimer = nil
        if let a = reticleAnchor {
            arView?.scene.removeAnchor(a)
            reticleAnchor = nil
        }
    }

    func updateReticle() {
        guard let arView else { return }
        if let a = reticleAnchor { arView.scene.removeAnchor(a); reticleAnchor = nil }

        guard let hitPos = raycast(from: crossCenter()) else { return }

        let anchor = AnchorEntity(world: hitPos)
        anchor.addChild(ManualPointHelpers.makeReticleDot())
        arView.scene.addAnchor(anchor)
        reticleAnchor = anchor

        if manualPlacementState == .placeSecond, let p1 = manualFirstPoint {
            updateMeasurementVisuals(from: p1, to: hitPos)
        } else if manualPlacementState == .readyToApply, let p1 = manualFirstPoint, let p2 = manualSecondPoint {
            // Keep badge anchored to the fixed line as camera moves
            refreshMeasurementBadgeScreenPosition(from: p1, to: p2)
        }
    }

    private func refreshMeasurementBadgeScreenPosition(from: SIMD3<Float>, to: SIMD3<Float>) {
        guard let arView, let frame = arView.session.currentFrame else { return }
        let mid = (from + to) / 2
        let badgeWorld = SIMD3<Float>(mid.x, mid.y + 0.05, mid.z)
        if let screenPt = projectWorldToScreen(worldPosition: badgeWorld, frame: frame, arView: arView) {
            measurementBadgeScreenPoint = screenPt
        }
    }

    private func raycast(from screenPoint: CGPoint) -> SIMD3<Float>? {
        guard let arView else { return nil }
        if let query = arView.makeRaycastQuery(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .any),
           let first = arView.session.raycast(query).first {
            let t = first.worldTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        if let query = arView.makeRaycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any),
           let first = arView.session.raycast(query).first {
            let t = first.worldTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }
        return nil
    }

    // MARK: - Measurement visuals

    /// Updates (or creates) the measurement line and distance badge between two world positions.
    func updateMeasurementVisuals(from: SIMD3<Float>, to: SIMD3<Float>) {
        guard let arView else { return }

        let distance = simd_distance(from, to)

        if let a = measurementLineAnchor { arView.scene.removeAnchor(a) }

        let line = ManualPointHelpers.makeMeasurementLine(from: from, to: to)
        let lineAnchor = AnchorEntity(world: .zero)
        lineAnchor.addChild(line)
        arView.scene.addAnchor(lineAnchor)
        measurementLineAnchor = lineAnchor

        // Screen-space badge: Z label at first reference
        let firstBadgeWorld = SIMD3<Float>(from.x, from.y + 0.15, from.z)
        if let frame = arView.session.currentFrame,
           let screenPt = projectWorldToScreen(worldPosition: firstBadgeWorld, frame: frame, arView: arView) {
            measurementBadgeScreenPoint = screenPt
        }
        if distance < 0.01 {
            measurementDistanceText = "Z: 0 cm"
        } else if distance < 1.0 {
            measurementDistanceText = "Z: \(String(format: "%.0f", distance * 100)) cm"
        } else {
            measurementDistanceText = "Z: \(String(format: "%.2f", distance))m"
        }
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

