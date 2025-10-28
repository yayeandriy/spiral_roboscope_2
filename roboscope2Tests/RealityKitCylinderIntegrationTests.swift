import XCTest
import simd
import RealityKit
import UIKit
@testable import roboscope2

@MainActor
final class RealityKitCylinderIntegrationTests: XCTestCase {

    func test_cylinder_usdc_meshAlgo_matches_analytic() throws {
        // Try loading the model from the app bundle assets
        // Load as generic Entity then extract first ModelEntity to be robust across RealityKit versions
        let root: Entity
        if let url = Bundle.main.url(forResource: "cylinder", withExtension: "usdc") {
            root = try Entity.load(contentsOf: url)
        } else if let testURL = Bundle(for: Self.self).url(forResource: "cylinder", withExtension: "usdc") {
            root = try Entity.load(contentsOf: testURL)
        } else if let named = try? Entity.load(named: "cylinder") {
            root = named
        } else {
            throw XCTSkip("cylinder.usdc not found in app or test bundle; skipping integration test")
        }
        guard let modelEntity = RealityKitCylinderIntegrationTests.findFirstModelEntity(in: root) else {
            throw XCTSkip("Loaded asset does not contain a ModelEntity; skipping integration test")
        }

    // Use the model as-is (no normalization)
    // Ensure collisions are available for raycasting
    modelEntity.generateCollisionShapes(recursive: true)

        // Host in an ARView-backed scene (Scene has no public initializer)
        let arView = ARView(frame: .init(x: 0, y: 0, width: 1, height: 1))
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(modelEntity)
        arView.scene.addAnchor(anchor)

        // Build provider and service
    let provider = RealityKitRaycastProvider(modelEntity: modelEntity)
        let service = MeshFrameDimsService()

    // Choose a marker point on the cylindrical surface in model-local XY at z centered between near/far
    // Use model's actual extents, do not modify the model
    let bMin = provider.boundsMin
    let bMax = provider.boundsMax
    let R = max(abs(bMin.x), abs(bMax.x))
    let theta: Float = .pi / 4
    let x = R * sin(theta)
    let y = R - R * cos(theta)
    let zMid = (bMin.z + bMax.z) * 0.5
    let node = SIMD3<Float>(x, y, zMid)

        // Execute
        let result = service.computeWithProvider(pointsFO: ["p1": node], provider: provider)
       
    // Ground truth computed from model's actual bounds (no asset changes)
    // Arc length along XY: left = (pi/2 - asin(x/R)) * R, right = (pi/2 + asin(x/R)) * R
    let thetaFromX = asin(max(-1, min(1, node.x / max(1e-6, R))))
    let aLeft = (0.5 * Float.pi - thetaFromX) * R
    let aRight = (0.5 * Float.pi + thetaFromX) * R
    print("===REALITYKIT: ANALYTIC (bounds-based): left: \(aLeft), right: \(aRight)")
    let aNear = node.z - bMin.z
    let aFar = bMax.z - node.z
        
        func edge(_ key: String) -> Float { result.perEdge[key]?.perPoint["p1"] ?? -1 }
        let leftDist = edge("left")
        let rightDist = edge("right")
        print("===REALITYKIT: MESH RESULTS: leftDist \(leftDist), rightDist \(rightDist)")
        let nearDist = edge("near")
        let farDist = edge("far")

        // Tolerance slightly looser to allow asset discretization
    let tol: Float = 0.05 // 5 cm
        XCTAssertEqual(leftDist, aLeft, accuracy: tol, "LEFT mismatch")
        XCTAssertEqual(rightDist, aRight, accuracy: tol, "RIGHT mismatch")
        XCTAssertEqual(nearDist, aNear, accuracy: tol, "NEAR mismatch")
        XCTAssertEqual(farDist, aFar, accuracy: tol, "FAR mismatch")
    }
}

private extension RealityKitCylinderIntegrationTests {
    static func findFirstModelEntity(in root: Entity) -> ModelEntity? {
        if let m = root as? ModelEntity { return m }
        for child in root.children {
            if let m = findFirstModelEntity(in: child) { return m }
        }
        return nil
    }

    /// Scale the model so that:
    ///  - Radial radius in X/Y becomes 1.0 (half-cylinder: y in [0, R])
    ///  - Longitudinal Z extent becomes 2.0 (z in [-1, +1])
    /// Assumes local coordinates: circle in XY, axis along Z.
    static func normalizeToUnitHalfCylinder(_ model: ModelEntity) {
        let b = model.model?.mesh.bounds
        let minB = SIMD3<Float>(b?.min.x ?? 0, b?.min.y ?? 0, b?.min.z ?? 0)
        let maxB = SIMD3<Float>(b?.max.x ?? 0, b?.max.y ?? 0, b?.max.z ?? 0)
        let radiusMeasured = max(abs(minB.x), abs(maxB.x), abs(minB.y), abs(maxB.y))
        let zLen = maxB.z - minB.z
        let sx = radiusMeasured > 0 ? (1.0 / radiusMeasured) : 1.0
        let sy = sx
        let sz = zLen > 0 ? (2.0 / zLen) : 1.0
        model.scale = SIMD3<Float>(sx, sy, sz) * model.scale
    }
}
