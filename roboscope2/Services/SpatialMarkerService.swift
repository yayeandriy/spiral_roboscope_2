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
    
    // Moving state
    private var movingMarkerIndex: Int?
    private var nodeScreenPositions: [CGPoint] = []
    
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
            print("updateMarkersInTarget: No arView or frame")
            return
        }
        
        guard !markers.isEmpty else {
            return
        }
        
        var newMarkersInTarget = Set<UUID>()
        
        for (markerIndex, marker) in markers.enumerated() {
            // Check if any node of this marker is within the target rect
            var nodesInTarget = 0
            var screenPositions: [CGPoint] = []
            
            for (nodeIndex, nodePos) in marker.nodes.enumerated() {
                if let screenPos = projectWorldToScreen(worldPosition: nodePos, frame: frame, arView: arView) {
                    screenPositions.append(screenPos)
                    
                    let isInTarget = targetRect.contains(screenPos)
                    if isInTarget {
                        nodesInTarget += 1
                    }
                    
                    // Debug every 30 frames (roughly every 3 seconds at 10fps tracking)
                    if markerIndex == 0 && nodeIndex == 0 {
                        let frameCount = Int(Date().timeIntervalSince1970 * 10) % 30
                        if frameCount == 0 {
                            print("Target rect: \(targetRect)")
                            print("Node \(nodeIndex) world: \(nodePos), screen: \(screenPos), inTarget: \(isInTarget)")
                        }
                    }
                }
            }
            
            // If at least 2 nodes are in target, consider the marker "in target"
            if nodesInTarget >= 2 {
                let wasInTarget = markersInTarget.contains(marker.id)
                newMarkersInTarget.insert(marker.id)
                
                // Update color to blue if newly entered target
                if !wasInTarget {
                    print("✓ Marker \(markerIndex) ENTERED TARGET (\(nodesInTarget)/4 nodes)")
                    updateMarkerColor(index: markerIndex, isSelected: false, isInTarget: true)
                }
            } else {
                // If was in target but no longer, reset color
                if markersInTarget.contains(marker.id) {
                    print("✗ Marker \(markerIndex) LEFT TARGET")
                    updateMarkerColor(index: markerIndex, isSelected: false, isInTarget: false)
                }
            }
        }
        
        markersInTarget = newMarkersInTarget
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
                updateMarkerColor(index: index, isSelected: false, isInTarget: isInTarget)
            }
            
            // Select this marker
            if let index = markers.firstIndex(where: { $0.id == markerToSelect.id }) {
                markers[index].isSelected = true
                selectedMarkerID = markerToSelect.id
                updateMarkerColor(index: index, isSelected: true, isInTarget: true)
                
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                print("✓ Selected marker INDEX \(index) with ID \(markerToSelect.id)")
            }
        }
    }
    
    /// Update marker color based on selection and target state
    private func updateMarkerColor(index: Int, isSelected: Bool, isInTarget: Bool = false) {
        guard index < markers.count else { return }
        
        let marker = markers[index]
        let anchorEntity = marker.anchorEntity
        
        // Determine colors based on state
        let nodeColor: UIColor
        let edgeColor: UIColor
        
        if isSelected {
            // Selected: bright blue for both
            nodeColor = UIColor.systemBlue
            edgeColor = UIColor.systemBlue
        } else if isInTarget {
            // In target: blue nodes and edges
            nodeColor = UIColor.systemBlue
            edgeColor = UIColor.systemBlue
        } else {
            // Default: black nodes, light blue edges
            nodeColor = UIColor.black
            edgeColor = UIColor(red: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
        }
        
        // Update node colors
        for nodeIndex in 0..<4 {
            if let nodeEntity = anchorEntity.children.first(where: { $0.name == "node_\(nodeIndex)" }) as? ModelEntity {
                var nodeMaterial = UnlitMaterial(color: nodeColor)
                nodeEntity.model?.materials = [nodeMaterial]
            }
        }
        
        // Update edge colors
        let edgeIndices = [(0, 1), (1, 2), (2, 3), (3, 0)]
        for (i, j) in edgeIndices {
            if let edgeEntity = anchorEntity.children.first(where: { $0.name == "edge_\(i)_\(j)" }) as? ModelEntity {
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
            print("updateMovingMarker: Guard failed - arView: \(arView != nil), markerIndex: \(movingMarkerIndex), positions: \(nodeScreenPositions.count)")
            return
        }
        
        // Raycast from stored screen positions to update node positions
        var newNodePositions: [SIMD3<Float>] = []
        var failedRaycasts = 0
        
        for (idx, screenPos) in nodeScreenPositions.enumerated() {
            let results = arView.raycast(from: screenPos, allowing: .estimatedPlane, alignment: .any)
            
            if let firstResult = results.first {
                let worldPosition = SIMD3<Float>(
                    firstResult.worldTransform.columns.3.x,
                    firstResult.worldTransform.columns.3.y,
                    firstResult.worldTransform.columns.3.z
                )
                newNodePositions.append(worldPosition)
            } else {
                // If any raycast fails, don't update but log it
                failedRaycasts += 1
                if failedRaycasts == 1 {
                    print("Raycast failed for node \(idx) at screen pos \(screenPos)")
                }
                return
            }
        }
        
        // Update marker nodes
        guard newNodePositions.count == 4 else { 
            print("Not enough positions: \(newNodePositions.count)")
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
        
        // Update edge entities
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
        
        print("Updated marker positions")
    }
    
    /// Stop moving the marker
    func stopMovingMarker() {
        movingMarkerIndex = nil
        nodeScreenPositions.removeAll()
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
