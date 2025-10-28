import Foundation
import simd

/// Deterministic, analytical model of a vertical half-cylinder extruded along Z.
/// - Axis: Z (constant cross-section in XY)
/// - Half-circle: down semicircle, y >= 0, with radius R
/// - Bounds: z in [-R, R], x in [-R, +R], y in [0, R]
struct HalfCylinderAnalytical {
    let R: Float = 1.0
    let zMin: Float = -1.0
    let zMax: Float = 1.0
    let yMin: Float = 0.0
    var yMax: Float { R }

    // Model height used for TP0 elevation
    var modelHeight: Float { yMax - yMin }

    // Surface Y for given x, or nil if |x| > R
    func surfaceY(x: Float) -> Float? {
        let r2 = R * R
        let x2 = x * x
        if x2 > r2 { return nil }
        let sq = sqrt(max(0, r2 - x2))
        return R - sq
    }

    // Returns hit point for a vertical ray DOWN from origin, if surface exists below
    func raycastDown(from origin: SIMD3<Float>) -> SIMD3<Float>? {
        guard origin.z >= zMin && origin.z <= zMax else { return nil }
        guard let yHit = surfaceY(x: origin.x) else { return nil }
        print("REYCAST DOWN \(origin), \(yHit)")
//        if origin.y >= yHit && yHit >= yMin {
//        
//        }
//        return nil
        return SIMD3(origin.x, yHit, origin.z)
    }

    // Returns hit point for a vertical ray UP from origin, if surface exists above
    func raycastUp(from origin: SIMD3<Float>) -> SIMD3<Float>? {
        guard origin.z >= zMin && origin.z <= zMax else { return nil }
        guard let yHit = surfaceY(x: origin.x) else { return nil }
        if origin.y <= yHit && yHit >= yMin { return SIMD3(origin.x, yHit, origin.z) }
        return nil
    }

    // Project a node to the surface and create TP0 above it per spec
    func makeTP0(for point: SIMD3<Float>) -> SIMD3<Float>? {
        if let hit = raycastDown(from: point) ?? raycastUp(from: point) {
            return SIMD3(hit.x, hit.y + modelHeight + 1.0, hit.z)
        }
        return nil
    }

    // Generic tracer: step laterally and raycast down to accumulate surface distance
    func traceDistance(from TP0: SIMD3<Float>, step: SIMD3<Float>, maxSteps: Int = 3000) -> Float {
        var total: Float = 0
        var points: [SIMD3<Float>] = []

        // seed with first surface point below TP0
        if let first = raycastDown(from: TP0) {
            points.append(first)
        } else {
            return 0
        }

        var current = TP0
        for _ in 0..<maxSteps {
            current += step
            let elevated = SIMD3<Float>(current.x, TP0.y, current.z)
            guard let hit = raycastDown(from: elevated) else { break }
            if let prev = points.last { total += simd_distance(prev, hit) }
            points.append(hit)
        }
        return total
    }

    // Convenience: recommended step size for axis length L (Δ = 1% clamped to [1cm, 5cm])
    func stepForLength(_ L: Float) -> Float { min(max(L * 0.01, 0.01), 0.05) }

    // Analytical distances from a true surface point HP0 = (x,y,z)
    func analyticLeftRight(from HP0: SIMD3<Float>) -> (left: Float, right: Float) {
        let theta = atan2(HP0.x, R) // already on surface, y>=0
        let left = 0.5*Float.pi - theta
        let right = 0.5*Float.pi + theta
        return (left, right)
    }
    
    func analyticLeftRight(theta Theta: Float) -> (left: Float, right: Float) {
        let left = 0.5*Float.pi - Theta
        let right = 0.5*Float.pi + Theta
        return (left, right)
    }

    func analyticNearFar(from HP0: SIMD3<Float>) -> (near: Float, far: Float) {
        let near = HP0.z - zMin
        let far = zMax - HP0.z
        return (near, far)
    }
}
