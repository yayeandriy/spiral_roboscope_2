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
    
    // Moving state
    private var movingMarkerIndex: Int?
    private var nodeScreenPositions: [CGPoint] = []
    private var updateCounter: Int = 0
    
    struct SpatialMarker: Identifiable {
        let id = UUID()
        var nodes: [SIMD3<Float>] // 4 corner positions (mutable for moving)
        let anchorEntity: AnchorEntity
        var isSelected: Bool = false
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
        
        // Calculate the reference distance from camera to center
        let referenceDistance = simd_distance(cameraPosition, centerPosition)
        
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
        
        // Create marker entity
        let anchorEntity = AnchorEntity(world: .zero)
        
        // Create nodes (black spheres, radius 1cm - 2x smaller) with flat material
        for (index, position) in hitPoints.enumerated() {
            let nodeMesh = MeshResource.generateSphere(radius: 0.01) // 1cm
            var nodeMaterial = UnlitMaterial(color: .black)
            let nodeEntity = ModelEntity(mesh: nodeMesh, materials: [nodeMaterial])
            nodeEntity.position = position
            nodeEntity.name = "node_\(index)"
            anchorEntity.addChild(nodeEntity)
        }
        
        // Create edges (white cylinders connecting nodes, radius 0.33cm - 3x smaller)
        let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)] // Connect in perimeter
        
        for (i, j) in edgeIndices {
            let start = hitPoints[i]
            let end = hitPoints[j]
            
            // Calculate edge properties
            let midpoint = (start + end) / 2
            let direction = end - start
            let length = simd_length(direction)
            
            // Create cylinder (radius 0.0005m = 0.5mm - very thin) with flat light blue material
            let edgeMesh = MeshResource.generateCylinder(height: length, radius: 0.0005)
            var edgeMaterial = UnlitMaterial(color: UIColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0))
            let edgeEntity = ModelEntity(mesh: edgeMesh, materials: [edgeMaterial])
            
            // Position and orient the cylinder
            edgeEntity.position = midpoint
            
            // Orient cylinder to point from start to end
            let up = normalize(direction)
            let defaultUp = SIMD3<Float>(0, 1, 0)
            
            // Calculate rotation to align cylinder
            if simd_length(cross(defaultUp, up)) > 0.001 {
                let axis = normalize(cross(defaultUp, up))
                let angle = acos(dot(defaultUp, up))
                edgeEntity.orientation = simd_quatf(angle: angle, axis: axis)
            }
            
            edgeEntity.name = "edge_\(i)_\(j)"
            anchorEntity.addChild(edgeEntity)
        }
        
        // Add anchor to scene
        arView.scene.addAnchor(anchorEntity)
        
        // Save marker
        let marker = SpatialMarker(nodes: hitPoints, anchorEntity: anchorEntity)
        markers.append(marker)
        
        print("Marker placed with \(hitPoints.count) nodes")
    }
    
    /// Clear all markers
    func clearMarkers() {
        guard let arView = arView else { return }
        
        for marker in markers {
            arView.scene.removeAnchor(marker.anchorEntity)
        }
        
        markers.removeAll()
    }
    
    // MARK: - Marker Tracking
    
    /// Continuously check which markers are in the target area
    func updateMarkersInTarget(targetRect: CGRect) {
        guard let arView = arView,
              let frame = arView.session.currentFrame else {
            return
        }
        
        guard !markers.isEmpty else {
            return
        }
        
        var newMarkersInTarget = Set<UUID>()
        var newMarkerEdgesInTarget: [UUID: Set<Int>] = [:]
        
        // Edge indices: 0:(0,1), 1:(1,2), 2:(2,3), 3:(3,0)
        let edgeNodePairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
        
        for (markerIndex, marker) in markers.enumerated() {
            // Project all nodes to screen
            var screenPositions: [CGPoint?] = []
            
            for nodePos in marker.nodes {
                let screenPos = projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
                screenPositions.append(screenPos)
            }
            
            // Check which edges have both nodes in target
            var edgesInTarget = Set<Int>()
            
            for (edgeIndex, (node1, node2)) in edgeNodePairs.enumerated() {
                if let pos1 = screenPositions[node1],
                   let pos2 = screenPositions[node2] {
                    let node1InTarget = targetRect.contains(pos1)
                    let node2InTarget = targetRect.contains(pos2)
                    
                    // Edge is in target if both its nodes are in target
                    if node1InTarget && node2InTarget {
                        edgesInTarget.insert(edgeIndex)
                    }
                }
            }
            
            // Marker is in target if at least one edge (2 connected nodes) is in target
            if !edgesInTarget.isEmpty {
                let wasInTarget = markersInTarget.contains(marker.id)
                newMarkersInTarget.insert(marker.id)
                newMarkerEdgesInTarget[marker.id] = edgesInTarget
                
                // Update colors
                if !wasInTarget || markerEdgesInTarget[marker.id] != edgesInTarget {
                    print("✓ Marker \(markerIndex) IN TARGET - Edges: \(edgesInTarget)")
                    updateMarkerColorWithEdges(index: markerIndex, isSelected: false, isInTarget: true, edgesInTarget: edgesInTarget)
                }
            } else {
                // If was in target but no longer, reset color
                if markersInTarget.contains(marker.id) {
                    print("✗ Marker \(markerIndex) LEFT TARGET")
                    updateMarkerColorWithEdges(index: markerIndex, isSelected: false, isInTarget: false, edgesInTarget: [])
                }
            }
        }
        
        markersInTarget = newMarkersInTarget
        markerEdgesInTarget = newMarkerEdgesInTarget
    }
    
    /// Select a marker that is in the target area
    func selectMarkerInTarget(targetRect: CGRect) {
        guard let arView = arView else { return }
        
        // Find markers in target
        let markersInTargetArray = markers.filter { markersInTarget.contains($0.id) }
        
        if markersInTargetArray.isEmpty {
            print("No markers in target to select")
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
                var nodeMaterial = UnlitMaterial(color: nodeColor)
                nodeEntity.model?.materials = [nodeMaterial]
            }
        }
        
        // Update edge colors - highlight edges in target with RED
        let edgeNodePairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (edgeIndex, (i, j)) in edgeNodePairs.enumerated() {
            if let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity {
                let edgeColor: UIColor
                
                if isSelected {
                    edgeColor = UIColor.systemBlue
                } else if edgesInTarget.contains(edgeIndex) {
                    // Highlight edges in target with RED
                    edgeColor = UIColor.systemRed
                } else if isInTarget {
                    // Other edges when marker is in target - blue
                    edgeColor = UIColor.systemBlue
                } else {
                    // Default: light blue
                    edgeColor = UIColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
                }
                
                var edgeMaterial = UnlitMaterial(color: edgeColor)
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
        
        print("Attempting to move marker \(markerIndex) (ID: \(selectedID))")
        
        let marker = markers[markerIndex]
        
        // Project all nodes to screen and store their positions
        nodeScreenPositions = marker.nodes.compactMap { nodePos in
            projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView)
        }
        
        if nodeScreenPositions.count == 4 {
            movingMarkerIndex = markerIndex
            print("✓ Started moving marker \(markerIndex) (ID: \(selectedID)) with screen positions: \(nodeScreenPositions)")
            return true
        } else {
            print("Failed to project all nodes to screen")
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
        
        updateCounter += 1
        
        // Only do full raycast every 2 frames to reduce load
        guard updateCounter % 2 == 0 else {
            return
        }
        
        // Raycast from stored screen positions to update node positions
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
        
        markers[markerIndex].nodes = newNodePositions
        
        // Update node entities positions
        let anchorEntity = markers[markerIndex].anchorEntity
        for (index, newPosition) in newNodePositions.enumerated() {
            if let nodeEntity = anchorEntity.children.first(where: { $0.name == "node_\(index)" }) as? ModelEntity {
                nodeEntity.position = newPosition
            }
        }
        
        // Update edge entities (only every 3rd update to reduce CPU load)
        if updateCounter % 6 == 0 {
            let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)]
            for (i, j) in edgeIndices {
                guard let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity,
                      let currentMaterial = edgeEntity.model?.materials.first else {
                    continue
                }
                
                let start = newNodePositions[i]
                let end = newNodePositions[j]
                
                let midpoint = (start + end) / 2
                let direction = end - start
                let length = simd_length(direction)
                
                // Recreate mesh with new length
                let edgeMesh = MeshResource.generateCylinder(height: length, radius: 0.0005)
                edgeEntity.model = ModelComponent(mesh: edgeMesh, materials: [currentMaterial])
                
                // Update position
                edgeEntity.position = midpoint
                
                // Update orientation
                let up = normalize(direction)
                let defaultUp = SIMD3<Float>(0, 1, 0)
                
                let dotProduct = dot(defaultUp, up)
                if abs(dotProduct) < 0.999 { // Not parallel
                    let axis = normalize(cross(defaultUp, up))
                    let angle = acos(max(-1, min(1, dotProduct))) // Clamp to avoid NaN
                    edgeEntity.orientation = simd_quatf(angle: angle, axis: axis)
                } else if dotProduct < 0 {
                    // Pointing down, rotate 180 degrees
                    edgeEntity.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
                }
            }
        }
    }
    
    /// Stop moving the marker
    func stopMovingMarker() {
        movingMarkerIndex = nil
        nodeScreenPositions.removeAll()
        updateCounter = 0
        print("Stopped moving marker")
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
