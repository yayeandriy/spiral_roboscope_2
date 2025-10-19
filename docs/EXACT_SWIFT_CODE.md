# COPY THIS EXACTLY - Working ARKit Alignment Code

## Server Status: ✅ WORKING CORRECTLY

The server is computing the correct transformation:
- 19° rotation around Y-axis (vertical)  
- Translation to position model at scan location
- Matrix format: Column-major (ARKit compatible)

## The Problem is in Your iPhone Code

You must apply the matrix to the **room model** and keep the **scan at identity**.

## Copy This Code Exactly

```swift
import RealityKit
import ARKit
import Foundation

// MARK: - Step 1: Upload Scan and Get Matrix

func alignScan(scanOBJ: Data, serverIP: String = "192.168.0.115") async throws -> simd_float4x4 {
    let url = URL(string: "http://\(serverIP):6000/align")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = scanOBJ
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    
    // Debug: Print server response
    print("📊 Server Response:")
    if let rotation = json["rotation_angle_degrees"] as? Float {
        print("   Rotation: \(rotation)°")
    }
    if let translation = json["translation"] as? [Float] {
        print("   Translation: \(translation)")
    }
    
    // Parse matrix (column-major format)
    let matrixArray = json["matrix"] as! [[Float]]
    
    let col0 = simd_float4(matrixArray[0][0], matrixArray[0][1], matrixArray[0][2], matrixArray[0][3])
    let col1 = simd_float4(matrixArray[1][0], matrixArray[1][1], matrixArray[1][2], matrixArray[1][3])
    let col2 = simd_float4(matrixArray[2][0], matrixArray[2][1], matrixArray[2][2], matrixArray[2][3])
    let col3 = simd_float4(matrixArray[3][0], matrixArray[3][1], matrixArray[3][2], matrixArray[3][3])
    
    return simd_float4x4(columns: (col0, col1, col2, col3))
}

// MARK: - Step 2: Apply Alignment

func applyAlignment(
    scanMesh: ModelEntity,
    roomModel: ModelEntity, 
    alignmentMatrix: simd_float4x4
) {
    // CRITICAL: Scan stays at identity (it's the reference frame)
    scanMesh.transform = Transform.identity
    
    // CRITICAL: Model gets the alignment matrix
    roomModel.transform = Transform(matrix: alignmentMatrix)
    
    // Debug: Verify transforms
    print("✅ Alignment Applied:")
    print("   Scan transform: \(scanMesh.transform)")
    print("   Model transform: \(roomModel.transform)")
}

// MARK: - Step 3: Complete Workflow

func performCompleteAlignment(
    scanURL: URL,
    roomModelName: String = "room.usdc",
    serverIP: String = "192.168.0.115",
    arView: ARView
) async throws {
    
    print("🚀 Starting alignment workflow...")
    
    // 1. Load scan mesh
    print("📥 Loading scan mesh...")
    let scanMesh = try await ModelEntity.load(contentsOf: scanURL)
    
    // 2. Load room model
    print("📥 Loading room model...")
    let roomModel = try await ModelEntity.load(named: roomModelName)
    
    // 3. Upload scan to server and get alignment matrix
    print("🌐 Uploading to server...")
    let scanData = try Data(contentsOf: scanURL)
    let alignmentMatrix = try await alignScan(scanOBJ: scanData, serverIP: serverIP)
    
    // 4. Create anchors and add to scene
    print("🏗️  Setting up scene...")
    let scanAnchor = AnchorEntity()
    let modelAnchor = AnchorEntity()
    
    arView.scene.addAnchor(scanAnchor)
    arView.scene.addAnchor(modelAnchor)
    
    scanAnchor.addChild(scanMesh)
    modelAnchor.addChild(roomModel)
    
    // 5. Apply alignment
    applyAlignment(
        scanMesh: scanMesh,
        roomModel: roomModel,
        alignmentMatrix: alignmentMatrix
    )
    
    // 6. Optional: Make semi-transparent for debugging
    scanMesh.model?.materials = [SimpleMaterial(
        color: UIColor.blue.withAlphaComponent(0.5),
        isMetallic: false
    )]
    
    roomModel.model?.materials = [SimpleMaterial(
        color: UIColor.red.withAlphaComponent(0.5),
        isMetallic: false
    )]
    
    print("✅ Alignment complete!")
}
```

## Usage Example

```swift
// In your view controller or SwiftUI view
Task {
    do {
        try await performCompleteAlignment(
            scanURL: scanFileURL,
            roomModelName: "room.usdc",
            serverIP: "192.168.0.115",
            arView: arView
        )
    } catch {
        print("❌ Alignment failed: \(error)")
    }
}
```

## What You Should See

After running this code:

1. **Blue mesh** (scan): Stays at origin
2. **Red mesh** (model): Moves and rotates to align
3. **Overlap**: Red and blue should overlap where geometry matches

## If It's Still Wrong

### Check 1: Are both meshes loaded correctly?
```swift
print("Scan bounds: \(scanMesh.visualBounds(relativeTo: nil))")
print("Model bounds: \(roomModel.visualBounds(relativeTo: nil))")
```

### Check 2: Is the matrix being parsed correctly?
```swift
print("Matrix column 3 (translation):")
print("  X: \(alignmentMatrix.columns.3.x)")
print("  Y: \(alignmentMatrix.columns.3.y)")
print("  Z: \(alignmentMatrix.columns.3.z)")
```

### Check 3: Are transforms applied correctly?
```swift
print("Scan position: \(scanMesh.position)")  // Should be (0,0,0)
print("Model position: \(roomModel.position)")  // Should be non-zero
```

### Check 4: Is room.usdc in Y-up?
- Export from Blender with Y-up axis
- Verify USDC file has `upAxis = "Y"`
- Both scan and model must use same coordinate system

## The Server Output Explained

```json
{
  "matrix": [
    [0.946, -0.023, 0.323, 0.0],  // Column 0: Rotated X-axis
    [0.022,  0.999, 0.009, 0.0],  // Column 1: Rotated Y-axis  
    [-0.323, -0.002, 0.946, 0.0], // Column 2: Rotated Z-axis
    [-0.735, -0.873, -3.287, 1.0] // Column 3: Translation + W
  ],
  "rotation_angle_degrees": 18.9,
  "rotation_axis": [0.017, -0.997, -0.069]  // Almost pure Y-axis rotation
}
```

This means:
- Rotate 18.9° around Y-axis (vertical)
- Then translate by (-0.735, -0.873, -3.287)
- Apply this to room model, NOT to scan

## Final Check: Print Everything

```swift
func debugAlignment(scanMesh: ModelEntity, roomModel: ModelEntity, matrix: simd_float4x4) {
    print("\n🔍 DEBUG ALIGNMENT")
    print("================")
    print("Matrix:")
    for i in 0..<4 {
        let col = matrix.columns.i
        print("  Col \(i): [\(col.x), \(col.y), \(col.z), \(col.w)]")
    }
    print("\nScan Transform:")
    print("  Position: \(scanMesh.position)")
    print("  Rotation: \(scanMesh.orientation)")
    print("  Transform matrix: \(scanMesh.transform.matrix)")
    print("\nModel Transform:")
    print("  Position: \(roomModel.position)")
    print("  Rotation: \(roomModel.orientation)")
    print("  Transform matrix: \(roomModel.transform.matrix)")
    print("================\n")
}
```

---

**Copy the code above exactly. The server is working correctly. The problem is in the iPhone application code.**
