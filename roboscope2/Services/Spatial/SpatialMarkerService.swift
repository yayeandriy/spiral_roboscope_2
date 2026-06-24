//
//  SpatialMarkerService.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import ARKit
import RealityKit
import Combine
import UIKit
import Foundation

/// Manages spatial markers placed in AR
final class SpatialMarkerService: ObservableObject {
    weak var arView: ARView?

    private var markersVisible: Bool = true

    // MARK: - Mesh cache (avoids runtime mesh generation per marker)

    private static let nodeMesh = MeshResource.generateSphere(radius: 0.01)
    private static let edgeMesh = MeshResource.generateCylinder(height: 1.0, radius: 0.0005)
    private static let markerMaterial = UnlitMaterial(color: .white)
    
    @Published var markers: [SpatialMarker] = []
    
    // Tracking state
    @Published var markersInTarget: Set<UUID> = []
    @Published var selectedMarkerID: UUID?
    var markerEdgesInTarget: [UUID: Set<Int>] = [:] // Stores which edges (0-3) are in target for each marker
    var selectedEdgeIndex: Int? // Edge index (0-3) for currently selected marker

    /// True when the target area crosses an object edge — UI should warn the user.
    @Published var targetCrossesEdge: Bool = false
    
    // Moving state
    var movingMarkerIndex: Int?
    var nodeScreenPositions: [CGPoint] = []
    var updateCounter: Int = 0
    var movingEdgeIndices: (Int, Int)?
    // Transform (move/resize) helpers
    var originalNodeScreenPositions: [CGPoint] = []
    var lastWorldNodePositions: [SIMD3<Float>] = []
    private var referenceCenterScreen: CGPoint = .zero
    
    struct SpatialMarker: Identifiable {
        let id = UUID()
        var backendId: UUID? = nil // Link to server-side marker
        var version: Int64 = 0 // Track marker version for optimistic locking
        var nodes: [SIMD3<Float>] // 4 corner positions in AR world space (mutable for moving)
        var frameOriginNodes: [SIMD3<Float>]? // Original frame-origin coordinates from server
        let anchorEntity: AnchorEntity
        var isSelected: Bool = false
        var details: MarkerDetails? = nil // Server-computed marker details
        var calibratedData: CalibratedData? = nil // Server-provided calibrated coordinates
    }

    /// Show/hide marker visuals without deleting them.
    /// When hidden, selection state is cleared to avoid showing marker UI while markers are invisible.
    @MainActor
    func setMarkersVisible(_ visible: Bool) {
        markersVisible = visible
        for marker in markers {
            marker.anchorEntity.isEnabled = visible
        }

        if !visible {
            selectedMarkerID = nil
            markersInTarget.removeAll()
            markerEdgesInTarget.removeAll()
            selectedEdgeIndex = nil
        }

        objectWillChange.send()
    }
    
    /// Create and add a marker from world-space points (used when loading from server)
    @discardableResult
    func addMarker(points: [SIMD3<Float>], backendId: UUID? = nil, version: Int64 = 0, details: MarkerDetails? = nil, calibratedData: CalibratedData? = nil, frameOriginNodes: [SIMD3<Float>]? = nil) -> SpatialMarker {
        guard let arView = arView else {
            let anchor = AnchorEntity(world: .zero)
            anchor.isEnabled = markersVisible
            return SpatialMarker(version: version, nodes: points, frameOriginNodes: frameOriginNodes, anchorEntity: anchor, details: details)
        }
        // Create anchor and geometry similar to placeMarker()
        let anchorEntity = AnchorEntity(world: .zero)
        anchorEntity.isEnabled = markersVisible

        // Nodes — reuse cached sphere mesh
        for (index, position) in points.enumerated() {
            let nodeEntity = ModelEntity(mesh: Self.nodeMesh, materials: [Self.markerMaterial])
            nodeEntity.position = position
            nodeEntity.name = "node_\(index)"
            anchorEntity.addChild(nodeEntity)
        }
        
        // Edges — reuse cached cylinder mesh (height=1), scale to match distance
        let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (i, j) in edgeIndices {
            let start = points[i]
            let end = points[j]
            let midpoint = (start + end) / 2
            let direction = end - start
            let length = simd_length(direction)
            let edgeEntity = ModelEntity(mesh: Self.edgeMesh, materials: [Self.markerMaterial])
            edgeEntity.position = midpoint
            edgeEntity.scale = SIMD3<Float>(1, length, 1)
            let up = normalize(direction)
            let defaultUp = SIMD3<Float>(0, 1, 0)
            if simd_length(cross(defaultUp, up)) > 0.001 {
                let axis = normalize(cross(defaultUp, up))
                let angle = acos(dot(defaultUp, up))
                edgeEntity.orientation = simd_quatf(angle: angle, axis: axis)
            }
            edgeEntity.name = "edge_\(i)_\(j)"
            anchorEntity.addChild(edgeEntity)
        }
        
        arView.scene.addAnchor(anchorEntity)
        let marker = SpatialMarker(backendId: backendId, version: version, nodes: points, frameOriginNodes: frameOriginNodes, anchorEntity: anchorEntity, isSelected: false, details: details, calibratedData: calibratedData)
        markers.append(marker)
        return marker
    }
    
    /// Link a local spatial marker to a backend marker id
    func linkSpatialMarker(localId: UUID, backendId: UUID) {
        if let idx = markers.firstIndex(where: { $0.id == localId }) {
            markers[idx].backendId = backendId
        }
    }
    
    /// Set frame-origin coordinates for a local marker
    func setFrameOriginNodes(localId: UUID, frameOriginNodes: [SIMD3<Float>]) {
        if let idx = markers.firstIndex(where: { $0.id == localId }) {
            markers[idx].frameOriginNodes = frameOriginNodes
        }
    }
    
    /// Update frame-origin coordinates for a marker by backend ID
    func updateFrameOriginNodesByBackendId(backendId: UUID, frameOriginNodes: [SIMD3<Float>]) {
        if let idx = markers.firstIndex(where: { $0.backendId == backendId }) {
            markers[idx].frameOriginNodes = frameOriginNodes
        }
    }
    
    /// Update calibrated data and details from server response
    @MainActor
    func updateCalibratedData(backendId: UUID, calibratedData: CalibratedData?, details: MarkerDetails?) {
        if let idx = markers.firstIndex(where: { $0.backendId == backendId }) {
            markers[idx].calibratedData = calibratedData
            markers[idx].details = details
            objectWillChange.send()
        }
    }
    
    /// Remove a marker by backend id
    func removeMarkerByBackendId(_ backendId: UUID) {
        guard let arView = arView else { return }
        if let idx = markers.firstIndex(where: { $0.backendId == backendId }) {
            arView.scene.removeAnchor(markers[idx].anchorEntity)
            // Clear selection if we removed the selected marker (compare local id)
            if selectedMarkerID == markers[idx].id { selectedMarkerID = nil }
            markers.remove(at: idx)
        }
    }

    /// Backend id of the currently selected marker (if any)
    var selectedBackendId: UUID? {
        guard let selId = selectedMarkerID,
              let m = markers.first(where: { $0.id == selId }) else { return nil }
        return m.backendId
    }

    /// Remove selected marker locally (by local id)
    func removeSelectedMarkerLocal() {
        guard let arView = arView, let selId = selectedMarkerID,
              let idx = markers.firstIndex(where: { $0.id == selId }) else { return }
        arView.scene.removeAnchor(markers[idx].anchorEntity)
        markers.remove(at: idx)
        selectedMarkerID = nil
    }
    
    /// Load persisted markers from API models
    func loadPersistedMarkers(_ apiMarkers: [Marker], originalFrameOriginMarkers: [Marker]? = nil) {
        for (index, m) in apiMarkers.enumerated() {
            let frameOriginNodes = originalFrameOriginMarkers?[safe: index]?.points
            if let idx = markers.firstIndex(where: { $0.backendId == m.id }) {
                // Update existing visual marker to match backend
                markers[idx].version = m.version
                markers[idx].details = m.details
                markers[idx].calibratedData = m.calibratedData
                markers[idx].frameOriginNodes = frameOriginNodes
                applyNodePositions(markerIndex: idx, newNodePositions: m.points)
            } else {
                // Add new marker from backend
                addMarker(points: m.points, backendId: m.id, version: m.version, details: m.details, calibratedData: m.calibratedData, frameOriginNodes: frameOriginNodes)
            }
        }
        
        // Automatically calculate details for any markers that don't have them
        Task {
            for marker in markers where marker.backendId != nil && marker.details == nil {
                if let backendId = marker.backendId {
                    await refreshMarkerDetails(backendId: backendId)
                }
            }
            
            // Ensure UI update happens on main thread
            await MainActor.run {
                self.objectWillChange.send()
            }
        }
    }
    
    /// Place a marker by raycasting from target corners.
    /// Handles object edges by snapping background corners to the foreground plane.
    func placeMarker(targetCorners: [CGPoint]) {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return }

        guard let points = raycastMarkerCorners(targetCorners: targetCorners, arView: arView, camera: frame.camera) else { return }
        _ = addMarker(points: points)
    }

    /// Place a marker and return the created SpatialMarker (for persistence)
    @discardableResult
    func placeMarkerReturningSpatial(targetCorners: [CGPoint]) -> SpatialMarker? {
        guard let arView = arView,
              let frame = arView.session.currentFrame else { return nil }

        guard let points = raycastMarkerCorners(targetCorners: targetCorners, arView: arView, camera: frame.camera) else { return nil }
        return addMarker(points: points)
    }

    /// Raycasts 4 target corners. Returns nil if any corner misses or crosses an object edge.
    private func raycastMarkerCorners(targetCorners: [CGPoint], arView: ARView, camera: ARCamera) -> [SIMD3<Float>]? {
        guard targetCorners.count == 4 else { return nil }

        // Simple raycast — all 4 must hit
        var hitPoints: [SIMD3<Float>] = []
        for corner in targetCorners {
            let results = arView.raycast(from: corner, allowing: .estimatedPlane, alignment: .any)
            if let first = results.first {
                let pos = SIMD3<Float>(first.worldTransform.columns.3.x,
                                       first.worldTransform.columns.3.y,
                                       first.worldTransform.columns.3.z)
                hitPoints.append(pos)
            } else {
                return nil
            }
        }

        if ARGeometryUtils.checkEdgeCrossing(hitPoints) { return nil }
        return hitPoints
    }

    /// Returns true if the 4 corners span an object edge (one corner on a different surface).
    func checkEdgeCrossing(_ points: [SIMD3<Float>]) -> Bool {
        ARGeometryUtils.checkEdgeCrossing(points)
    }

    /// Checks if the given target corners cross an object edge, updates targetCrossesEdge.
    func updateTargetEdgeState(targetCorners: [CGPoint]) {
        guard let arView, arView.session.currentFrame != nil else {
            targetCrossesEdge = false
            return
        }
        var hitPoints: [SIMD3<Float>] = []
        for corner in targetCorners {
            let results = arView.raycast(from: corner, allowing: .estimatedPlane, alignment: .any)
            if let first = results.first {
                let pos = SIMD3<Float>(first.worldTransform.columns.3.x,
                                       first.worldTransform.columns.3.y,
                                       first.worldTransform.columns.3.z)
                hitPoints.append(pos)
            }
        }
        // Edge also indicated when corners miss (partial hits)
        if hitPoints.count < 4 {
            targetCrossesEdge = hitPoints.count > 0
        } else {
            targetCrossesEdge = checkEdgeCrossing(hitPoints)
        }
    }

    // MARK: - Plane helpers (delegated to ARGeometryUtils)

    private func fitPlane(points: [SIMD3<Float>]) -> (center: SIMD3<Float>, normal: SIMD3<Float>) {
        ARGeometryUtils.fitPlane(points: points)
    }
    
    /// Clear all markers
    func clearMarkers() {
        guard let arView = arView else { return }
        
        for marker in markers {
            arView.scene.removeAnchor(marker.anchorEntity)
        }
        
        markers.removeAll()
    }

    /// Project a world position to screen coordinates (delegates to ARGeometryUtils).
    func projectWorldToScreen(worldPosition: SIMD3<Float>, frame: ARFrame, arView: ARView) -> CGPoint? {
        ARGeometryUtils.projectWorldToScreen(worldPosition: worldPosition, frame: frame, arView: arView)
    }
}

// MARK: - Finger-driven Transform API (Move + Resize)
extension SpatialMarkerService {
    /// Prepare to transform (move/resize) the selected marker using finger gestures.
    /// - Parameter referenceCenter: The screen-space reference center (e.g., target center) used for scaling around.
    func startTransformSelectedMarker(referenceCenter: CGPoint) -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let selectedID = selectedMarkerID,
              let markerIndex = markers.firstIndex(where: { $0.id == selectedID }) else {
            return false
        }

        let marker = markers[markerIndex]
        // Project all nodes to screen and store their positions
        let screenPts = marker.nodes.compactMap { projectWorldToScreen(worldPosition: $0, frame: frame, arView: arView) }
        guard screenPts.count == 4 else {
            return false
        }
        originalNodeScreenPositions = screenPts
        nodeScreenPositions = screenPts
        lastWorldNodePositions = marker.nodes
        referenceCenterScreen = referenceCenter
        movingMarkerIndex = markerIndex
        updateCounter = 0
        return true
    }

    /// Update the transform by applying drag and pinch to screen positions, then raycast to world.
    func updateTransform(dragTranslation: CGSize, pinchScale: CGFloat) {
        guard let arView = arView,
              let markerIndex = movingMarkerIndex else { return }

        // Compute new screen positions relative to reference center
        var adjustedScreenPoints: [CGPoint] = []
        for orig in originalNodeScreenPositions {
            let dx = dragTranslation.width
            let dy = dragTranslation.height
            // Scale around reference center, then add drag
            let sx = referenceCenterScreen.x + (orig.x - referenceCenterScreen.x) * pinchScale + dx
            let sy = referenceCenterScreen.y + (orig.y - referenceCenterScreen.y) * pinchScale + dy
            adjustedScreenPoints.append(CGPoint(x: sx, y: sy))
        }
        nodeScreenPositions = adjustedScreenPoints

        // Raycast these points into world space
        var newWorldPositions: [SIMD3<Float>] = []
        newWorldPositions.reserveCapacity(4)
        for (idx, sp) in adjustedScreenPoints.enumerated() {
            let results = arView.raycast(from: sp, allowing: .estimatedPlane, alignment: .any)
            if let first = results.first {
                let wp = SIMD3<Float>(first.worldTransform.columns.3.x,
                                      first.worldTransform.columns.3.y,
                                      first.worldTransform.columns.3.z)
                newWorldPositions.append(wp)
            } else if idx < lastWorldNodePositions.count {
                // Fallback to last known world position for stability
                newWorldPositions.append(lastWorldNodePositions[idx])
            } else {
                // As a last resort, skip update if we can't maintain all nodes
                return
            }
        }

        // Apply updates
        guard newWorldPositions.count == 4 else { return }
        markers[markerIndex].nodes = newWorldPositions
        lastWorldNodePositions = newWorldPositions

        let anchorEntity = markers[markerIndex].anchorEntity
        // Update node entities
        for (i, pos) in newWorldPositions.enumerated() {
            if let nodeEntity = anchorEntity.children.first(where: { $0.name == "node_\(i)" }) as? ModelEntity {
                nodeEntity.position = pos
            }
        }
        // Update edges less frequently
        updateCounter += 1
        if updateCounter % 2 == 0 {
            let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)]
            for (i, j) in edgeIndices {
                guard let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity else { continue }
                let start = newWorldPositions[i]
                let end = newWorldPositions[j]
                let midpoint = (start + end) / 2
                let direction = end - start
                let length = simd_length(direction)
                edgeEntity.scale = SIMD3<Float>(1, length, 1)
                edgeEntity.position = midpoint
                let up = normalize(direction)
                let defaultUp = SIMD3<Float>(0, 1, 0)
                let dotProduct = dot(defaultUp, up)
                if abs(dotProduct) < 0.999 {
                    let axis = normalize(cross(defaultUp, up))
                    let angle = acos(max(-1, min(1, dotProduct)))
                    edgeEntity.orientation = simd_quatf(angle: angle, axis: axis)
                } else if dotProduct < 0 {
                    edgeEntity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
                }
            }
        }
    }

    /// End the current transform and return the modified marker for persistence
    /// - Returns: (backendId, updatedNodes) if a marker was being transformed, nil otherwise
    func endTransform() -> (UUID, Int64, [SIMD3<Float>])? {
        return stopMovingMarker()
    }

    // MARK: - Edge movement (one finger)
    /// Prepare to move the currently selected edge (auto-selected in updateMarkersInTarget)
    func startMoveSelectedEdge() -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let selID = selectedMarkerID,
              let markerIdx = markers.firstIndex(where: { $0.id == selID }),
              let selEdge = selectedEdgeIndex else {
            return false
        }
        let pairs = [(0,1),(1,2),(2,3),(3,0)]
        let (i, j) = pairs[selEdge]
        let marker = markers[markerIdx]
        guard let p1 = projectWorldToScreen(worldPosition: marker.nodes[i], frame: frame, arView: arView),
              let p2 = projectWorldToScreen(worldPosition: marker.nodes[j], frame: frame, arView: arView) else {
            return false
        }
        movingMarkerIndex = markerIdx
        originalNodeScreenPositions = [p1, p2]
        nodeScreenPositions = originalNodeScreenPositions
        lastWorldNodePositions = [marker.nodes[i], marker.nodes[j]]
        movingEdgeIndices = (i, j)
        updateCounter = 0
        return true
    }

    /// Update the moving edge by raycasting the two adjusted screen points
    func updateMoveSelectedEdge() {
        guard let arView = arView,
              let (i, j) = movingEdgeIndices,
              let markerIdx = movingMarkerIndex else { return }
        // Raycast from stored two screen positions (projected once on start)
        var newWorld: [SIMD3<Float>] = []
        for (idx, sp) in nodeScreenPositions.enumerated() {
            let results = arView.raycast(from: sp, allowing: .estimatedPlane, alignment: .any)
            if let first = results.first {
                let wp = SIMD3<Float>(first.worldTransform.columns.3.x,
                                      first.worldTransform.columns.3.y,
                                      first.worldTransform.columns.3.z)
                newWorld.append(wp)
            } else if idx < lastWorldNodePositions.count {
                newWorld.append(lastWorldNodePositions[idx])
            } else {
                return
            }
        }
        guard newWorld.count == 2 else { return }
        // Compose full node set with two updated nodes
        var allNodes = markers[markerIdx].nodes
        allNodes[i] = newWorld[0]
        allNodes[j] = newWorld[1]
        lastWorldNodePositions = newWorld
        applyNodePositions(markerIndex: markerIdx, newNodePositions: allNodes)
        refreshHandlers(markerIndex: markerIdx)
    }

    /// Update the moving edge using a one-finger drag translation in screen space.
    /// This adjusts the originally projected edge endpoints by the drag delta and raycasts them each tick.
    func updateMoveSelectedEdge(withDrag dragTranslation: CGSize) {
        guard let arView = arView,
              let (i, j) = movingEdgeIndices,
              let markerIdx = movingMarkerIndex,
              originalNodeScreenPositions.count == 2 else { return }

        // Compute adjusted screen positions by adding drag delta to the original points
        let adjusted: [CGPoint] = originalNodeScreenPositions.map { p in
            CGPoint(x: p.x + dragTranslation.width, y: p.y + dragTranslation.height)
        }
        nodeScreenPositions = adjusted

        // Raycast adjusted points
        var newWorld: [SIMD3<Float>] = []
        for (idx, sp) in adjusted.enumerated() {
            let results = arView.raycast(from: sp, allowing: .estimatedPlane, alignment: .any)
            if let first = results.first {
                let wp = SIMD3<Float>(first.worldTransform.columns.3.x,
                                      first.worldTransform.columns.3.y,
                                      first.worldTransform.columns.3.z)
                newWorld.append(wp)
            } else if idx < lastWorldNodePositions.count {
                // fallback to last known to keep continuity
                newWorld.append(lastWorldNodePositions[idx])
            } else {
                // Skip update if can't resolve both points
                return
            }
        }
        guard newWorld.count == 2 else { return }
        var allNodes = markers[markerIdx].nodes
        allNodes[i] = newWorld[0]
        allNodes[j] = newWorld[1]
        lastWorldNodePositions = newWorld
        applyNodePositions(markerIndex: markerIdx, newNodePositions: allNodes)
        refreshHandlers(markerIndex: markerIdx)
    }
    
    /// End edge movement and return the modified marker for persistence
    func endMoveSelectedEdge() -> (UUID, Int64, [SIMD3<Float>])? {
        return stopMovingMarker()
    }

    /// Recalculate handler positions for the currently selected edge of a marker
    private func refreshHandlers(markerIndex: Int) {
        guard markerIndex < markers.count,
              let selEdge = selectedEdgeIndex,
              markers[markerIndex].id == selectedMarkerID else { return }
        let marker = markers[markerIndex]
        let anchorEntity = marker.anchorEntity
        let pairs = [(0,1),(1,2),(2,3),(3,0)]
        let (i, j) = pairs[selEdge]
        let pA = marker.nodes[i]
        let pB = marker.nodes[j]
        let mid = (pA + pB) / 2
        let dir = normalize(pB - pA)
        var perp = SIMD3<Float>(dir.z, 0, -dir.x)
        if simd_length(perp) < 0.0001 { perp = SIMD3<Float>(1, 0, 0) }
        perp = normalize(perp)
        let gap: Float = 0.008
        for (side, name) in [(-1, "handler_a"), (1, "handler_b")] {
            if let handle = anchorEntity.children.first(where: { $0.name == name }) {
                handle.position = mid + perp * gap * Float(side)
                let yAxis = SIMD3<Float>(0, 1, 0)
                let crossVal = cross(yAxis, dir)
                if simd_length(crossVal) > 0.0001 {
                    handle.orientation = simd_quatf(angle: acos(dot(yAxis, dir)), axis: normalize(crossVal))
                }
            }
        }
    }
}

// MARK: - Geometry rebuild helper
extension SpatialMarkerService {
    /// Apply node positions and fully rebuild visible geometry (nodes + all 4 edges)
    func applyNodePositions(markerIndex: Int, newNodePositions: [SIMD3<Float>]) {
        guard markerIndex < markers.count else { return }
        markers[markerIndex].nodes = newNodePositions
        let anchorEntity = markers[markerIndex].anchorEntity
        // Update node entities
        for (index, newPosition) in newNodePositions.enumerated() {
            if let nodeEntity = anchorEntity.children.first(where: { $0.name == "node_\(index)" }) as? ModelEntity {
                nodeEntity.position = newPosition
            }
        }
        // Rebuild all edges each update (reuse cached cylinder, scale to length)
        let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (i, j) in edgeIndices {
            if let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity {
                let start = newNodePositions[i]
                let end = newNodePositions[j]
                let midpoint = (start + end) / 2
                let direction = end - start
                let length = simd_length(direction)
                edgeEntity.scale = SIMD3<Float>(1, length, 1)
                edgeEntity.position = midpoint
                let up = normalize(direction)
                let defaultUp = SIMD3<Float>(0, 1, 0)
                let dotProduct = dot(defaultUp, up)
                if abs(dotProduct) < 0.999 {
                    let axis = normalize(cross(defaultUp, up))
                    let angle = acos(max(-1, min(1, dotProduct)))
                    edgeEntity.orientation = simd_quatf(angle: angle, axis: axis)
                } else if dotProduct < 0 {
                    edgeEntity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
                }
            }
        }
    }
}
