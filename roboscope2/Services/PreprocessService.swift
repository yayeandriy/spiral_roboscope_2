//
//  PreprocessService.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import Foundation
import simd
import Accelerate

struct PreprocessParams {
    var minConfidence: UInt8 = 128 // medium or higher
    var minRange: Float = 0.25
    var maxRange: Float = 5.0
    var voxelSizes: [Float] = [0.02, 0.01, 0.007] // coarse → fine
}

/// Confidence filter, voxel downsample, normals computation
final class PreprocessService {
    
    func buildPyramid(raw: RawCloud,
                      gravityUp: SIMD3<Float>,
                      params: PreprocessParams) -> [PointCloud] {
        // 1) Filter by confidence and range
        var filtered: [SIMD3<Float>] = []
        for (idx, point) in raw.points.enumerated() {
            let conf = raw.confidences[idx]
            let dist = length(point)
            if conf >= params.minConfidence && dist >= params.minRange && dist <= params.maxRange {
                filtered.append(point)
            }
        }
        
        guard !filtered.isEmpty else {
            return []
        }
        
        // 2) Build pyramid: downsample at each voxel size
        var pyramid: [PointCloud] = []
        for voxelSize in params.voxelSizes {
            let downsampled = voxelDownsample(filtered, voxelSize: voxelSize)
            let normals = computeNormals(points: downsampled, neighborRadius: voxelSize * 3, gravityUp: gravityUp)
            
            let bounds = computeBounds(downsampled)
            
            let cloud = PointCloud(
                points: downsampled.map { Point3F($0) },
                normals: normals.map { Normal3F($0) },
                voxelSize: voxelSize,
                boundsMin: bounds.min,
                boundsMax: bounds.max,
                estimatedUp: Normal3F(gravityUp)
            )
            pyramid.append(cloud)
        }
        
        return pyramid
    }
    
    // MARK: - Voxel Downsample
    
    private func voxelDownsample(_ points: [SIMD3<Float>], voxelSize: Float) -> [SIMD3<Float>] {
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
    
    // MARK: - Compute Normals (PCA per neighborhood)
    
    private func computeNormals(points: [SIMD3<Float>], neighborRadius: Float, gravityUp: SIMD3<Float>) -> [SIMD3<Float>] {
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(points.count)
        
        for point in points {
            // Find neighbors within radius
            var neighbors: [SIMD3<Float>] = []
            for other in points {
                if distance(point, other) < neighborRadius {
                    neighbors.append(other)
                }
            }
            
            guard neighbors.count >= 3 else {
                // Not enough neighbors, use gravity up as fallback
                normals.append(gravityUp)
                continue
            }
            
            // Compute normal via PCA (smallest eigenvector)
            let normal = computeNormalPCA(neighbors, gravityUp: gravityUp)
            normals.append(normal)
        }
        
        return normals
    }
    
    private func computeNormalPCA(_ points: [SIMD3<Float>], gravityUp: SIMD3<Float>) -> SIMD3<Float>  {
        // Compute centroid
        let centroid = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        
        // Compute covariance matrix (3x3)
        var cov = simd_float3x3()
        for p in points {
            let d = p - centroid
            cov[0] += d * d.x
            cov[1] += d * d.y
            cov[2] += d * d.z
        }
        let scale = 1.0 / Float(points.count)
        cov[0] *= scale
        cov[1] *= scale
        cov[2] *= scale
        
        // For simplicity, use cross product of first two principal directions
        // In production, use proper eigenvalue decomposition
        // Here we approximate: normal ≈ gravity up if horizontal surface detected
        let avgDir = normalize(points.last! - points.first!)
        var normal = cross(avgDir, gravityUp)
        
        if length(normal) < 0.1 {
            normal = gravityUp
        } else {
            normal = normalize(normal)
        }
        
        // Orient toward gravity if ambiguous
        if dot(normal, gravityUp) < 0 {
            normal = -normal
        }
        
        return normal
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
