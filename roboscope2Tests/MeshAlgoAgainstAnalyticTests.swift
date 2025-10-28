import XCTest
import simd
@testable import roboscope2

// Provider that adapts HalfCylinderAnalytical to MeshRaycastProvider for service testing
@MainActor
struct AnalyticalRaycastProvider: MeshRaycastProvider {
    let hc: HalfCylinderAnalytical
    var boundsMin: SIMD3<Float> { SIMD3(-hc.R, hc.yMin, hc.zMin) }
    var boundsMax: SIMD3<Float> { SIMD3(+hc.R, hc.yMax, hc.zMax) }
    var upAxis: SIMD3<Float> { SIMD3<Float>(0, 1, 0) }
    var upAxisIndex: Int { 1 }
    func raycastDown(from point: SIMD3<Float>) -> SIMD3<Float>? { hc.raycastDown(from: point) }
    func raycastUp(from point: SIMD3<Float>) -> SIMD3<Float>? { hc.raycastUp(from: point) }
    func raycast(from origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        // Intersect a ray in XY-plane with the analytical semicircle x^2 + (y - R)^2 = R^2, z is extruded
        // Only support rays with zero Z component as used by the service
        if abs(direction.z) > 1e-6 { return nil }
        let dirXY = SIMD2<Float>(direction.x, direction.y)
        let len = simd_length(dirXY)
        if len < 1e-6 { return nil }
        let d = dirXY / len
        let o = SIMD2<Float>(origin.x, origin.y)
        let c = SIMD2<Float>(0, hc.R)
        // Solve |(o + t d) - c|^2 = R^2 -> at^2 + bt + c0 = 0
        let oc = o - c
        let a: Float = simd_dot(d, d)
        let b: Float = 2 * simd_dot(oc, d)
        let c0: Float = simd_dot(oc, oc) - hc.R * hc.R
        let disc = b*b - 4*a*c0
        if disc < 0 { return nil }
        let sqrtDisc = sqrt(max(0, disc))
        let t1 = (-b - sqrtDisc) / (2*a)
        let t2 = (-b + sqrtDisc) / (2*a)
        let t = [t1, t2].filter { $0 >= 0 }.min()
        guard let tHit = t else { return nil }
        let hitXY = o + tHit * d
        // Validate within y bounds of the semicircle
        if hitXY.y < hc.yMin - 1e-4 || hitXY.y > hc.yMax + hc.R + 1e-4 { return nil }
        // Clamp z within extruded bounds
        if origin.z < hc.zMin - 1e-4 || origin.z > hc.zMax + 1e-4 { return nil }
        return SIMD3<Float>(hitXY.x, hitXY.y, origin.z)
    }
}

final class MeshAlgoAgainstAnalyticTests: XCTestCase {

    @MainActor
    func test_halfCylinder_matches_analytic_at_midHeight() throws {
        // Arrange analytical model
        let hc = HalfCylinderAnalytical()
        let provider = AnalyticalRaycastProvider(hc: hc)
        let service = MeshFrameDimsService()

        // Choose a marker node near mid-arc: θ=π/3 => x=R cosθ, y=R sinθ
        let theta: Float = .pi / 4
        let x = hc.R * sin(theta)
        let y = hc.R - hc.R * cos(theta)
        let z: Float = 0.0
        let node = SIMD3<Float>(x, y, z)
        print("TEST NODE: \(node)")
        // Run service with provider
        let result = service.computeWithProvider(pointsFO: ["p1": node], provider: provider)
        
        print("RESULT: \(result)")
        // Analytical ground truth from HP0 below TP0 (or directly from node since it's on surface)
        let HP0 = node
    let (aLeft, aRight) = hc.analyticLeftRight(theta: theta)
        print("ANALITICAL LEFT RIGHT: \(aLeft) | \(aRight)")
        let (aNear, aFar) = hc.analyticNearFar(from: HP0)

        // Extract per-edge distances for p1
        func edge(_ key: String) -> Float {
            result.perEdge[key]?.perPoint["p1"] ?? -1
        }

        let leftDist = edge("left")
        let rightDist = edge("right")
        let nearDist = edge("near")
        let farDist = edge("far")

        print("MESH LEFT RIGHT: \(leftDist) | \(rightDist)")
        // Assert with tolerances (3 cm)
        let tol: Float = 0.03
        XCTAssertEqual(leftDist, aLeft, accuracy: tol, "LEFT mismatch: mesh=\(leftDist) analytic=\(aLeft)")
        XCTAssertEqual(rightDist, aRight, accuracy: tol, "RIGHT mismatch")
        XCTAssertEqual(nearDist, aNear, accuracy: tol, "NEAR mismatch")
        XCTAssertEqual(farDist, aFar, accuracy: tol, "FAR mismatch")
    }
}
