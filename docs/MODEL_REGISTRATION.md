# Model Registration Documentation

## Overview

The model registration system aligns a CAD model (USDC/USDZ/GLB) with a LiDAR scan (OBJ) using a constrained Iterative Closest Point (ICP) algorithm. The registration computes a transformation that places the CAD model in the same coordinate system as the scan.

## Registration Process

### 1. Input
- **Primary Model**: USDC/USDZ/GLB file with architectural/design geometry
- **Scan Model**: OBJ file from ARKit LiDAR scanning
- Both models are loaded into SceneKit as `SCNNode` instances

### 2. Algorithm Steps

#### A. Point Cloud Extraction
```swift
// Extract vertices from both models
let primaryPoints = extractPointCloud(from: primaryModelNode, sampleCount: 5000)
let scanPoints = extractPointCloud(from: scanModelNode, sampleCount: 10000)
```

Points are extracted in **world space** coordinates to ensure both models are in the same reference frame.

#### B. Coarse Yaw Initialization
```swift
// Try 36 angles (every 10°) to find rough alignment
let initialYaw = findBestInitialYaw(
    modelPoints: primaryPoints,
    scanPoints: scanPoints,
    modelCentroid: modelCentroid,
    scanCentroid: scanCentroid
)
```

This handles large rotational misalignments that ICP alone cannot resolve.

#### C. ICP Refinement
- Iteratively finds closest point correspondences
- Computes optimal yaw-only rotation + translation
- Refines alignment until convergence (RMSE change < threshold)

### 3. Output: Registration Result

```swift
struct RegistrationResult {
    let transformMatrix: simd_float4x4  // 4x4 homogeneous transform
    let rmse: Float                     // Root mean squared error (meters)
    let inlierFraction: Float           // Fraction of points within 10cm
    let iterations: Int                 // Number of ICP iterations
}
```

#### Transform Matrix Format
The `transformMatrix` is a 4×4 homogeneous transformation in **world space**:

```
[  Rxx   Rxy   Rxz   0  ]
[  Ryx   Ryy   Ryz   0  ]
[  Rzx   Rzy   Rzz   0  ]
[  Tx    Ty    Tz    1  ]
```

Where:
- **R** (3×3): Rotation matrix (constrained to yaw-only around Y axis)
  - For yaw angle θ: `Rxx = cos(θ)`, `Rxz = sin(θ)`, `Rzx = -sin(θ)`, `Rzz = cos(θ)`
  - Middle row: `[0, 1, 0]` (no rotation around Y)
- **T** (3×1): Translation vector `(Tx, Ty, Tz)` in meters
- Bottom row: `[0, 0, 0, 1]` (homogeneous coordinates)

#### Example Result
```
Final transform matrix:
  [SIMD4<Float>(0.9995685, 0.0, 0.029373294, 0.0)]   // X axis (rotated)
  [SIMD4<Float>(0.0, 1.0, 0.0, 0.0)]                  // Y axis (unchanged)
  [SIMD4<Float>(-0.029373294, 0.0, 0.9995685, 0.0)]  // Z axis (rotated)
  [SIMD4<Float>(2.023, -1.085, -0.615, 1.0)]         // Translation + homogeneous

Final translation: (2.023, -1.085, -0.615) meters
Yaw angle: ~1.68° (0.029 radians)
RMSE: 0.264 meters
Inlier fraction: 43.8%
```

## Scale Considerations

### Current Behavior
The registration **does NOT compute scale**—it assumes both models are at the same scale. This is a rigid transformation (rotation + translation only).

### Scale Scenarios

#### 1. Models Already at Same Scale
✅ **Current implementation works**
- CAD model and scan were created at real-world dimensions
- Example: Scan is 9.1m × 3.1m, CAD is 7.8m × 2.8m → similar scale

#### 2. Models at Different Scales
❌ **Requires modification**

**Symptoms:**
- Good alignment in one area, but models diverge elsewhere
- RMSE remains high despite good centroid alignment
- Inlier fraction is very low

**Solution: Add Uniform Scale Factor**

Modify the algorithm to use **Umeyama's method** (similarity transformation):

```swift
struct RegistrationResult {
    let transformMatrix: simd_float4x4
    let scale: Float  // ← Add this
    let rmse: Float
    let inlierFraction: Float
    let iterations: Int
}

// In ICP computation:
let scale = computeOptimalScale(correspondences: correspondences)
// Apply: transformed = scale * (R * point + t)
```

Implementation sketch:
```swift
private static func computeOptimalScale(
    correspondences: [(model: SIMD3<Float>, scan: SIMD3<Float>)]
) -> Float {
    var modelVar: Float = 0
    var scanVar: Float = 0
    
    let modelCentroid = // ... compute centroid
    let scanCentroid = // ... compute centroid
    
    for (m, s) in correspondences {
        let mp = m - modelCentroid
        let sp = s - scanCentroid
        modelVar += length_squared(mp)
        scanVar += length_squared(sp)
    }
    
    return sqrt(scanVar / modelVar)
}
```

**When to enable:**
- Add a toggle in the UI: "Match Scale" checkbox
- Or auto-detect when `abs(modelBounds.size - scanBounds.size) / scanBounds.size > 0.3` (30% difference)

### 3. Models with Non-Uniform Scale
🔴 **Not supported**

If one dimension is scaled differently (e.g., height scaled 2×, width/depth 1×), the registration will fail. This requires full affine transformation, which is beyond typical ICP.

## Persistence Options

### Option 1: Store Transform in Space Model (Recommended)

**Pros:**
- Registration survives app restarts
- Can show aligned view by default
- Easy to toggle between "original" and "registered" poses

**Implementation:**

```swift
// In Models/Space.swift
struct Space: Codable, Identifiable {
    let id: UUID
    let name: String
    let modelGlbUrl: String?
    let modelUsdcUrl: String?
    let scanUrl: String?
    
    // Add registration data
    var registrationTransform: RegistrationTransform?
    var registrationDate: Date?
}

struct RegistrationTransform: Codable {
    let matrix: [Float]  // 16 floats for 4x4 matrix (stored row-major)
    let rmse: Float
    let inlierFraction: Float
    let scale: Float?    // Optional for future scaling support
    
    var simdMatrix: simd_float4x4 {
        simd_float4x4(rows: [
            SIMD4<Float>(matrix[0], matrix[1], matrix[2], matrix[3]),
            SIMD4<Float>(matrix[4], matrix[5], matrix[6], matrix[7]),
            SIMD4<Float>(matrix[8], matrix[9], matrix[10], matrix[11]),
            SIMD4<Float>(matrix[12], matrix[13], matrix[14], matrix[15])
        ])
    }
    
    init(matrix: simd_float4x4, rmse: Float, inlierFraction: Float, scale: Float? = nil) {
        self.matrix = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
        self.rmse = rmse
        self.inlierFraction = inlierFraction
        self.scale = scale
    }
}
```

**Usage:**

```swift
// After registration completes
await MainActor.run {
    var updatedSpace = space
    updatedSpace.registrationTransform = RegistrationTransform(
        matrix: result.transformMatrix,
        rmse: result.rmse,
        inlierFraction: result.inlierFraction
    )
    updatedSpace.registrationDate = Date()
    
    // Save to backend or local storage
    SpaceService.shared.updateSpace(updatedSpace)
}

// When loading space
if let regTransform = space.registrationTransform {
    primaryModelNode.simdTransform = regTransform.simdMatrix * originalTransform
    print("Applied saved registration from \(space.registrationDate)")
}
```

### Option 2: Export Aligned Model

**Pros:**
- CAD model is permanently aligned
- Works in external 3D tools (Blender, RealityComposer, etc.)
- No need to recompute alignment

**Cons:**
- Larger file size (need to store both original and aligned)
- Harder to undo/re-register

**Implementation:**

```swift
func exportAlignedModel(space: Space, transform: simd_float4x4) async throws -> URL {
    // Load original model
    let originalURL = URL(string: space.modelUsdcUrl!)!
    let scene = try SCNScene(url: originalURL)
    
    // Apply transform to root nodes
    for node in scene.rootNode.childNodes {
        node.simdTransform = transform * node.simdTransform
    }
    
    // Export to new file
    let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let outputURL = documentsDir
        .appendingPathComponent(space.name + "_aligned")
        .appendingPathExtension("usdc")
    
    scene.write(to: outputURL, options: nil, delegate: nil) { totalProgress, error, stop in
        print("Export progress: \(totalProgress)")
    }
    
    return outputURL
}
```

### Option 3: Real-Time Transform (Current Implementation)

**Pros:**
- No storage needed
- Can re-register at any time
- Useful for testing/development

**Cons:**
- User must re-register after each app launch
- Registration takes 2-5 seconds

**Current code:**
```swift
// In Space3DViewer.swift
onRegistrationComplete: { result in
    self.registrationResult = result
    // Transform is applied to node but not saved
}
```

## Recommended Approach

### Phase 1: Add Persistence (Priority 1)
1. Add `registrationTransform` field to `Space` model
2. Save transform after successful registration
3. Auto-apply on space load if available
4. Show indicator: "Using registration from Jan 15, 2025"

### Phase 2: Add UI Controls (Priority 2)
1. Toggle: "Show Aligned" vs "Show Original"
2. Button: "Clear Registration"
3. Quality indicator: Show RMSE and inlier fraction
4. Option to re-register if quality is poor

### Phase 3: Add Scale Support (Priority 3, if needed)
1. Detect scale mismatch: `abs(1 - modelSize/scanSize) > 0.3`
2. Compute uniform scale factor in ICP
3. Show scale value in UI: "Model scaled 0.87× to match scan"
4. Option to "Lock Scale" (disable scale estimation)

## API for External Use

If registration needs to be used from other parts of the app:

```swift
// In SpaceService.swift
extension SpaceService {
    func registerModel(space: Space) async throws -> RegistrationResult {
        // Extract models
        let primaryNode = await loadModel(url: space.modelUsdcUrl)
        let scanNode = await loadModel(url: space.scanUrl)
        
        // Run registration
        let result = await ModelRegistrationService.registerModels(
            modelPoints: extractPointCloud(from: primaryNode),
            scanPoints: extractPointCloud(from: scanNode)
        )
        
        // Save result
        var updatedSpace = space
        updatedSpace.registrationTransform = RegistrationTransform(
            matrix: result.transformMatrix,
            rmse: result.rmse,
            inlierFraction: result.inlierFraction
        )
        
        try await updateSpace(updatedSpace)
        return result
    }
    
    func clearRegistration(space: Space) async throws {
        var updatedSpace = space
        updatedSpace.registrationTransform = nil
        updatedSpace.registrationDate = nil
        try await updateSpace(updatedSpace)
    }
}
```

## Quality Metrics

### Good Registration
- **RMSE < 0.15m** (15cm average error)
- **Inlier fraction > 50%** (half of points within 10cm)
- **Visual alignment**: Walls, floors, major features match

### Acceptable Registration
- **RMSE < 0.30m** (30cm average error)
- **Inlier fraction > 30%**
- May need manual refinement in some areas

### Poor Registration (Re-register recommended)
- **RMSE > 0.50m**
- **Inlier fraction < 20%**
- Visible misalignment

Show these in the UI after registration:
```swift
struct RegistrationResultView: View {
    let result: RegistrationResult
    
    var qualityColor: Color {
        if result.rmse < 0.15 { return .green }
        if result.rmse < 0.30 { return .yellow }
        return .red
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(qualityColor)
                Text("Registration Complete")
                    .font(.headline)
            }
            
            Text("Accuracy: \(Int(result.rmse * 100))cm average error")
            Text("Quality: \(Int(result.inlierFraction * 100))% points aligned")
            Text("Iterations: \(result.iterations)")
            
            if result.rmse > 0.30 {
                Text("⚠️ Quality is low. Try re-registering.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}
```

## Future Enhancements

### 1. Multi-Model Registration
Register multiple CAD models to the same scan:
- Store transform per model
- Use first registration as reference for subsequent ones

### 2. Partial Registration
Register only specific rooms/areas:
- Allow user to select region of interest
- Crop point clouds before ICP

### 3. Feature-Based Registration
Improve robustness with semantic features:
- Detect corners, edges, planes
- Match features before ICP
- Better handling of sparse scans

### 4. Registration History
Track multiple registration attempts:
```swift
struct RegistrationHistory: Codable {
    let attempts: [RegistrationAttempt]
    
    struct RegistrationAttempt {
        let date: Date
        let transform: RegistrationTransform
        let userNote: String?
    }
}
```

## Troubleshooting

### Registration Fails (No Result)
- **Cause**: No correspondences found
- **Fix**: Ensure models overlap in space, adjust correspondence threshold

### Registration Converges but Alignment is Wrong
- **Cause**: Local minimum in ICP
- **Fix**: Improve initial yaw search (try 72 angles instead of 36)

### Models at Different Heights
- **Cause**: Y-axis translation is wrong
- **Fix**: Ensure floor/ground plane is at Y=0 in both models

### One Model is Upside Down
- **Cause**: Different coordinate system conventions
- **Fix**: Pre-rotate model 180° around X before registration

## Summary

The registration system produces a **4×4 transformation matrix** that aligns a CAD model to a scan. To make it persistent:

1. **Store the matrix** in the `Space` model as a `RegistrationTransform` struct
2. **Apply on load** by setting `node.simdTransform = savedTransform * originalTransform`
3. **Add UI controls** to show/hide alignment and view quality metrics
4. **Consider scale** if models have significant size differences

This enables a "register once, use forever" workflow where aligned models are saved and automatically applied on subsequent views.
