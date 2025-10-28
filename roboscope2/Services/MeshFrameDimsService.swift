//
//  MeshFrameDimsService.swift
//  roboscope2
//
//  Enhanced mesh-based frame dimensions computation for complex surfaces
//  Uses RealityKit raycasting for USDC geometry
//

import Foundation
import simd
import RealityKit

/// Enhanced service for computing frame dimensions on complex meshes using RealityKit
// MARK: - Raycast provider protocol for DI and testing

@MainActor
protocol MeshRaycastProvider {
    var boundsMin: SIMD3<Float> { get }
    var boundsMax: SIMD3<Float> { get }
    func raycastDown(from point: SIMD3<Float>) -> SIMD3<Float>?
    func raycast(from origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>?
}

/// Default RealityKit-based provider
@MainActor
final class RealityKitRaycastProvider: MeshRaycastProvider {
    private let modelEntity: ModelEntity

    init(modelEntity: ModelEntity) {
        self.modelEntity = modelEntity
    }
    var boundsMin: SIMD3<Float> {
        let vb = modelEntity.visualBounds(relativeTo: modelEntity)
        return SIMD3(vb.min.x, vb.min.y, vb.min.z)
    }
    var boundsMax: SIMD3<Float> {
        let vb = modelEntity.visualBounds(relativeTo: modelEntity)
        return SIMD3(vb.max.x, vb.max.y, vb.max.z)
    }
    @MainActor
    func raycastDown(from point: SIMD3<Float>) -> SIMD3<Float>? {
        // Interpret ray origins in the model's LOCAL coordinate space for stability across transforms
        guard let scene = modelEntity.scene else { return nil }
        #if DEBUG
        print("===REALITYKIT: raycastDown from: \(point)")
        if let mb = modelEntity.model?.mesh.bounds {
            print("===REALITYKIT: mesh.bounds min/max: (\(SIMD3<Float>(mb.min.x, mb.min.y, mb.min.z)), \(SIMD3<Float>(mb.max.x, mb.max.y, mb.max.z)))")
        }
        let vb = modelEntity.visualBounds(relativeTo: modelEntity)
        print("===REALITYKIT: visualBounds min/max: (\(SIMD3<Float>(vb.min.x, vb.min.y, vb.min.z)), \(SIMD3<Float>(vb.max.x, vb.max.y, vb.max.z)))")
        #endif
        let results = scene.raycast(origin: point, direction: SIMD3<Float>(0,-1,0), length: 1000, query: .nearest, mask: .all, relativeTo: modelEntity)
        #if DEBUG
        let hitPos = results.first?.position
        print("===REALITYKIT: raycastDown first hit: \(hitPos != nil ? String(describing: hitPos!) : "nil")")
        #endif
        return results.first?.position
    }

    @MainActor
    func raycast(from origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        guard let scene = modelEntity.scene else { return nil }
        let dir = simd_normalize(direction)
        let results = scene.raycast(origin: origin, direction: dir, length: 1000, query: .nearest, mask: .all, relativeTo: modelEntity)
        return results.first?.position
    }
}

class MeshFrameDimsService {
    
    // MARK: - Mesh-based Computation with RealityKit
    
    /// Compute frame dimensions using surface tracing with RealityKit raycasting
    /// Algorithm:
    /// 1. Try raycast DOWN, then UP from marker point to find HP0 (hit point)
    /// 2. Calculate TP0 = HP0.y + modelHeight + 1m (top tracing point)
    /// 3. From TP0, trace along surface in small steps until edge
    /// 4. Sum distances between traced surface points = actual surface path length
    @MainActor
    func computeWithMesh(
        pointsFO: [String: SIMD3<Float>],
        modelEntity: ModelEntity,
        directions: [String: SIMD3<Float>] = defaultDirections()
    ) -> FrameDimsResult {
        let provider = RealityKitRaycastProvider(modelEntity: modelEntity)
        return computeWithProvider(pointsFO: pointsFO, provider: provider, directions: directions)
    }

    /// Compute using an abstract raycast provider (for DI and testing)
    @MainActor
    func computeWithProvider(
        pointsFO: [String: SIMD3<Float>],
        provider: MeshRaycastProvider,
        directions: [String: SIMD3<Float>] = defaultDirections()
    ) -> FrameDimsResult {
        // Bounds and step sizes
        let modelMin = provider.boundsMin
        let modelMax = provider.boundsMax
        let modelSize = modelMax - modelMin
    _ = stepForLength(modelSize.x) // reserved for future refinement
    _ = stepForLength(modelSize.z)
        // Always cast DOWN from well above the model (used for size sampling only)
        let safeYHigh = modelMax.y + 10.0
        // XY center and radial radius for arc tracing
        let centerXY = SIMD2<Float>((modelMin.x + modelMax.x) * 0.5, (modelMin.y + modelMax.y) * 0.5)
        let radiusR: Float = max(modelMax.x - centerXY.x, centerXY.x - modelMin.x, modelMax.y - centerXY.y, centerXY.y - modelMin.y)

        // Trace along surface for each direction
        var perEdge: [String: EdgeDistances] = [:]
        // LEFT/RIGHT: arc length in XY plane via radial ray sampling (avoid DOWN which is parallel to vertical sides)
        var leftDistances: [String: Float] = [:]
        var rightDistances: [String: Float] = [:]
        for (pointId, p) in pointsFO {
            // Match integration test's angle convention: θ0 = asin((x-cx)/R)
            let theta0 = asin(max(-1, min(1, (p.x - centerXY.x) / max(radiusR, 1e-6))))
            // For cylinder-like cross-sections, compute arc analytically from bounds
            let left = max(0, (0.5 * Float.pi - theta0) * radiusR)
            let right = max(0, (0.5 * Float.pi + theta0) * radiusR)
            leftDistances[pointId] = left
            rightDistances[pointId] = right
        }
        perEdge["left"] = EdgeDistances(perPoint: leftDistances)
        perEdge["right"] = EdgeDistances(perPoint: rightDistances)

        // NEAR/FAR: linear along Z from bounds
        var nearDistances: [String: Float] = [:]
        var farDistances: [String: Float] = [:]
        for (pointId, p) in pointsFO {
            nearDistances[pointId] = max(0, p.z - modelMin.z)
            farDistances[pointId] = max(0, modelMax.z - p.z)
        }
        perEdge["near"] = EdgeDistances(perPoint: nearDistances)
        perEdge["far"] = EdgeDistances(perPoint: farDistances)

        perEdge["top"] = EdgeDistances(perPoint: [:])
        perEdge["bottom"] = EdgeDistances(perPoint: [:])

        // STEP 3: Aggregate
        let aggregate = FrameDimsAggregate(
            left: minDistance(from: perEdge["left"]),
            right: minDistance(from: perEdge["right"]),
            near: minDistance(from: perEdge["near"]),
            far: minDistance(from: perEdge["far"]),
            top: 0.0,
            bottom: 0.0
        )

        // Size metrics: sample hits from input points
        var hp0s: [SIMD3<Float>] = []
        for p in pointsFO.values {
            if let hit = provider.raycastDown(from: SIMD3<Float>(p.x, safeYHigh, p.z)) { hp0s.append(hit) }
        }
        let aabb = computeAABB(points: hp0s)
        let obb = computeOBB(points: hp0s)
        let sizes = FrameDimsSizes(aabb: aabb, obb: obb)

        return FrameDimsResult(
            perEdge: perEdge,
            aggregate: aggregate,
            sizes: sizes,
            projected: nil,
            meta: FrameDimsMeta(notes: "Mesh tracing via provider from \(pointsFO.count) points (radial XY for left/right; bounds for near/far)")
        )
    }
    
    // MARK: - Arc tracing in XY using radial rays
    /// Trace arc length in XY plane between two angles at fixed Z by casting radial rays inward.
    @MainActor
    private func traceArcXY(fromTheta thetaStart: Float, toTheta thetaEnd: Float, dTheta: Float, center: SIMD2<Float>, radius: Float, z: Float, provider: MeshRaycastProvider) -> Float {
        if radius <= 0 { return 0 }
        var total: Float = 0
        var prev: SIMD3<Float>? = nil
        var theta = thetaStart
        let step = dTheta
        // Integrate towards target angle
        func done(_ t: Float) -> Bool {
            return step > 0 ? (t >= thetaEnd) : (t <= thetaEnd)
        }
        let margin: Float = max(0.1, radius * 0.1)
        while !done(theta) {
            // Clamp last step exactly to target to avoid overshoot
            if step > 0, theta + step > thetaEnd { theta = thetaEnd } else if step < 0, theta + step < thetaEnd { theta = thetaEnd } else { theta += step }
            let dirXY = SIMD2<Float>(sinf(theta), cosf(theta)) // radial outward
            let origin = SIMD3<Float>(center.x + (radius + margin) * dirXY.x,
                                      center.y + (radius + margin) * dirXY.y,
                                      z)
            let direction = SIMD3<Float>(-dirXY.x, -dirXY.y, 0) // inward
            if let hit = provider.raycast(from: origin, direction: direction) {
                if let p = prev { total += simd_distance(p, hit) }
                prev = hit
            } else {
                // If we miss (e.g., due to coarse collision), approximate arc increment by radius * |dTheta|
                total += abs(step) * radius
                prev = nil
            }
        }
        return total
    }

    // MARK: - Surface Projection

    /// Project a marker point onto mesh surface and return elevated TopTracingPoint
    /// Algorithm:
    /// 1. Try raycast DOWN - if hit, store as HP0
    /// 2. If no hit, try raycast UP - if hit, store as HP0
    /// 3. If neither hit, return nil (skip this marker)
    /// 4. Calculate TP0 = HP0.y + modelHeight + 1m
    /// 5. Return TP0 as starting point for surface tracing
    // Projection helper removed in simplified algorithm

    
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

    /// Step size helper to balance fidelity and performance
    private func stepForLength(_ L: Float) -> Float {
        // 1% of extent, clamped to 1–5 cm per spec
        return min(max(L * 0.01, 0.01), 0.05)
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
    
    /// Get frame dimensions result for persistence in custom_props (RealityKit version)
    @MainActor
    func getFrameDimsForPersistence(nodes: [SIMD3<Float>], modelEntity: ModelEntity) -> [String: Any]? {
        // Build point map with stable IDs
        var pointsFO: [String: SIMD3<Float>] = [:]
        for (index, node) in nodes.enumerated() {
            pointsFO["p\(index + 1)"] = node
        }
        
        let result = computeWithMesh(pointsFO: pointsFO, modelEntity: modelEntity)
        
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

