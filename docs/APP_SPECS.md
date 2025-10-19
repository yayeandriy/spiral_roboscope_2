fully on-device, no server. below is a complete blueprint for an iOS app that takes a local USDZ room model and, after a LiDAR scan, places and aligns it with the real room in AR.

0) Tech stack & device

iOS 17+, A12Z/ A14+ LiDAR devices (iPad Pro 2020+, iPhone 12 Pro+).

Swift + SwiftUI, ARKit (Scene Reconstruction), RealityKit, simd/Accelerate.

Optional performance boosters: Metal compute for downsampling/NN search (can ship later).

1) High-level architecture
Modules

CaptureSession (AR session setup)

MeshFusionService (fuse ARMeshAnchors → unified point cloud)

PreprocessService (confidence/range filter, voxel downsample, normals)

ModelLoader (load USDZ, sample to point cloud, compute features)

CoarsePoseEstimator (gravity + PCA + multi-hypothesis seeds)

ICPRefiner (robust point-to-plane ICP, coarse→fine pyramid)

AlignmentCoordinator (drives the pipeline; exposes status to UI)

ARPlacementService (applies final transform to ModelEntity in AR)

PersistenceService (save/load pose, metrics, world map)

DiagnosticsService (heatmap overlay, metrics HUD)

Runtime flow (simplified)
App start
 └─ Load USDZ → ModelCloud
Start Scan
 └─ CaptureSession.start(.mesh)
     └─ MeshFusionService.accumulate() → ScanCloud (live)
         └─ PreprocessService (voxel, normals)
When “Align” tapped:
 └─ CoarsePoseEstimator → T0 (1..N seeds)
 └─ ICPRefiner.run(T0s) → T*
 └─ ARPlacementService.apply(T*)
 └─ PersistenceService.save(T*, metrics, world map)

2) Data model scheme (Codable; persisted as JSON)
import simd

struct Pose: Codable {
    var matrix: simd_float4x4
}

struct RegistrationMetrics: Codable {
    var inlierFraction: Float
    var rmseMeters: Float
    var iterations: Int
    var voxelMeters: Float
    var timestamp: Double
}

struct Point3F: Codable { var x, y, z: Float }
struct Normal3F: Codable { var nx, ny, nz: Float }

struct PointCloud: Codable {
    var points: [Point3F]
    var normals: [Normal3F]?     // optional; present after preprocessing
    var voxelSize: Float?        // meters
    var boundsMin: Point3F?
    var boundsMax: Point3F?
    var estimatedUp: Normal3F?   // gravity-aligned up from ARKit
}

struct ScanSnapshot: Codable {
    var cloud: PointCloud
    var worldOrigin: Pose           // ARKit world origin at capture start
    var device: String              // model identifier
    var arWorldMapData: Data?       // optional relocalization
}

struct ModelDescriptor: Codable {
    var name: String                // usd(z) asset name
    var nominalScale: Float         // meters/unit (usually 1.0)
    var canonicalFrameHint: String  // e.g., "Z-up room"
    var sampleVoxel: Float          // sampling resolution for model cloud
}

struct AlignmentResult: Codable {
    var poseModelInWorld: Pose      // T*: places USDZ in AR world
    var metrics: RegistrationMetrics
    var model: ModelDescriptor
}

3) Services design (interfaces + notes)
3.1 CaptureSession

Configures ARKit with scene reconstruction & gravity alignment.

final class CaptureSession {
    let session = ARSession()

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.worldAlignment = .gravity    // crucial for stable "up"
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }
}

3.2 MeshFusionService

Fuses ARMeshAnchor geometry into a deduplicated point set in world coordinates; attaches per-vertex confidence and distances for filtering.

Key steps:

iterate mesh anchors each frame

transform vertex positions by anchor.transform

drop vertices with low confidence

accumulate into a spatial hash (voxel map) to avoid duplicates

API:

final class MeshFusionService {
    func append(meshAnchor: ARMeshAnchor)
    func snapshotPointCloud() -> RawCloud   // (points: [SIMD3<Float>], confidences: [UInt8])
}

3.3 PreprocessService

Confidence filter: keep confidence ≥ medium

Range clamp: e.g., 0.25–5.0 m

Voxel downsample: 3 levels (coarse 2.0cm → mid 1.0cm → fine 0.5–0.8cm)

Normals: PCA per voxel neighborhood; orient via gravity when ambiguous

Optional: radius outlier removal

API:

struct PreprocessParams {
    var minConfidence: UInt8
    var minRange: Float
    var maxRange: Float
    var voxelSizes: [Float]   // e.g., [0.02, 0.01, 0.007]
}

final class PreprocessService {
    func buildPyramid(raw: RawCloud,
                      gravityUp: SIMD3<Float>,
                      params: PreprocessParams) -> [PointCloud]
}

3.4 ModelLoader

Loads USDZ via RealityKit, samples surface to a point cloud (Poisson-disk or voxel sampling), computes vertex normals, and tags high-curvature lines (edges) for coarse matching.

API:

final class ModelLoader {
    func loadUSDZ(named: String, sampleVoxel: Float) async throws -> PointCloud
    func extractEdgeLines(from modelMesh: MeshResource) -> [Polyline3D] // optional
}

3.5 CoarsePoseEstimator

Generates multi-hypothesis seeds:

gravity alignment

PCA major axis of scan vs. model principal axis

model BB center → scan BB center

try mirrored/rotated variants (90° steps around up if needed)

API:

struct CoarseSeed { let pose: simd_float4x4; let score: Float }

final class CoarsePoseEstimator {
    func seeds(model: PointCloud, scan: PointCloud, up: SIMD3<Float>) -> [CoarseSeed]
}

3.6 ICPRefiner (on-device)

Robust point-to-plane ICP with trimmed loss and Huber. Coarse→fine across the pyramid.

Correspondence search via voxel grid + k-d lite (grid bucket NN).

Reject by max distance & normal angle.

Minimize Σ ρ(n·(R m + t − s)), ρ=Huber.

Trimmed ICP: keep best p% residuals per iteration.

Stop when ΔRMSE < 1% of current voxel size (or max iters).

API:

struct ICPParams {
    var maxIterations: Int
    var maxCorrDist: Float        // starts as 4× voxel, shrinks each level
    var normalDotMin: Float       // e.g., 0.75
    var trimFraction: Float       // e.g., 0.7
    var huberDelta: Float         // 2× voxel
}

final class ICPRefiner {
    func refine(modelPyr: [PointCloud],
                scanPyr: [PointCloud],
                seeds: [simd_float4x4],
                paramsPerLevel: [ICPParams]) -> (bestPose: simd_float4x4, metrics: RegistrationMetrics)
}

3.7 AlignmentCoordinator

Orchestrates: pulls scan pyramid + model cloud, requests seeds, runs ICP, publishes results to UI.

3.8 ARPlacementService

Holds a ModelEntity loaded from USDZ and applies pose in AR world space.

final class ARPlacementService {
    let arView: ARView
    var modelEntity: ModelEntity!

    func loadModel(named: String) async throws {
        modelEntity = try await ModelEntity(named: named)
        modelEntity.generateCollisionShapes(recursive: true)
        arView.scene.anchors.append(AnchorEntity(world: .identity)) // placeholder
    }

    func apply(pose: simd_float4x4) {
        modelEntity.transform.matrix = pose
        if modelEntity.parent == nil {
            let anchor = AnchorEntity(world: pose)
            anchor.addChild(modelEntity)
            arView.scene.addAnchor(anchor)
        }
    }
}

3.9 PersistenceService

Save AlignmentResult to disk (JSON).

Optionally save ARWorldMap for relocalization (user can resume later).

Keep last good pose per model name.

4) App workflow (UX + pipeline)

Load model

App boots, shows model picker (or fixed asset).

ModelLoader samples USDZ into ModelCloud (e.g., voxel 1 cm).

Precompute model normals.

Scan room

Start AR session; show “mesh coverage” progress (surface area).

Live voxel downsample preview to ensure good coverage of floors/walls/key geometry.

Button “Align”.

Preprocess

Freeze accumulation; produce scan pyramid (2.0 cm / 1.0 cm / 0.7 cm).

Estimate gravity up from ARKit camera.

Coarse alignment (multi-seed)

Compute scan PCA; align model principal axes.

Translate model BB center to scan BB center.

Emit ~6–10 seeds (yaw variations ±90°, mirroring if room symmetry suspected).

Quick scoring: point-to-plane error on coarsest level; keep top 2.

ICP refinement (coarse→fine)

Level 0 (2.0 cm): 15–25 iters, maxCorr=8 cm, trim=0.7, normalDot>0.75.

Level 1 (1.0 cm): 12–20 iters, maxCorr=4 cm, trim=0.7.

Level 2 (0.7 cm): 10–15 iters, maxCorr=2.5 cm, trim=0.7.

Choose best pose by lowest RMSE & highest inlierFraction.

Place model in AR

Apply T* to the ModelEntity (world space).

Show metrics (RMSE, inliers). Provide “Nudge” (small joystick to tweak yaw/xyz if desired) and “Refine again” (restarts ICP from adjusted pose).

Persist

Save AlignmentResult + optional ARWorldMap.

On next app run in same room, relocalize; place model instantly using saved pose.

Optional overlays

Residual heatmap: render sampled model points; color by distance to nearest scan surface (blue good → red poor).

Coverage map: highlight model areas with no nearby scan points (indicates missing LiDAR coverage).

5) Practical parameters (good defaults)

Confidence threshold: medium or higher.

Range: 0.25–5.0 m (skip ultra-near speckle).

Voxel sizes (scan): [0.02, 0.01, 0.007] m.

Model sampling voxel: 0.01 m (rooms are large; 1 cm is fine).

Normals neighborhood: k=20 or radius=3×voxel.

ICP normal angle: cosθ ≥ 0.75 (θ ≤ ~41°).

Trim fraction: 0.7.

Stop criterion: ΔRMSE < 0.01×voxel over 3 iters.

6) Key implementation snippets
6.1 Mesh to point cloud
func points(from anchor: ARMeshAnchor) -> [SIMD3<Float>] {
    let geom = anchor.geometry
    let vertices = geom.vertices
    let vBuffer = vertices.buffer.contents()
    var pts: [SIMD3<Float>] = []
    pts.reserveCapacity(vertices.count)

    for i in 0..<vertices.count {
        let v = vertices[i]
        var p = SIMD3<Float>(v.x, v.y, v.z)
        // to world space:
        p = (anchor.transform * simd_float4(p, 1)).xyz
        // confidence filter:
        if geom.classificationOf(faceWithIndex: 0) != .none { /* optional */ }
        pts.append(p)
    }
    return pts
}

6.2 Voxel downsample (grid hash)
struct VoxelKey: Hashable { let x,y,z: Int32 }

func voxelize(_ pts: [SIMD3<Float>], voxel: Float) -> [SIMD3<Float>] {
    var map = [VoxelKey: SIMD3<Float>]()
    var cnt = [VoxelKey: Int]()
    for p in pts {
        let k = VoxelKey(x: Int32(floor(p.x/voxel)),
                         y: Int32(floor(p.y/voxel)),
                         z: Int32(floor(p.z/voxel)))
        map[k, default: .zero] += p
        cnt[k, default: 0] += 1
    }
    return map.map { (k, sum) in sum / Float(cnt[k]!) }
}

6.3 PCA (for major axes)
func pcaMajorAxis(_ pts: [SIMD3<Float>]) -> (center: SIMD3<Float>, axis: SIMD3<Float>) {
    // compute mean, covariance (Accelerate), eigenvectors
    // return center and principal axis (largest eigenvalue)
}

6.4 ICP loop (point-to-plane, trimmed)

Pseudocode (core math hidden for brevity):

func icpPointToPlane(model: Cloud, scan: Cloud, seed: simd_float4x4, params: ICPParams) -> (pose: simd_float4x4, rmse: Float, inliers: Float) {
    var T = seed
    for _ in 0..<params.maxIterations {
        // 1) transform model points by T
        // 2) find nearest scan point (grid buckets/kNN)
        // 3) build correspondences with normal angle & distance checks
        // 4) compute point-to-plane residuals r_i = n_s^T ( (R m_i + t) - s_i )
        // 5) trim top (1 - trimFraction) largest |r_i|
        // 6) solve normal equations with Huber weights → Δξ in se(3)
        // 7) update T ← exp(Δξ) ∘ T
        // 8) check ΔRMSE stop condition
    }
    return (T, rmse, inlierFrac)
}

7) UI/UX notes

Live coverage bar showing estimated scanned surface area vs. target (just a heuristic from scan BB).

Align button becomes active after minimal coverage (e.g., 30–40%).

Status HUD: level (“coarse/mid/fine”), iters, RMSE, inliers.

Nudge mode: small step arrows (±1 cm, ±1° around up).

Accept / Save: persists pose + world map, shows “Auto-place next time.”

8) Accuracy, performance, and guardrails

Expect 1–2 cm alignment error with decent coverage and good normals; better with rich geometry.

Keep point counts reasonable (≤ 80k fine level) to maintain 30–60 ms/iter on device.

If RMSE > 3× voxel on last level or inlier fraction < 0.45 → prompt user to scan more surfaces or retry seeds.

Use gravity & PCA every time to avoid mirrored/flipped placements in symmetric rooms.

Don’t optimize scale (LiDAR is metrically calibrated).

9) App requirements checklist

 USDZ placed in Assets (e.g., Room.usdz)

 Privacy: NSCameraUsageDescription

 Entitlements: none special beyond camera

 ARKit capability enabled

 Device gating (show message on non-LiDAR devices)

 Persist last AlignmentResult to reuse across launches

 Optional: “Reset world origin” developer toggle