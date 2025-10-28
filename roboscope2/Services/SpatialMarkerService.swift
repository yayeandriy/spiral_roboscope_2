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

/// Manages spatial markers placed in AR
final class SpatialMarkerService: ObservableObject {
    weak var arView: ARView?
    
    @Published var markers: [SpatialMarker] = []
    
    // Tracking state
    @Published var markersInTarget: Set<UUID> = []
    @Published var selectedMarkerID: UUID?
    private var markerEdgesInTarget: [UUID: Set<Int>] = [:] // Stores which edges (0-3) are in target for each marker
    private var selectedEdgeIndex: Int? // Edge index (0-3) for currently selected marker
    
    // Frame dimensions support
    private let frameDimsService = FrameDimsService()
    var roomPlanes: [String: Plane]? = nil  // Set externally for room boundaries
    
    // Moving state
    private var movingMarkerIndex: Int?
    private var nodeScreenPositions: [CGPoint] = []
    private var updateCounter: Int = 0
    private var movingEdgeIndices: (Int, Int)?
    // Transform (move/resize) helpers
    private var originalNodeScreenPositions: [CGPoint] = []
    private var lastWorldNodePositions: [SIMD3<Float>] = []
    private var referenceCenterScreen: CGPoint = .zero
    
    struct SpatialMarker: Identifiable {
        let id = UUID()
        var backendId: UUID? = nil // Link to server-side marker
        var version: Int64 = 0 // Track marker version for optimistic locking
        var nodes: [SIMD3<Float>] // 4 corner positions (mutable for moving)
        let anchorEntity: AnchorEntity
        var isSelected: Bool = false
    }
    
    /// Create and add a marker from world-space points (used when loading from server)
    @discardableResult
    func addMarker(points: [SIMD3<Float>], backendId: UUID? = nil, version: Int64 = 0) -> SpatialMarker {
        guard let arView = arView else {
            print("AR view not available")
            return SpatialMarker(version: version, nodes: points, anchorEntity: AnchorEntity(world: .zero))
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
        let marker = SpatialMarker(backendId: backendId, version: version, nodes: points, anchorEntity: anchorEntity, isSelected: false)
        markers.append(marker)
        print("[Marker] Added id=\(marker.id) backendId=\(backendId?.uuidString ?? "nil") version=\(version) nodes=\(points)")
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
                applyNodePositions(markerIndex: idx, newNodePositions: m.points)
            } else {
                // Add new marker from backend
                addMarker(points: m.points, backendId: m.id, version: m.version)
            }
        }
    }
    
    /// Place a marker by raycasting from target corners
    func placeMarker(targetCorners: [CGPoint]) {
        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            print("AR view or frame not available")
            return
        }
        
        // First, raycast from the center to establish a reference plane and distance
        let screenCenter = CGPoint(
            x: (targetCorners[0].x + targetCorners[2].x) / 2,
            y: (targetCorners[0].y + targetCorners[2].y) / 2
        )
        
        guard let centerResult = arView.raycast(from: screenCenter, allowing: .estimatedPlane, alignment: .any).first else {
            print("No raycast hit at center")
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
                print("No raycast hit for corner: \(corner)")
                return
            }
        }
        
        // Need 4 hit points for a valid marker
        guard hitPoints.count == 4 else {
            print("Failed to get all 4 hit points")
            return
        }
        
        // Create spatial marker from computed points
        _ = addMarker(points: hitPoints)
        
        print("Marker placed with \(hitPoints.count) nodes")
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
    
    // MARK: - Marker Info
    
    struct MarkerInfo {
        let width: Float
        let length: Float
        let centerX: Float
        let centerZ: Float
        let frameDims: FrameDimsAggregate?      // Plane-based frame dimensions
        let meshFrameDims: FrameDimsAggregate?  // Mesh-based frame dimensions
    }
    
    /// Get info for the currently selected marker
    var selectedMarkerInfo: MarkerInfo? {
        guard let selectedID = selectedMarkerID,
              let marker = markers.first(where: { $0.id == selectedID }) else {
            return nil
        }
        
        let nodes = marker.nodes
        guard nodes.count == 4 else { return nil }
        
        // Calculate center (average of all 4 nodes)
        let center = (nodes[0] + nodes[1] + nodes[2] + nodes[3]) / 4.0
        
        // Calculate width and length
        // Assuming nodes are ordered: 0-1-2-3 forming a quadrilateral
        // Width: distance between edges 0-1 and 2-3 (average)
        // Length: distance between edges 1-2 and 3-0 (average)
        let edge01 = simd_distance(nodes[0], nodes[1])
        let edge23 = simd_distance(nodes[2], nodes[3])
        let width = (edge01 + edge23) / 2.0
        
        let edge12 = simd_distance(nodes[1], nodes[2])
        let edge30 = simd_distance(nodes[3], nodes[0])
        let length = (edge12 + edge30) / 2.0
        
        // Compute frame dimensions if room planes are available
        let frameDims = computeFrameDims(for: nodes)
        
        return MarkerInfo(
            width: width,
            length: length,
            centerX: center.x,
            centerZ: center.z,
            frameDims: frameDims?.aggregate,
            meshFrameDims: nil  // Computed separately in ARSessionView
        )
    }
    
    /// Compute frame dimensions for marker nodes
    func computeFrameDims(for nodes: [SIMD3<Float>]) -> FrameDimsResult? {
        // Use room planes if available, otherwise create default room
        let planes = roomPlanes ?? FrameDimsService.createDefaultRoomPlanes()
        
        // Build point map with stable IDs
        var pointsFO: [String: SIMD3<Float>] = [:]
        for (index, node) in nodes.enumerated() {
            pointsFO["p\(index + 1)"] = node
        }
        
        // Compute frame dimensions (no vertical projection for now)
        let result = frameDimsService.compute(
            pointsFO: pointsFO,
            planesFO: planes,
            verticalRaycast: nil
        )
        
        return result
    }
    
    /// Get frame dimensions result for a marker (to persist in custom_props)
    func getFrameDimsForPersistence(nodes: [SIMD3<Float>]) -> [String: Any]? {
        guard let result = computeFrameDims(for: nodes) else { return nil }
        
        // Encode to JSON
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(result)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json
        } catch {
            print("Failed to encode frame dims: \(error)")
            return nil
        }
    }
    
    // MARK: - Marker Tracking
    
    /// Continuously check which markers are in the target area
    func updateMarkersInTarget(targetRect: CGRect) {
        // If we are currently moving a marker/edge, do not change selection
        if movingMarkerIndex != nil {
            // Keep selection stable during move
            // print("[Select] Skip tracking while moving markerIndex=\(movingMarkerIndex!)")
            return
        }
        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            return
        }
        
        guard !markers.isEmpty else {
            return
        }
        
    var newMarkersInTarget = Set<UUID>()
    var newMarkerEdgesInTarget: [UUID: Set<Int>] = [:]

    // Add a small margin so selection is forgiving
    let expandedRect = targetRect.insetBy(dx: -10, dy: -10)
    let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        
        // Edge indices: 0:(0,1), 1:(1,2), 2:(2,3), 3:(3,0)
        let edgeNodePairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
        
        // For edge selection distance
        func edgeMidpointScreen(_ i: Int, _ j: Int, _ screenPositions: [CGPoint?]) -> CGPoint? {
            if let p1 = screenPositions[i], let p2 = screenPositions[j] {
                return CGPoint(x: (p1.x + p2.x)/2, y: (p1.y + p2.y)/2)
            }
            return nil
        }

        // Segment-rect intersection: true if either endpoint inside rect or segment crosses any rect edge
        func segmentIntersectsRect(p1: CGPoint, p2: CGPoint, rect: CGRect) -> Bool {
            if rect.contains(p1) || rect.contains(p2) { return true }
            let rMinX = rect.minX, rMaxX = rect.maxX, rMinY = rect.minY, rMaxY = rect.maxY
            let rTL = CGPoint(x: rMinX, y: rMinY)
            let rTR = CGPoint(x: rMaxX, y: rMinY)
            let rBR = CGPoint(x: rMaxX, y: rMaxY)
            let rBL = CGPoint(x: rMinX, y: rMaxY)
            func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
                return (c.y - a.y) * (b.x - a.x) > (b.y - a.y) * (c.x - a.x)
            }
            func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
                return ccw(a,c,d) != ccw(b,c,d) && ccw(a,b,c) != ccw(a,b,d)
            }
            // Check against 4 edges of the rect
            if segmentsIntersect(p1, p2, rTL, rTR) { return true }
            if segmentsIntersect(p1, p2, rTR, rBR) { return true }
            if segmentsIntersect(p1, p2, rBR, rBL) { return true }
            if segmentsIntersect(p1, p2, rBL, rTL) { return true }
            return false
        }

        for (markerIndex, marker) in markers.enumerated() {
            // Project all nodes to screen
            var screenPositions: [CGPoint?] = []
            for nodePos in marker.nodes {
                let screenPos = projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
                screenPositions.append(screenPos)
            }

            // Check which edges intersect the target rect (edge-based selection)
            var edgesInTarget = Set<Int>()
            for (edgeIndex, (n1, n2)) in edgeNodePairs.enumerated() {
                if let p1 = screenPositions[n1], let p2 = screenPositions[n2] {
                    if segmentIntersectsRect(p1: p1, p2: p2, rect: expandedRect) {
                        edgesInTarget.insert(edgeIndex)
                    }
                }
            }

            // Marker is in target if at least one edge intersects the target area
            if !edgesInTarget.isEmpty {
                let wasInTarget = markersInTarget.contains(marker.id)
                newMarkersInTarget.insert(marker.id)
                newMarkerEdgesInTarget[marker.id] = edgesInTarget
                
                // Update colors
                if !wasInTarget || markerEdgesInTarget[marker.id] != edgesInTarget {
                    updateMarkerColorWithEdges(index: markerIndex, isSelected: false, isInTarget: true, edgesInTarget: edgesInTarget)
                }
            } else {
                // If was in target but no longer, reset color
                if markersInTarget.contains(marker.id) {
                    updateMarkerColorWithEdges(index: markerIndex, isSelected: false, isInTarget: false, edgesInTarget: [])
                }
            }
        }
        
        markersInTarget = newMarkersInTarget
        markerEdgesInTarget = newMarkerEdgesInTarget

        // Auto-select marker if needed and choose edge
        if newMarkersInTarget.isEmpty {
            // No selection when nothing qualifies
            // Auto-deselect silently
            selectedMarkerID = nil
            selectedEdgeIndex = nil
            // Update visuals to non-selected
            for idx in markers.indices {
                updateMarkerColorWithEdges(index: idx, isSelected: false, isInTarget: false, edgesInTarget: [])
            }
            return
        }

        // Keep current selection if still valid; otherwise pick closest to center
        var selectedIndex: Int?
        if let selID = selectedMarkerID, let idx = markers.firstIndex(where: { $0.id == selID }), newMarkersInTarget.contains(selID) {
            selectedIndex = idx
        } else {
            var bestIdx: Int?
            var bestDist: CGFloat = .infinity
            for (i, m) in markers.enumerated() where newMarkersInTarget.contains(m.id) {
                // Center of marker in screen
                let worldCenter = m.nodes.reduce(SIMD3<Float>.zero, +) / Float(m.nodes.count)
                if let sp = projectWorldToScreen(worldPosition: worldCenter, frame: frame, arView: arView) {
                    let d = hypot(sp.x - targetCenter.x, sp.y - targetCenter.y)
                    if d < bestDist { bestDist = d; bestIdx = i }
                }
            }
            selectedIndex = bestIdx
            if let si = selectedIndex { selectedMarkerID = markers[si].id }
        }

        // Choose selected edge
        if let si = selectedIndex {
            let m = markers[si]
            // Recompute screen positions
            var screenPositions: [CGPoint?] = []
            for nodePos in m.nodes {
                let sp = projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
                screenPositions.append(sp)
            }
            let edges = markerEdgesInTarget[m.id] ?? []
            var choice: Int?
            var bestDist: CGFloat = .infinity
            if !edges.isEmpty {
                for e in edges {
                    let pair = edgeNodePairs[e]
                    if let mid = edgeMidpointScreen(pair.0, pair.1, screenPositions) {
                        let d = hypot(mid.x - targetCenter.x, mid.y - targetCenter.y)
                        if d < bestDist { bestDist = d; choice = e }
                    }
                }
            } else {
                // Fall back: pick the closest edge to center among all edges
                for e in 0..<4 {
                    let pair = edgeNodePairs[e]
                    if let mid = edgeMidpointScreen(pair.0, pair.1, screenPositions) {
                        let d = hypot(mid.x - targetCenter.x, mid.y - targetCenter.y)
                        if d < bestDist { bestDist = d; choice = e }
                    }
                }
            }
            selectedEdgeIndex = choice
        } else {
            selectedEdgeIndex = nil
        }

        // Update colors: selected marker shows selected edge red
        for i in markers.indices {
            let isSel = (selectedMarkerID == markers[i].id)
            let inTarget = newMarkersInTarget.contains(markers[i].id)
            let edges = markerEdgesInTarget[markers[i].id] ?? []
            updateMarkerColorWithEdges(index: i, isSelected: isSel, isInTarget: inTarget, edgesInTarget: edges)
        }
    }
    
    /// Select a marker that is in the target area
    func selectMarkerInTarget(targetRect: CGRect) {
        // Do not change selection during movement
        if movingMarkerIndex != nil { return }
        guard let arView = arView else { return }
        
        // Find markers in target
        let markersInTargetArray = markers.filter { markersInTarget.contains($0.id) }
        
        if markersInTargetArray.isEmpty {
            // Deselect all if nothing is in target
            var didDeselect = false
            for index in markers.indices {
                if markers[index].isSelected {
                    markers[index].isSelected = false
                    let isInTarget = markersInTarget.contains(markers[index].id)
                    let edgesInTarget = markerEdgesInTarget[markers[index].id] ?? []
                    updateMarkerColorWithEdges(index: index, isSelected: false, isInTarget: isInTarget, edgesInTarget: edgesInTarget)
                    didDeselect = true
                }
            }
            if didDeselect {
                selectedMarkerID = nil
                print("Deselected all markers (none in target)")
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            } else {
                print("No markers in target to select")
            }
            return
        }
        
        // Select the first one (or closest to center)
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        var closestMarker: SpatialMarker?
        var closestDistance: CGFloat = .infinity
        
        guard let frame = arView.session.currentFrame else { return }
        
        for marker in markersInTargetArray {
            // Calculate marker center
            let markerCenter = marker.nodes.reduce(SIMD3<Float>.zero, +) / Float(marker.nodes.count)
            
            if let screenPos = projectWorldToScreen(worldPosition: markerCenter, frame: frame, arView: arView) {
                let distance = hypot(screenPos.x - targetCenter.x, screenPos.y - targetCenter.y)
                if distance < closestDistance {
                    closestDistance = distance
                    closestMarker = marker
                }
            }
        }
        
        if let markerToSelect = closestMarker {
            // Deselect all markers first
            for index in markers.indices {
                markers[index].isSelected = false
                let isInTarget = markersInTarget.contains(markers[index].id)
                let edgesInTarget = markerEdgesInTarget[markers[index].id] ?? []
                updateMarkerColorWithEdges(index: index, isSelected: false, isInTarget: isInTarget, edgesInTarget: edgesInTarget)
            }
            
            // Select this marker
            if let index = markers.firstIndex(where: { $0.id == markerToSelect.id }) {
                markers[index].isSelected = true
                selectedMarkerID = markerToSelect.id
                updateMarkerColorWithEdges(index: index, isSelected: true, isInTarget: true, edgesInTarget: [])
                
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                print("✓ Selected marker INDEX \(index) with ID \(markerToSelect.id)")
            }
        }
    }
    
    /// Update marker color based on selection and target state
    private func updateMarkerColor(index: Int, isSelected: Bool, isInTarget: Bool = false) {
        updateMarkerColorWithEdges(index: index, isSelected: isSelected, isInTarget: isInTarget, edgesInTarget: [])
    }
    
    /// Update marker color with specific edges highlighted
    private func updateMarkerColorWithEdges(index: Int, isSelected: Bool, isInTarget: Bool, edgesInTarget: Set<Int>) {
        guard index < markers.count else { return }
        
        let marker = markers[index]
        let anchorEntity = marker.anchorEntity
        
        // Determine node color based on state
        let nodeColor: UIColor
        
        if isSelected {
            nodeColor = UIColor.systemBlue
        } else if isInTarget {
            nodeColor = UIColor.systemBlue
        } else {
            nodeColor = UIColor.black
        }
        
        // Update node colors
        for nodeIndex in 0..<4 {
            if let nodeEntity = anchorEntity.children.first(where: { $0.name == "node_\(nodeIndex)" }) as? ModelEntity {
                let nodeMaterial = UnlitMaterial(color: nodeColor)
                nodeEntity.model?.materials = [nodeMaterial]
            }
        }
        
        // Update edge colors: selected edge is RED; others blue when in target/selected, otherwise light blue
        let edgeNodePairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (edgeIndex, (i, j)) in edgeNodePairs.enumerated() {
            if let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity {
                let edgeColor: UIColor
                
                if isSelected, let selEdge = selectedEdgeIndex, markers[index].id == selectedMarkerID, edgeIndex == selEdge {
                    edgeColor = UIColor.systemRed
                } else if isSelected || isInTarget || edgesInTarget.contains(edgeIndex) {
                    // Selected marker or in-target markers/edges appear blue
                    edgeColor = UIColor.systemBlue
                } else {
                    // Default: light blue
                    edgeColor = UIColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
                }
                
                let edgeMaterial = UnlitMaterial(color: edgeColor)
                edgeEntity.model?.materials = [edgeMaterial]
            }
        }
    }
    
    // MARK: - Marker Moving
    
    /// Start moving the currently selected marker
    func startMovingSelectedMarker() -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame,
              let selectedID = selectedMarkerID,
              let markerIndex = markers.firstIndex(where: { $0.id == selectedID }) else {
            print("Cannot start moving: no selected marker or no AR frame. SelectedID: \(selectedMarkerID?.uuidString ?? "nil")")
            return false
        }
        
        let marker = markers[markerIndex]
        
        // Project all nodes to screen and store their positions
        nodeScreenPositions = marker.nodes.compactMap { nodePos in
            projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
        }
        
        if nodeScreenPositions.count == 4 {
            // Reset counters to avoid initial lag
            updateCounter = 0
            movingMarkerIndex = markerIndex
            return true
        } else {
            return false
        }
    }
    
    /// Check if any marker is in the target area and prepare to move it
    func startMovingMarkerInTarget(targetCorners: [CGPoint]) -> Bool {
        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            return false
        }
        
        // Calculate target center
        let targetCenter = CGPoint(
            x: (targetCorners[0].x + targetCorners[2].x) / 2,
            y: (targetCorners[0].y + targetCorners[2].y) / 2
        )
        
        // Find if any marker is near the target center
        for (index, marker) in markers.enumerated() {
            // Calculate marker center in world space
            let markerCenter = marker.nodes.reduce(SIMD3<Float>.zero, +) / Float(marker.nodes.count)
            
            // Project marker center to screen
            if let screenPos = projectWorldToScreen(worldPosition: markerCenter, frame: frame, arView: arView) {
                let distance = hypot(screenPos.x - targetCenter.x, screenPos.y - targetCenter.y)
                
                // If marker is within target area (75 points from center)
                if distance < 75 {
                    movingMarkerIndex = index
                    
                    // Project all nodes to screen and store their positions
                    nodeScreenPositions = marker.nodes.compactMap { nodePos in
                        projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
                    }
                    
                    if nodeScreenPositions.count == 4 {
                        print("Started moving marker \(index)")
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    /// Update the moving marker position based on current camera
    func updateMovingMarker() {
        guard let arView = arView,
              let markerIndex = movingMarkerIndex,
              markerIndex < markers.count,
              nodeScreenPositions.count == 4 else {
            return
        }
        // Raycast from stored screen positions (projected once on start)
        var newNodePositions: [SIMD3<Float>] = []
        for screenPos in nodeScreenPositions {
            let results = arView.raycast(from: screenPos, allowing: .estimatedPlane, alignment: .any)
            
            if let firstResult = results.first {
                let worldPosition = SIMD3<Float>(
                    firstResult.worldTransform.columns.3.x,
                    firstResult.worldTransform.columns.3.y,
                    firstResult.worldTransform.columns.3.z
                )
                newNodePositions.append(worldPosition)
            } else {
                // If any raycast fails, skip this update
                return
            }
        }
        
        // Update marker nodes
        guard newNodePositions.count == 4 else { 
            return 
        }
        applyNodePositions(markerIndex: markerIndex, newNodePositions: newNodePositions)
    }
    
    /// Stop moving the marker and return the modified marker for persistence
    /// - Returns: (backendId, version, updatedNodes) if a marker was being moved, nil otherwise
    func stopMovingMarker() -> (UUID, Int64, [SIMD3<Float>])? {
        defer {
            movingMarkerIndex = nil
            nodeScreenPositions.removeAll()
            originalNodeScreenPositions.removeAll()
            lastWorldNodePositions.removeAll()
            movingEdgeIndices = nil
            updateCounter = 0
        }
        
        guard let idx = movingMarkerIndex, idx < markers.count else {
            return nil
        }
        
        let marker = markers[idx]
        guard let backendId = marker.backendId else {
            return nil
        }
        
        // Increment version for optimistic locking
        markers[idx].version += 1
        
        return (backendId, marker.version, marker.nodes)
    }
    
    /// Project a world position to screen coordinates
    private func projectWorldToScreen(worldPosition: SIMD3<Float>, frame: ARFrame, arView: ARView) -> CGPoint? {
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
            print("Cannot start transform: no selected marker or no AR frame.")
            return false
        }

        let marker = markers[markerIndex]
        // Project all nodes to screen and store their positions
        let screenPts = marker.nodes.compactMap { projectWorldToScreen(worldPosition: $0, frame: frame, arView: arView) }
        guard screenPts.count == 4 else {
            print("Start transform failed: could not project all nodes")
            return false
        }
        originalNodeScreenPositions = screenPts
        nodeScreenPositions = screenPts
        lastWorldNodePositions = marker.nodes
        referenceCenterScreen = referenceCenter
        movingMarkerIndex = markerIndex
        updateCounter = 0
        print("✓ Transform ready for marker index: \(markerIndex)")
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
    fileprivate func applyNodePositions(markerIndex: Int, newNodePositions: [SIMD3<Float>]) {
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
