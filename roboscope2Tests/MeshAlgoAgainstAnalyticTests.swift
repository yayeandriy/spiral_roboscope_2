import XCTest
import simd
@testable import roboscope2

// Provider that adapts HalfCylinderAnalytical to MeshRaycastProvider for service testing
@MainActor
struct AnalyticalRaycastProvider: MeshRaycastProvider {
    let hc: HalfCylinderAnalytical
    var boundsMin: SIMD3<Float> { SIMD3(-hc.R, hc.yMin, hc.zMin) }
    var boundsMax: SIMD3<Float> { SIMD3(+hc.R, hc.yMax, hc.zMax) }
    func raycastDown(from point: SIMD3<Float>) -> SIMD3<Float>? { hc.raycastDown(from: point) }
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
