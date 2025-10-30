# Definitive ARKit Application Guide

## The Server is Working Correctly! ✅

The alignment algorithm is finding the correct transformation:
- Rotation: ~19-22° around Y-axis (vertical)
- Translation: Moves model to align with scan
- Floor detection: Y-axis is correctly identified as "up"

## Critical: How to Apply in ARKit

### ❌ WRONG - Common Mistakes

```swift
// DON'T DO THIS - transforms scan instead of model
scanMesh.transform = Transform(matrix: alignmentMatrix)  // ❌ WRONG!

// DON'T DO THIS - inverts the matrix
let inverted = alignmentMatrix.inverse
modelMesh.transform = Transform(matrix: inverted)  // ❌ WRONG!

// DON'T DO THIS - applies to both
scanMesh.transform = Transform(matrix: somethingElse)  // ❌ WRONG!
modelMesh.transform = Transform(matrix: alignmentMatrix)  // Confusing!
```

### ✅ CORRECT - Definitive Implementation

```swift
import RealityKit
import ARKit

// STEP 1: Get alignment matrix from server
let response = try await uploadScanAndAlign(scanOBJ: scanData)
let alignmentMatrix = response.matrix  // This is simd_float4x4

// STEP 2: Apply transformations

// The SCAN stays at identity (it's your reference frame, don't move it!)
scanMesh.transform = Transform.identity  // ✅ SCAN FIXED AT ORIGIN

// The MODEL gets the alignment matrix
roomModel.transform = Transform(matrix: alignmentMatrix)  // ✅ MODEL MOVES TO ALIGN

// That's it! The model should now align perfectly with the scan
```

### Complete Working Example

```swift
import RealityKit
import Foundation

class AlignmentController {
    var arView: ARView!
    var scanAnchor: AnchorEntity!
    var modelAnchor: AnchorEntity!
    
    func performAlignment(scanURL: URL, serverIP: String = "192.168.0.115") async throws {
        // 1. Load scan mesh from iPhone LiDAR
        let scanMesh = try await ModelEntity.load(contentsOf: scanURL)
        
        // 2. Load room model (your room.usdc)
        let roomModel = try await ModelEntity.load(named: "room.usdc")
        
        // 3. Create anchors
        scanAnchor = AnchorEntity()
        modelAnchor = AnchorEntity()
        
        // 4. Add to scene
        arView.scene.addAnchor(scanAnchor)
        arView.scene.addAnchor(modelAnchor)
        
        scanAnchor.addChild(scanMesh)
        modelAnchor.addChild(roomModel)
        
        // 5. Upload scan to server and get alignment
        let scanData = try Data(contentsOf: scanURL)
        let url = URL(string: "http://\(serverIP):6000/align")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = scanData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let matrixArray = json["matrix"] as! [[Float]]
        
        // 6. Parse matrix
        let col0 = simd_float4(matrixArray[0][0], matrixArray[0][1], matrixArray[0][2], matrixArray[0][3])
        let col1 = simd_float4(matrixArray[1][0], matrixArray[1][1], matrixArray[1][2], matrixArray[1][3])
        let col2 = simd_float4(matrixArray[2][0], matrixArray[2][1], matrixArray[2][2], matrixArray[2][3])
        let col3 = simd_float4(matrixArray[3][0], matrixArray[3][1], matrixArray[3][2], matrixArray[3][3])
        let alignmentMatrix = simd_float4x4(columns: (col0, col1, col2, col3))
        
        // 7. Apply transformations - THIS IS THE CRITICAL PART!
        
        // SCAN STAYS FIXED (identity transform)
        scanMesh.transform = Transform.identity
        
        // MODEL GETS THE ALIGNMENT MATRIX
        roomModel.transform = Transform(matrix: alignmentMatrix)
        
        // 8. Log for debugging
        print("✅ Alignment applied!")
        print("   Scan transform: \(scanMesh.transform)")
        print("   Model transform: \(roomModel.transform)")
        print("   Rotation: \(json["rotation_angle_degrees"] as! Float)°")
        print("   Translation: \(json["translation"] as! [Float])")
    }
}
```

## Debugging Checklist

If alignment still looks wrong, check:

### 1. Verify Scan is at Identity
```swift
print("Scan transform: \(scanMesh.transform)")
// Should print: Transform(translation: (0.0, 0.0, 0.0), rotation: (angle: 0.0, axis: (0.0, 0.0, 0.0)))
```

### 2. Verify Model Has Transform
```swift
print("Model transform: \(roomModel.transform)")
// Should have non-zero translation and rotation
```

### 3. Check Matrix Parsing
```swift
let matrixArray = json["matrix"] as! [[Float]]
print("Matrix from server:")
for (i, col) in matrixArray.enumerated() {
    print("  Col \(i): \(col)")
}

// Verify column-major construction
let col0 = simd_float4(matrixArray[0][0], matrixArray[0][1], matrixArray[0][2], matrixArray[0][3])
print("Column 0: \(col0)")
```

### 4. Visualize with Semi-Transparent Materials
```swift
// Make scan blue and semi-transparent
scanMesh.model?.materials = [SimpleMaterial(
    color: UIColor.blue.withAlphaComponent(0.5),
    isMetallic: false
)]

// Make model red and semi-transparent  
roomModel.model?.materials = [SimpleMaterial(
    color: UIColor.red.withAlphaComponent(0.5),
    isMetallic: false
)]

// Blue (scan) and red (model) should overlap where geometry matches
```

### 5. Check Model and Scan Are Both Y-Up
```swift
// Both room.usdc and scan.obj must be in Y-up coordinate system
// In Blender: Export settings → Up Axis: Y Up
// In USDC: Verify upAxis = "Y"
```

## The Mathematics

### What the Server Computes

```
Given:
- scan.obj (from iPhone, Y-up coordinates)
- room.obj (from assets, Y-up coordinates)

Server computes:
1. T0 = translation from model centroid → scan centroid
2. T_icp = ICP refinement (rotation + fine translation)  
3. T_final = T_icp * T0

T_final transforms: room model points → scan frame
```

### What ARKit Should Do

```swift
// In ARKit scene:
let scanPoint_in_world = scan.transform * scanPoint_local  // = scanPoint_local (identity)
let modelPoint_in_world = model.transform * modelPoint_local  // = T_final * modelPoint_local

// After alignment:
// modelPoint_in_world ≈ corresponding scanPoint_in_world
```

### Coordinate System Verification

```
Y-up (ARKit, iPhone, Blender default):
    Y↑ (up)
    |
    |
    +--→X (right)
   /
  Z (forward)

Both scan and room.usdc MUST use this!
```

## Common Issues and Solutions

### Issue: Model appears in different location
**Solution**: Scan is not at identity. Set `scanMesh.transform = .identity`

### Issue: Model is rotated wrong
**Solution**: You're inverting the matrix or applying to wrong object

### Issue: Model is completely elsewhere
**Solution**: Matrix is being applied to scan instead of model

### Issue: Both scan and model move
**Solution**: Don't transform scan. Only transform model.

### Issue: No alignment at all
**Solution**: Check room.usdc and scan.obj are both Y-up coordinate system

## Final Verification

After applying the transform, the model should:
1. ✅ Be at roughly the same height as scan (Y translation applied)
2. ✅ Be rotated to match scan orientation (rotation around Y-axis)
3. ✅ Be positioned to overlap scan geometry (X,Z translation applied)

The scan should:
1. ✅ Stay exactly where it was loaded (identity transform)
2. ✅ Not move or rotate at all
3. ✅ Serve as the reference frame

---

**The server is working correctly. The issue is in how the matrix is being applied in ARKit. Follow the code above exactly.**
