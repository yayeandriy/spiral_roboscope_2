
# ScanRegistrationKit (Swift Package)

**Goal:** Register a local USDZ/CAD model to an iPhone/iPad LiDAR scan (point cloud / mesh) **fully on-device** and return a world-space pose to place the model in AR.

This package is designed to drop into your existing app where you already:
- scan with ARKit and can **save/load** the scan
- load the **target model** (USDZ) into the same 3D view
- have a **button** to start registration

## What you get

- A complete **registration pipeline**:
  - Preprocessing → point-cloud **pyramid**
  - **Coarse seeds** (gravity/PCA/yaw variants)
  - **Robust ICP** (point-to-plane, trimmed + Huber)
- Clear **data models** (`PointCloud`, `Pose`, `RegistrationMetrics`)
- A single **Coordinator** you can call from your button

> Works on iOS 17+ with LiDAR devices. RealityKit/ARKit not strictly required for running the math (you can feed your own clouds).

---

## Quick Start (Integrate in your app)

1) **Add Swift Package**
   - Xcode → Project → Package Dependencies → `Add Local...`
   - Choose this folder (`ScanRegistrationKit`).
   - Or keep as a subfolder and add as a local package.

2) **Feed your clouds**

You already have:
- `scanCloud`: your fused scan as `[SIMD3<Float>]` (or triangles).
- `modelCloud`: samples from your USDZ (or we can sample via your existing mesh).

Convert to `PointCloud`:

```swift
import ScanRegistrationKit
let scanPC = PointCloud.fromSIMD(points: scanPointsSIMD)
let modelPC = PointCloud.fromSIMD(points: modelPointsSIMD)
```

3) **Run registration when the button is pressed**

```swift
let pipeline = RegistrationPipeline.defaultPipeline()

let params = RegistrationRequest(
    scan: scanPC,
    model: modelPC,
    gravityUp: gravityVector,              // from ARKit or your app; use [0,1,0] if unknown
    voxelPyramid: [0.02, 0.01, 0.007],     // meters
    seedYawDegrees: [-90, -45, 0, 45, 90], // adjust as needed
    trimFraction: 0.7
)

let result = pipeline.register(request: params)

switch result {
case .success(let out):
    // out.poseModelInWorld.matrix is your SE(3) transform.
    // Apply to your ModelEntity / Scene node:
    let T = out.poseModelInWorld.matrix
    // yourARPlacementService.apply(pose: T)
    print("RMSE:", out.metrics.rmseMeters, "Inliers:", out.metrics.inlierFraction)
case .failure(let err):
    print("Registration failed:", err.localizedDescription)
}
```

4) **Tune thresholds** in `ICPParams` / `RegistrationRequest`.

---

## Files overview

- `PoseTypes.swift` — `Pose`, `PointCloud`, `RegistrationMetrics` (Codable)
- `VoxelGrid.swift` — voxelization, spatial hash, nearest neighbor
- `NormalEstimation.swift` — normals via local PCA
- `PreprocessService.swift` — filtering + pyramid construction
- `CoarsePoseEstimator.swift` — gravity/PCA seeds + yaw variants + quick scoring
- `ICPRefiner.swift` — robust point-to-plane ICP (trimmed, Huber, 6×6 solve)
- `RegistrationPipeline.swift` — single entry point for apps
- `SIMDExt.swift` — matrix/vec helpers (SE(3) incremental updates)
- `README.md` — this guide

---

## Performance notes

- Keep finest level ≤ ~80k points.
- Use 3 levels (2cm → 1cm → 7mm) for rooms.
- iPhone Pro/Max can typically handle 10–30 ms/iter at these densities.
- If iterations are slow: reduce finest density or expand trim fraction.

---

## Quality gates

If `rmseMeters > 3 × finestVoxel` or `inlierFraction < 0.45`, prompt the user to scan more distinctive features (corners/furniture) and retry.

---

## License

MIT — do whatever you want; attribution appreciated.
