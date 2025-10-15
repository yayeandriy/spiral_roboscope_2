//
//  ModelLoader.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import RealityKit
import Foundation
import simd

/// Loads USDZ via RealityKit, samples surface to point cloud
final class ModelLoader {
    
    func loadUSDZ(named: String, sampleVoxel: Float) async throws -> PointCloud {
        // Load the USDZ/USDC model from bundle
        guard let resourceURL = Bundle.main.url(forResource: named, withExtension: "usdc") else {
            throw NSError(domain: "ModelLoader", code: 0,
                         userInfo: [NSLocalizedDescriptionKey: "Could not find \(named).usdc in bundle"])
        }
        let entity = try await Entity.load(contentsOf: resourceURL)
        
        // Extract mesh and sample points
        var allPoints: [SIMD3<Float>] = []
        
        extractPoints(from: entity, into: &allPoints)
        
        guard !allPoints.isEmpty else {
            throw NSError(domain: "ModelLoader", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No geometry found in model"])
        }
        
        // Voxel downsample to target resolution
        let sampledPoints = voxelSample(allPoints, voxelSize: sampleVoxel)
        
        // Compute normals
        let normals = computeNormals(points: sampledPoints, neighborRadius: sampleVoxel * 3)
        
        // Compute bounds
        let bounds = computeBounds(sampledPoints)
        
        return PointCloud(
            points: sampledPoints.map { Point3F($0) },
            normals: normals.map { Normal3F($0) },
            voxelSize: sampleVoxel,
            boundsMin: bounds.min,
            boundsMax: bounds.max
        )
    }
    
    // MARK: - Extract Points from Entity
    
    private func extractPoints(from entity: Entity, into points: inout [SIMD3<Float>]) {
        // If entity has a mesh, extract vertices
        if let modelEntity = entity as? ModelEntity,
           let mesh = modelEntity.model?.mesh {
            let contents = mesh.contents
            
            // Extract positions from mesh
            if let positions = contents.models.first?.parts.first?.positions {
                for position in positions {
                    // Transform to world space
                    let worldPos = entity.transform.matrix * simd_float4(position, 1)
                    points.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
                }
            }
        }
        
        // Recursively process children
        for child in entity.children {
            extractPoints(from: child, into: &points)
        }
    }
    
    // MARK: - Voxel Sample
    
    private func voxelSample(_ points: [SIMD3<Float>], voxelSize: Float) -> [SIMD3<Float>] {
        struct VoxelKey: Hashable {
            let x, y, z: Int32
        }
        
        var voxelMap: [VoxelKey: (sum: SIMD3<Float>, count: Int)] = [:]
        
        for point in points {
            let key = VoxelKey(
                x: Int32(floor(point.x / voxelSize)),
                y: Int32(floor(point.y / voxelSize)),
                z: Int32(floor(point.z / voxelSize))
            )
            
            if let existing = voxelMap[key] {
                voxelMap[key] = (existing.sum + point, existing.count + 1)
            } else {
                voxelMap[key] = (point, 1)
            }
        }
        
        return voxelMap.values.map { $0.sum / Float($0.count) }
    }
    
    // MARK: - Compute Normals
    
    private func computeNormals(points: [SIMD3<Float>], neighborRadius: Float) -> [SIMD3<Float>] {
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(points.count)
        
        for point in points {
            // Find neighbors
            var neighbors: [SIMD3<Float>] = []
            for other in points {
                if distance(point, other) < neighborRadius {
                    neighbors.append(other)
                }
            }
            
            guard neighbors.count >= 3 else {
                normals.append(SIMD3<Float>(0, 1, 0)) // default up
                continue
            }
            
            // Simple normal estimation via cross product
            let d1 = normalize(neighbors[1] - neighbors[0])
            let d2 = normalize(neighbors[2] - neighbors[0])
            let normal = normalize(cross(d1, d2))
            normals.append(normal)
        }
        
        return normals
    }
    
    // MARK: - Compute Bounds
    
    private func computeBounds(_ points: [SIMD3<Float>]) -> (min: Point3F, max: Point3F) {
        guard !points.isEmpty else {
            return (Point3F(0, 0, 0), Point3F(0, 0, 0))
        }
        
        var minP = points[0]
        var maxP = points[0]
        
        for p in points {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        
        return (Point3F(minP), Point3F(maxP))
    }
}
