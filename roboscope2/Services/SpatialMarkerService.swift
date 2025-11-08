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
    
    @Published var markers: [SpatialMarker] = []
    
    // Tracking state
    @Published var markersInTarget: Set<UUID> = []
    @Published var selectedMarkerID: UUID?
    var markerEdgesInTarget: [UUID: Set<Int>] = [:] // Stores which edges (0-3) are in target for each marker
    var selectedEdgeIndex: Int? // Edge index (0-3) for currently selected marker
    
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
        var nodes: [SIMD3<Float>] // 4 corner positions (mutable for moving)
        let anchorEntity: AnchorEntity
        var isSelected: Bool = false
        var details: MarkerDetails? = nil // Server-computed marker details
        var calibratedData: CalibratedData? = nil // Server-provided calibrated coordinates
    }
    
    /// Create and add a marker from world-space points (used when loading from server)
    @discardableResult
    func addMarker(points: [SIMD3<Float>], backendId: UUID? = nil, version: Int64 = 0, details: MarkerDetails? = nil, calibratedData: CalibratedData? = nil) -> SpatialMarker {
        guard let arView = arView else {
            return SpatialMarker(version: version, nodes: points, anchorEntity: AnchorEntity(world: .zero), details: details)
        }
        // Create anchor and geometry similar to placeMarker()
        let anchorEntity = AnchorEntity(world: .zero)
        
        // Nodes
        for (index, position) in points.enumerated() {
            let nodeMesh = MeshResource.generateSphere(radius: 0.01)
            let nodeEntity = ModelEntity(mesh: nodeMesh, materials: [UnlitMaterial(color: .black)])
            nodeEntity.position = position
            nodeEntity.name = "node_\(index)"
            anchorEntity.addChild(nodeEntity)
        }
        
        // Edges
        let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (i, j) in edgeIndices {
            let start = points[i]
            let end = points[j]
            let midpoint = (start + end) / 2
            let direction = end - start
            let length = simd_length(direction)
            let edgeMesh = MeshResource.generateCylinder(height: length, radius: 0.0005)
            let edgeEntity = ModelEntity(mesh: edgeMesh, materials: [UnlitMaterial(color: UIColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0))])
            edgeEntity.position = midpoint
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
        let marker = SpatialMarker(backendId: backendId, version: version, nodes: points, anchorEntity: anchorEntity, isSelected: false, details: details, calibratedData: calibratedData)
        markers.append(marker)
        return marker
    }
    
    /// Link a local spatial marker to a backend marker id
    func linkSpatialMarker(localId: UUID, backendId: UUID) {
        if let idx = markers.firstIndex(where: { $0.id == localId }) {
            markers[idx].backendId = backendId
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
    func loadPersistedMarkers(_ apiMarkers: [Marker]) {
        for m in apiMarkers {
            if let idx = markers.firstIndex(where: { $0.backendId == m.id }) {
                // Update existing visual marker to match backend
                markers[idx].version = m.version
                markers[idx].details = m.details
                markers[idx].calibratedData = m.calibratedData
                applyNodePositions(markerIndex: idx, newNodePositions: m.points)
            } else {
                // Add new marker from backend
                addMarker(points: m.points, backendId: m.id, version: m.version, details: m.details, calibratedData: m.calibratedData)
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
    
    /// Place a marker by raycasting from target corners
    func placeMarker(targetCorners: [CGPoint]) {
                guard let arView = arView,
                            let frame = arView.session.currentFrame else {
                        return
                }
        
        // First, raycast from the center to establish a reference plane and distance
        let screenCenter = CGPoint(
            x: (targetCorners[0].x + targetCorners[2].x) / 2,
            y: (targetCorners[0].y + targetCorners[2].y) / 2
        )
        
        guard let centerResult = arView.raycast(from: screenCenter, allowing: .estimatedPlane, alignment: .any).first else {
            return
        }
        
        let centerPosition = SIMD3<Float>(
            centerResult.worldTransform.columns.3.x,
            centerResult.worldTransform.columns.3.y,
            centerResult.worldTransform.columns.3.z
        )
        
        // Calculate the camera position
        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
    // Calculate the reference distance from camera to center (unused, kept for potential UX)
    _ = simd_distance(cameraPosition, centerPosition)
        
        // Now raycast from each corner and use actual hit positions
        var hitPoints: [SIMD3<Float>] = []
        
        for corner in targetCorners {
            let results = arView.raycast(from: corner, allowing: .estimatedPlane, alignment: .any)
            
            if let firstResult = results.first {
                let worldPosition = SIMD3<Float>(
                    firstResult.worldTransform.columns.3.x,
                    firstResult.worldTransform.columns.3.y,
                    firstResult.worldTransform.columns.3.z
                )
                hitPoints.append(worldPosition)
            } else {
                return
            }
        }
        
        // Need 4 hit points for a valid marker
        guard hitPoints.count == 4 else {
            return
        }
        
        // Create spatial marker from computed points
        _ = addMarker(points: hitPoints)
    }
    
    /// Place a marker and return the created SpatialMarker (for persistence)
    @discardableResult
    func placeMarkerReturningSpatial(targetCorners: [CGPoint]) -> SpatialMarker? {
      guard let arView = arView,
          let _ = arView.session.currentFrame else { return nil }
        // Reuse the standard placement logic
        // First, raycast center to ensure session has a reference (not strictly needed here)
        let screenCenter = CGPoint(
            x: (targetCorners[0].x + targetCorners[2].x) / 2,
            y: (targetCorners[0].y + targetCorners[2].y) / 2
        )
        guard let _ = arView.raycast(from: screenCenter, allowing: .estimatedPlane, alignment: .any).first else {
            return nil
        }
        var hitPoints: [SIMD3<Float>] = []
        for corner in targetCorners {
            let results = arView.raycast(from: corner, allowing: .estimatedPlane, alignment: .any)
            if let first = results.first {
                let pos = SIMD3<Float>(first.worldTransform.columns.3.x, first.worldTransform.columns.3.y, first.worldTransform.columns.3.z)
                hitPoints.append(pos)
            } else { return nil }
        }
        return addMarker(points: hitPoints)
    }
    
    /// Clear all markers
    func clearMarkers() {
        guard let arView = arView else { return }
        
        for marker in markers {
            arView.scene.removeAnchor(marker.anchorEntity)
        }
        
        markers.removeAll()
    }

    /// Show or hide all markers visually without removing them from the scene
    func setMarkersVisible(_ visible: Bool) {
        for marker in markers {
            marker.anchorEntity.isEnabled = visible
        }
    }
    
    
    /// Project a world position to screen coordinates
    func projectWorldToScreen(worldPosition: SIMD3<Float>, frame: ARFrame, arView: ARView) -> CGPoint? {
        let camera = frame.camera
        
        // Convert world position to camera space
        let viewMatrix = camera.viewMatrix(for: .portrait)
        let projectionMatrix = camera.projectionMatrix(for: .portrait, viewportSize: arView.bounds.size, zNear: 0.001, zFar: 1000)
        
        // Transform to homogeneous coordinates
        let worldPos4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        
        // Apply view and projection matrices
        let viewPos = viewMatrix * worldPos4
        let projPos = projectionMatrix * viewPos
        
        // Perspective divide
        guard projPos.w != 0 else { return nil }
        let ndcPos = SIMD3<Float>(projPos.x / projPos.w, projPos.y / projPos.w, projPos.z / projPos.w)
        
        // Convert from NDC (-1 to 1) to screen coordinates
        let screenX = (ndcPos.x + 1.0) * 0.5 * Float(arView.bounds.width)
        let screenY = (1.0 - ndcPos.y) * 0.5 * Float(arView.bounds.height)
        
        return CGPoint(x: CGFloat(screenX), y: CGFloat(screenY))
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
                guard let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity,
                      let currentMaterial = edgeEntity.model?.materials.first else { continue }
                let start = newWorldPositions[i]
                let end = newWorldPositions[j]
                let midpoint = (start + end) / 2
                let direction = end - start
                let length = simd_length(direction)
                let edgeMesh = MeshResource.generateCylinder(height: length, radius: 0.0005)
                edgeEntity.model = ModelComponent(mesh: edgeMesh, materials: [currentMaterial])
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
    }
    
    /// End edge movement and return the modified marker for persistence
    func endMoveSelectedEdge() -> (UUID, Int64, [SIMD3<Float>])? {
        return stopMovingMarker()
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
        // Rebuild all edges each update
        let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (i, j) in edgeIndices {
            if let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity,
               let currentMaterial = edgeEntity.model?.materials.first {
                let start = newNodePositions[i]
                let end = newNodePositions[j]
                let midpoint = (start + end) / 2
                let direction = end - start
                let length = simd_length(direction)
                let edgeMesh = MeshResource.generateCylinder(height: length, radius: 0.0005)
                edgeEntity.model = ModelComponent(mesh: edgeMesh, materials: [currentMaterial])
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
