//
//  ARGeometryUtils.swift
//  roboscope2
//
//  Shared AR geometry utilities: plane fitting, edge detection, world-to-screen projection.
//  Extracted from SpatialMarkerService for reuse across the codebase.
//

import ARKit
import RealityKit
import CoreGraphics
import simd

enum ARGeometryUtils {

    // MARK: - Plane fitting

    /// Fit a plane to 3+ points. Returns (center, normal).
    /// For 2 points, the normal is perpendicular to the line, roughly horizontal.
    static func fitPlane(points: [SIMD3<Float>]) -> (center: SIMD3<Float>, normal: SIMD3<Float>) {
        let center = points.reduce(.zero, +) / Float(points.count)
        if points.count >= 3 {
            let v1 = points[1] - points[0]
            let v2 = points[2] - points[0]
            var normal = cross(v1, v2)
            if simd_length(normal) < 0.0001 { normal = SIMD3<Float>(0, 1, 0) }
            else { normal = normalize(normal) }
            return (center, normal)
        }
        let dir = normalize(points[1] - points[0])
        let up = SIMD3<Float>(0, 1, 0)
        var normal = cross(dir, up)
        if simd_length(normal) < 0.0001 { normal = SIMD3<Float>(1, 0, 0) }
        else { normal = normalize(normal) }
        return (center, normal)
    }

    // MARK: - Edge detection

    /// Returns true if the 4 corners span an object edge (one corner on a different surface).
    /// Uses leave-one-out plane fitting: if any single point is >10cm from the plane
    /// fitted through the other three, it's an edge crossing.
    static func checkEdgeCrossing(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count == 4 else { return false }
        var bestOutlierRes: Float = 0
        for skip in 0..<4 {
            let subset = (0..<4).filter { $0 != skip }.map { points[$0] }
            let (subCenter, subNormal) = fitPlane(points: subset)
            let outlierRes = abs(dot(points[skip] - subCenter, subNormal))
            if outlierRes > bestOutlierRes { bestOutlierRes = outlierRes }
        }
        let crosses = bestOutlierRes > 0.10
        if crosses {
            print("[EdgeCheck] crossing detected — best outlier residual=\(bestOutlierRes)m")
        }
        return crosses
    }

    // MARK: - World → screen projection

    /// Projects a world-space position to screen coordinates using the current AR frame.
    /// Returns nil if the point is behind the camera.
    static func projectWorldToScreen(
        worldPosition: SIMD3<Float>,
        frame: ARFrame,
        arView: ARView
    ) -> CGPoint? {
        let camera = frame.camera
        let orientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projectionMatrix = camera.projectionMatrix(
            for: orientation,
            viewportSize: arView.bounds.size,
            zNear: 0.001,
            zFar: 1000
        )

        let worldPos4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        let viewPos = viewMatrix * worldPos4
        if viewPos.z > 0 { return nil } // behind camera
        let projPos = projectionMatrix * viewPos
        guard projPos.w != 0 else { return nil }
        let ndcX = projPos.x / projPos.w
        let ndcY = projPos.y / projPos.w

        let screenX = (ndcX + 1.0) * 0.5 * Float(arView.bounds.width)
        let screenY = (1.0 - ndcY) * 0.5 * Float(arView.bounds.height)

        return CGPoint(x: CGFloat(screenX), y: CGFloat(screenY))
    }
}
