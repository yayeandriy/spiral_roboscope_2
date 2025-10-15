//
//  SpatialMarkerService.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import ARKit
import RealityKit
import Combine

/// Manages spatial markers placed in AR
final class SpatialMarkerService: ObservableObject {
    weak var arView: ARView?
    
    @Published var markers: [SpatialMarker] = []
    
    struct SpatialMarker: Identifiable {
        let id = UUID()
        let nodes: [SIMD3<Float>] // 4 corner positions
        let anchorEntity: AnchorEntity
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
}
