//
//  MeshFrameDimsService.swift
//  roboscope2
//
//  Enhanced mesh-based frame dimensions computation for complex surfaces
//  Uses surface tracing instead of simple raycasting
//

import Foundation
import simd
import RealityKit
import SceneKit

/// Enhanced service for computing frame dimensions on complex meshes
class MeshFrameDimsService {
    
    // MARK: - Mesh-based Computation
    
    /// Compute frame dimensions using surface tracing
    /// Algorithm:
    /// 1. Project each marker point onto surface along Y-axis
    /// 2. From projected point, trace along surface in small steps until edge
    /// 3. Sum distances between traced surface points = actual surface path length
    func computeWithMesh(
        pointsFO: [String: SIMD3<Float>],
        meshNode: SCNNode,
        directions: [String: SIMD3<Float>] = defaultDirections()
    ) -> FrameDimsResult {
        
        // Get model bounding box for safe Y values
        let modelBounds = meshNode.boundingBox
        let modelMin = SIMD3<Float>(modelBounds.min.x, modelBounds.min.y, modelBounds.min.z)
        let modelMax = SIMD3<Float>(modelBounds.max.x, modelBounds.max.y, modelBounds.max.z)
        let modelSize = modelMax - modelMin
        
        let safeYHigh = modelMax.y + 10.0  // 10m above highest point
        
        print("[MeshFrameDims] Model bounds: \(modelMin) to \(modelMax)")
        print("[MeshFrameDims] Model size: \(modelSize)")
        
        // STEP 1: Project each point onto surface along Y-axis
        var projectedPoints: [String: SIMD3<Float>] = [:]
        
        for (pointId, point) in pointsFO {
            if let surfacePoint = projectPointOntoSurface(point: point, mesh: meshNode) {
                projectedPoints[pointId] = surfacePoint
                print("[MeshFrameDims] ✅ \(pointId) projected: \(point) → \(surfacePoint)")
            } else {
                print("[MeshFrameDims] ⚠️ \(pointId) could not be projected onto surface, skipping")
            }
        }
        
        guard !projectedPoints.isEmpty else {
            print("[MeshFrameDims] ❌ No points could be projected, returning default")
            return createDefaultResult(pointsFO: pointsFO)
        }
        
        // STEP 2: Trace along surface for each direction
        var perEdge: [String: EdgeDistances] = [:]
        
        // LEFT: trace in -X direction
        var leftDistances: [String: Float] = [:]
        for (pointId, surfacePoint) in projectedPoints {
            let delta = modelSize.x * 0.01  // 1% of model width
            let distance = traceSurfaceDistance(
                from: surfacePoint,
                direction: SIMD3<Float>(-delta, 0, 0),  // -X
                safeYHigh: safeYHigh,
                mesh: meshNode
            )
            leftDistances[pointId] = distance
            print("[MeshFrameDims] LEFT from \(pointId): \(distance)m")
        }
        perEdge["left"] = EdgeDistances(perPoint: leftDistances)
        
        // RIGHT: trace in +X direction
        var rightDistances: [String: Float] = [:]
        for (pointId, surfacePoint) in projectedPoints {
            let delta = modelSize.x * 0.01
            let distance = traceSurfaceDistance(
                from: surfacePoint,
                direction: SIMD3<Float>(delta, 0, 0),  // +X
                safeYHigh: safeYHigh,
                mesh: meshNode
            )
            rightDistances[pointId] = distance
            print("[MeshFrameDims] RIGHT from \(pointId): \(distance)m")
        }
        perEdge["right"] = EdgeDistances(perPoint: rightDistances)
        
        // NEAR: trace in -Z direction
        var nearDistances: [String: Float] = [:]
        for (pointId, surfacePoint) in projectedPoints {
            let delta = modelSize.z * 0.01  // 1% of model depth
            let distance = traceSurfaceDistance(
                from: surfacePoint,
                direction: SIMD3<Float>(0, 0, -delta),  // -Z
                safeYHigh: safeYHigh,
                mesh: meshNode
            )
            nearDistances[pointId] = distance
            print("[MeshFrameDims] NEAR from \(pointId): \(distance)m")
        }
        perEdge["near"] = EdgeDistances(perPoint: nearDistances)
        
        // FAR: trace in +Z direction
        var farDistances: [String: Float] = [:]
        for (pointId, surfacePoint) in projectedPoints {
            let delta = modelSize.z * 0.01
            let distance = traceSurfaceDistance(
                from: surfacePoint,
                direction: SIMD3<Float>(0, 0, delta),  // +Z
                safeYHigh: safeYHigh,
                mesh: meshNode
            )
            farDistances[pointId] = distance
            print("[MeshFrameDims] FAR from \(pointId): \(distance)m")
        }
        perEdge["far"] = EdgeDistances(perPoint: farDistances)
        
        // TOP/BOTTOM: placeholder for now
        perEdge["top"] = EdgeDistances(perPoint: [:])
        perEdge["bottom"] = EdgeDistances(perPoint: [:])
        
        // STEP 3: Compute aggregated minimal distances
        let aggregate = FrameDimsAggregate(
            left: minDistance(from: perEdge["left"]),
            right: minDistance(from: perEdge["right"]),
            near: minDistance(from: perEdge["near"]),
            far: minDistance(from: perEdge["far"]),
            top: 5.0,  // Placeholder
            bottom: 2.0  // Placeholder
        )
        
        print("[MeshFrameDims] 📊 Aggregate: L:\(aggregate.left) R:\(aggregate.right) N:\(aggregate.near) F:\(aggregate.far)")
        
        // STEP 4: Compute size metrics
        let points = Array(projectedPoints.values)
        let aabb = computeAABB(points: points)
        let obb = computeOBB(points: points)
        let sizes = FrameDimsSizes(aabb: aabb, obb: obb)
        
        // STEP 5: Build result
        return FrameDimsResult(
            perEdge: perEdge,
            aggregate: aggregate,
            sizes: sizes,
            projected: nil,
            meta: FrameDimsMeta(
                notes: "Mesh surface tracing from \(projectedPoints.count)/\(pointsFO.count) points"
            )
        )
    }
    
    // MARK: - Surface Tracing
    
    /// Trace along surface from starting point in a direction, summing distances
    /// - Parameters:
    ///   - from: Starting surface point
    ///   - direction: Step vector (delta in X or Z, with Y=0)
    ///   - safeYHigh: Y coordinate guaranteed to be above surface
    ///   - mesh: Mesh to trace on
    /// - Returns: Total distance along surface path
    private func traceSurfaceDistance(
        from startPoint: SIMD3<Float>,
        direction stepDelta: SIMD3<Float>,
        safeYHigh: Float,
        mesh: SCNNode
    ) -> Float {
        var totalDistance: Float = 0.0
        var tracedPoints: [SIMD3<Float>] = [startPoint]
        var currentXZ = SIMD2<Float>(startPoint.x, startPoint.z)
        
        let maxSteps = 10000  // Safety limit
        var stepCount = 0
        
        while stepCount < maxSteps {
            stepCount += 1
            
            // Move to next XZ position
            currentXZ.x += stepDelta.x
            currentXZ.y += stepDelta.z  // y component of SIMD2 is Z coordinate
            
            // Create high point above surface
            let highPoint = SIMD3<Float>(currentXZ.x, safeYHigh, currentXZ.y)
            
            // Raycast down to find surface
            if let surfaceHit = projectPointOntoSurface(point: highPoint, mesh: mesh) {
                // Found surface at this XZ position
                let prevPoint = tracedPoints.last!
                let segmentDistance = simd_distance(prevPoint, surfaceHit)
                totalDistance += segmentDistance
                tracedPoints.append(surfaceHit)
            } else {
                // No surface found - reached edge
                print("[MeshFrameDims]   Traced \(stepCount) steps, total distance: \(totalDistance)m")
                break
            }
        }
        
        if stepCount >= maxSteps {
            print("[MeshFrameDims]   ⚠️ Reached max steps (\(maxSteps)), stopping trace")
        }
        
        return totalDistance
    }
    
    // MARK: - Surface Projection
    
    /// Project a point onto the mesh surface along Y-axis (up/down)
    /// Returns the surface point if hit found, nil otherwise
    private func projectPointOntoSurface(point: SIMD3<Float>, mesh: SCNNode) -> SIMD3<Float>? {
        let origin = SCNVector3(point.x, point.y, point.z)
        
        // Try raycasting DOWN first (negative Y)
        let downHits = mesh.hitTestWithSegment(
            from: origin,
            to: SCNVector3(point.x, point.y - 100.0, point.z),
            options: nil
        )
        
        if let downHit = downHits.first {
            let hitPoint = downHit.worldCoordinates
            return SIMD3<Float>(hitPoint.x, hitPoint.y, hitPoint.z)
        }
        
        // Try raycasting UP (positive Y)
        let upHits = mesh.hitTestWithSegment(
            from: origin,
            to: SCNVector3(point.x, point.y + 100.0, point.z),
            options: nil
        )
        
        if let upHit = upHits.first {
            let hitPoint = upHit.worldCoordinates
            return SIMD3<Float>(hitPoint.x, hitPoint.y, hitPoint.z)
        }
        
        // No hit found
        return nil
    }
    
    // MARK: - Fallback
    
    /// Create a default result when projection fails
    private func createDefaultResult(pointsFO: [String: SIMD3<Float>]) -> FrameDimsResult {
        let points = Array(pointsFO.values)
        let aabb = computeAABB(points: points)
        let obb = computeOBB(points: points)
        let sizes = FrameDimsSizes(aabb: aabb, obb: obb)
        
        // Return large distances to indicate failure
        let aggregate = FrameDimsAggregate(
            left: 999.0,
            right: 999.0,
            near: 999.0,
            far: 999.0,
            top: 999.0,
            bottom: 999.0
        )
        
        return FrameDimsResult(
            perEdge: [:],
            aggregate: aggregate,
            sizes: sizes,
            projected: nil,
            meta: FrameDimsMeta(notes: "Failed to project points onto surface")
        )
    }
    
    // MARK: - Helper Functions
    
    private func minDistance(from edgeDistances: EdgeDistances?) -> Float {
        guard let distances = edgeDistances?.perPoint.values, !distances.isEmpty else {
            return 0.0
        }
        return distances.min() ?? 0.0
    }
    
    /// Default directions for 6 edges
    static func defaultDirections() -> [String: SIMD3<Float>] {
        return [
            "left":   SIMD3<Float>(-1, 0, 0),
            "right":  SIMD3<Float>( 1, 0, 0),
            "near":   SIMD3<Float>( 0, 0,-1),
            "far":    SIMD3<Float>( 0, 0, 1),
            "top":    SIMD3<Float>( 0, 1, 0),
            "bottom": SIMD3<Float>( 0,-1, 0)
        ]
    }
    
    // MARK: - AABB/OBB (reuse from FrameDimsService)
    
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
    
    private func computeOBB(points: [SIMD3<Float>]) -> OBB {
        guard points.count >= 3 else {
            let aabb = computeAABB(points: points)
            let center = (aabb.min + aabb.max) / 2
            let extents = (aabb.max - aabb.min) / 2
            return OBB(center: center, axes: matrix_identity_float3x3, extents: extents)
        }
        
        // Compute centroid
        let centroid = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        
        // Center the points
        let centered = points.map { $0 - centroid }
        
        // Compute covariance matrix
        var cov = simd_float3x3()
        for p in centered {
            cov[0] += p * p.x
            cov[1] += p * p.y
            cov[2] += p * p.z
        }
        let scale = 1.0 / Float(points.count)
        cov[0] *= scale
        cov[1] *= scale
        cov[2] *= scale
        
        // Simple PCA approximation (use dominant axis)
        let axes = matrix_identity_float3x3
        
        // Project onto axes
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
    
    // MARK: - JSON Encoding
    
    /// Get frame dimensions result for persistence in custom_props
    func getFrameDimsForPersistence(nodes: [SIMD3<Float>], meshNode: SCNNode) -> [String: Any]? {
        // Build point map with stable IDs
        var pointsFO: [String: SIMD3<Float>] = [:]
        for (index, node) in nodes.enumerated() {
            pointsFO["p\(index + 1)"] = node
        }
        
        let result = computeWithMesh(pointsFO: pointsFO, meshNode: meshNode)
        
        // Encode to JSON
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(result)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json
        } catch {
            print("Failed to encode mesh frame dims: \(error)")
            return nil
        }
    }
}

// MARK: - Marker Extension for Mesh Frame Dims Access

extension Marker {
    /// Get mesh-based frame dims from custom props
    var meshFrameDims: FrameDimsResult? {
        guard let frameDimsData = customProps[Self.meshFrameDimsKey],
              let dict = frameDimsData.value as? [String: Any] else {
            return nil
        }
        
        // Convert to JSON and decode
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict)
            let result = try JSONDecoder().decode(FrameDimsResult.self, from: jsonData)
            return result
        } catch {
            print("Failed to decode mesh frame_dims: \(error)")
            return nil
        }
    }
}
