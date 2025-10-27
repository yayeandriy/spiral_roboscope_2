//
//  FrameDimsService.swift
//  roboscope2
//
//  Service for computing marker frame dimensions
//  See docs/MARKER_FRAME_DIMS.ms for specification
//

import Foundation
import simd
import RealityKit
import Accelerate

/// Protocol for computing frame dimensions
protocol FrameDimsComputing {
    func compute(
        pointsFO: [String: SIMD3<Float>],
        planesFO: [String: Plane],
        verticalRaycast: ((SIMD3<Float>) -> SIMD3<Float>?)?
    ) -> FrameDimsResult
}

/// Service to compute marker frame dimensions relative to reference model boundaries
class FrameDimsService: FrameDimsComputing {
    
    // MARK: - Main Computation
    
    /// Compute frame dimensions for a set of points in FrameOrigin coordinates
    func compute(
        pointsFO: [String: SIMD3<Float>],
        planesFO: [String: Plane],
        verticalRaycast: ((SIMD3<Float>) -> SIMD3<Float>?)? = nil
    ) -> FrameDimsResult {
        
        // 1) Compute per-edge, per-point distances
        var perEdge: [String: EdgeDistances] = [:]
        let edgeKeys = ["left", "right", "near", "far", "top", "bottom"]
        
        for edgeKey in edgeKeys {
            guard let plane = planesFO[edgeKey] else {
                // If plane missing, use zero distances
                perEdge[edgeKey] = EdgeDistances(perPoint: [:])
                continue
            }
            
            var distances: [String: Float] = [:]
            for (pointId, point) in pointsFO {
                distances[pointId] = plane.distance(to: point)
            }
            perEdge[edgeKey] = EdgeDistances(perPoint: distances)
        }
        
        // 2) Compute aggregated minimal distances
        let aggregate = FrameDimsAggregate(
            left: minDistance(from: perEdge["left"]),
            right: minDistance(from: perEdge["right"]),
            near: minDistance(from: perEdge["near"]),
            far: minDistance(from: perEdge["far"]),
            top: minDistance(from: perEdge["top"]),
            bottom: minDistance(from: perEdge["bottom"])
        )
        
        // 3) Compute size metrics (AABB and OBB)
        let points = Array(pointsFO.values)
        let aabb = computeAABB(points: points)
        let obb = computeOBB(points: points)
        let sizes = FrameDimsSizes(aabb: aabb, obb: obb)
        
        // 4) Compute projected dimensions (if raycast provided)
        var projected: FrameDimsProjected? = nil
        if let raycast = verticalRaycast {
            let projectedPoints = points.compactMap { raycast($0) }
            if !projectedPoints.isEmpty {
                let projAABB = computeAABB(points: projectedPoints)
                let projOBB = computeOBB(points: projectedPoints)
                projected = FrameDimsProjected(aabb: projAABB, obb: projOBB)
            } else {
                projected = FrameDimsProjected(aabb: nil, obb: nil)
            }
        }
        
        // 5) Build result
        return FrameDimsResult(
            perEdge: perEdge,
            aggregate: aggregate,
            sizes: sizes,
            projected: projected,
            meta: FrameDimsMeta(
                notes: "Computed from \(pointsFO.count) points in FrameOrigin coordinates"
            )
        )
    }
    
    // MARK: - Helper Functions
    
    private func minDistance(from edgeDistances: EdgeDistances?) -> Float {
        guard let distances = edgeDistances?.perPoint.values, !distances.isEmpty else {
            return 0.0
        }
        return distances.min() ?? 0.0
    }
    
    /// Compute Axis-Aligned Bounding Box
    private func computeAABB(points: [SIMD3<Float>]) -> AABB {
        guard !points.isEmpty else {
            return AABB(min: .zero, max: .zero)
        }
        
        var minPoint = points[0]
        var maxPoint = points[0]
        
        for point in points {
            minPoint.x = min(minPoint.x, point.x)
            minPoint.y = min(minPoint.y, point.y)
            minPoint.z = min(minPoint.z, point.z)
            
            maxPoint.x = max(maxPoint.x, point.x)
            maxPoint.y = max(maxPoint.y, point.y)
            maxPoint.z = max(maxPoint.z, point.z)
        }
        
        return AABB(min: minPoint, max: maxPoint)
    }
    
    /// Compute Oriented Bounding Box using PCA
    private func computeOBB(points: [SIMD3<Float>]) -> OBB {
        guard points.count >= 3 else {
            // Degenerate case: fall back to AABB-based OBB
            let aabb = computeAABB(points: points)
            let center = (aabb.min + aabb.max) / 2
            let extents = (aabb.max - aabb.min) / 2
            return OBB(center: center, axes: matrix_identity_float3x3, extents: extents)
        }
        
        // 1. Compute centroid
        let centroid = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        
        // 2. Center the points
        let centered = points.map { $0 - centroid }
        
        // 3. Compute covariance matrix (3x3)
        var cov = simd_float3x3()
        for p in centered {
            // Outer product contribution
            cov[0] += p * p.x  // First column
            cov[1] += p * p.y  // Second column
            cov[2] += p * p.z  // Third column
        }
        let scale = 1.0 / Float(points.count)
        cov[0] *= scale
        cov[1] *= scale
        cov[2] *= scale
        
        // 4. Compute eigenvectors and eigenvalues using Accelerate
        let (eigenvalues, eigenvectors) = computeEigen(matrix: cov)
        
        // 5. Sort by eigenvalues (descending) to get principal components
        var indexed = zip(eigenvalues.indices, eigenvalues).sorted { $0.1 > $1.1 }
        
        // Build axes matrix from sorted eigenvectors (columns = principal directions)
        let axes = simd_float3x3(
            columns: (
                eigenvectors[indexed[0].0],
                eigenvectors[indexed[1].0],
                eigenvectors[indexed[2].0]
            )
        )
        
        // 6. Project centered points onto principal axes to find extents
        var minProj = SIMD3<Float>(repeating: .infinity)
        var maxProj = SIMD3<Float>(repeating: -.infinity)
        
        for p in centered {
            let proj = SIMD3<Float>(
                simd_dot(axes.columns.0, p),
                simd_dot(axes.columns.1, p),
                simd_dot(axes.columns.2, p)
            )
            minProj = simd_min(minProj, proj)
            maxProj = simd_max(maxProj, proj)
        }
        
        let extents = (maxProj - minProj) / 2
        
        return OBB(center: centroid, axes: axes, extents: extents)
    }
    
    /// Compute eigenvalues and eigenvectors of a 3x3 symmetric matrix using Accelerate
    private func computeEigen(matrix: simd_float3x3) -> (eigenvalues: [Float], eigenvectors: [SIMD3<Float>]) {
        // Convert to column-major array for LAPACK
        var a: [Float] = [
            matrix[0][0], matrix[1][0], matrix[2][0],  // Column 0
            matrix[0][1], matrix[1][1], matrix[2][1],  // Column 1
            matrix[0][2], matrix[1][2], matrix[2][2]   // Column 2
        ]
        
        var n: __CLPK_integer = 3
        var lda: __CLPK_integer = 3
        var w = [Float](repeating: 0, count: 3)  // Eigenvalues
        var work = [Float](repeating: 0, count: 9)
        var lwork: __CLPK_integer = 9
        var info: __CLPK_integer = 0
        var jobz: Int8 = 86  // 'V' = compute eigenvectors
        var uplo: Int8 = 85  // 'U' = upper triangle
        
        // Call LAPACK's ssyev to compute eigenvalues and eigenvectors
        ssyev_(&jobz, &uplo, &n, &a, &lda, &w, &work, &lwork, &info)
        
        if info != 0 {
            print("Warning: Eigen decomposition failed with info=\(info)")
            // Fall back to identity
            return (
                eigenvalues: [1, 1, 1],
                eigenvectors: [
                    SIMD3<Float>(1, 0, 0),
                    SIMD3<Float>(0, 1, 0),
                    SIMD3<Float>(0, 0, 1)
                ]
            )
        }
        
        // Extract eigenvectors (stored column-major in a)
        let v1 = SIMD3<Float>(a[0], a[1], a[2])
        let v2 = SIMD3<Float>(a[3], a[4], a[5])
        let v3 = SIMD3<Float>(a[6], a[7], a[8])
        
        return (eigenvalues: [w[0], w[1], w[2]], eigenvectors: [v1, v2, v3])
    }
    
    // MARK: - Default Room Planes
    
    /// Create default room planes based on a bounding box
    /// Assumes room is axis-aligned in FrameOrigin coordinates
    static func createRoomPlanes(boundingBox: AABB) -> [String: Plane] {
        return [
            "left":   Plane(n: SIMD3<Float>( 1, 0, 0), d: -boundingBox.min.x),
            "right":  Plane(n: SIMD3<Float>(-1, 0, 0), d:  boundingBox.max.x),
            "near":   Plane(n: SIMD3<Float>( 0, 0, 1), d: -boundingBox.min.z),
            "far":    Plane(n: SIMD3<Float>( 0, 0,-1), d:  boundingBox.max.z),
            "top":    Plane(n: SIMD3<Float>( 0, 1, 0), d: -boundingBox.min.y),
            "bottom": Plane(n: SIMD3<Float>( 0,-1, 0), d:  boundingBox.max.y)
        ]
    }
    
    /// Create default room planes for a typical room (3m x 4m x 2.5m)
    static func createDefaultRoomPlanes() -> [String: Plane] {
        // Room centered at origin, 3m wide (x), 2.5m tall (y), 4m deep (z)
        return [
            "left":   Plane(n: SIMD3<Float>( 1, 0, 0), d:  1.5),  // Wall at x = -1.5
            "right":  Plane(n: SIMD3<Float>(-1, 0, 0), d:  1.5),  // Wall at x = +1.5
            "near":   Plane(n: SIMD3<Float>( 0, 0, 1), d:  2.0),  // Wall at z = -2.0
            "far":    Plane(n: SIMD3<Float>( 0, 0,-1), d:  2.0),  // Wall at z = +2.0
            "top":    Plane(n: SIMD3<Float>( 0, 1, 0), d:  1.25), // Ceiling at y = -1.25
            "bottom": Plane(n: SIMD3<Float>( 0,-1, 0), d:  1.25)  // Floor at y = +1.25
        ]
    }
}
