# iPhone Integration Guide

This guide shows how to integrate the alignment server with your iPhone LiDAR scanning app.

## Server Overview

**Endpoint**: `POST http://YOUR_SERVER:6000/align`
**Input**: Raw OBJ file data (iPhone LiDAR scan)
**Output**: JSON with 4x4 transformation matrix

## Quick Start

### 1. Start the Server

```bash
cd spatial_intelligence
cargo build --release --bin align_server
./target/release/align_server
```

Server runs on `http://0.0.0.0:6000`

### 2. Test from Command Line

```bash
curl -X POST http://localhost:6000/align \
  --data-binary "@scan.obj" \
  -H "Content-Type: application/octet-stream"
```

## Response Format

```json
{
  "matrix": [
    [0.960, -0.281, -0.003, 0.0],
    [0.281,  0.960,  0.011, 0.0],
    [0.009, -0.010,  1.000, 0.0],
    [-1.596, -1.737,  0.098, 1.0]
  ],
  "translation": [-1.596, -1.737, 0.098],
  "rotation_angle_degrees": 16.3,
  "rotation_axis": [0.009, -0.010, 1.000],
  "icp_iterations": 100,
  "scan_points": 121427,
  "model_points": 13822,
  "floor_normal": [0.001, -0.001, 1.000]
}
```

## Swift Integration (ARKit)

### Step 1: Upload Scan

```swift
import Foundation

func alignScan(objData: Data, serverURL: String = "http://YOUR_SERVER:6000") async throws -> simd_float4x4 {
    let url = URL(string: "\(serverURL)/align")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = objData
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    
    let (data, response) = try await URLSession.shared.data(for: request)
    
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return parseTransformMatrix(from: json)
}
```

### Step 2: Parse Transform Matrix

```swift
func parseTransformMatrix(from json: [String: Any]) -> simd_float4x4 {
    guard let matrixArray = json["matrix"] as? [[Float]] else {
        fatalError("Invalid matrix format")
    }
    
    // Server sends column-major format (perfect for simd_float4x4)
    let col0 = simd_float4(matrixArray[0][0], matrixArray[0][1], matrixArray[0][2], matrixArray[0][3])
    let col1 = simd_float4(matrixArray[1][0], matrixArray[1][1], matrixArray[1][2], matrixArray[1][3])
    let col2 = simd_float4(matrixArray[2][0], matrixArray[2][1], matrixArray[2][2], matrixArray[2][3])
    let col3 = simd_float4(matrixArray[3][0], matrixArray[3][1], matrixArray[3][2], matrixArray[3][3])
    
    return simd_float4x4(columns: (col0, col1, col2, col3))
}
```

### Step 3: Apply Transform in ARKit

```swift
import ARKit

class RoomAlignmentManager {
    var roomModel: ModelEntity?
    
    func alignRoomModel(with scanURL: URL) async {
        do {
            // Load scan OBJ data
            let scanData = try Data(contentsOf: scanURL)
            
            // Get transformation from server
            let transform = try await alignScan(objData: scanData)
            
            // Apply transformation to room model in ARKit
            guard let model = roomModel else { return }
            
            // Convert to ARKit coordinate system (Y-up is already correct!)
            model.transform = Transform(matrix: transform)
            
            print("✅ Room model aligned!")
            print("Translation: \(transform.columns.3)")
            
        } catch {
            print("❌ Alignment failed: \(error)")
        }
    }
}
```

### Complete Example

```swift
import SwiftUI
import RealityKit
import ARKit

struct ARAlignmentView: View {
    @StateObject var arManager = ARAlignmentManager()
    
    var body: some View {
        ZStack {
            ARViewContainer(arManager: arManager)
            
            VStack {
                Spacer()
                Button("Align Room Model") {
                    Task {
                        await arManager.alignWithServer()
                    }
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
    }
}

class ARAlignmentManager: ObservableObject {
    var arView: ARView?
    var roomModelAnchor: AnchorEntity?
    
    func alignWithServer() async {
        // 1. Export current LiDAR scan to OBJ
        guard let objData = await exportScanToOBJ() else {
            print("❌ Failed to export scan")
            return
        }
        
        // 2. Send to server
        do {
            let transform = try await alignScan(objData: objData)
            
            // 3. Apply transform to room model
            await MainActor.run {
                roomModelAnchor?.transform = Transform(matrix: transform)
                print("✅ Alignment complete!")
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }
    
    func exportScanToOBJ() async -> Data? {
        // Export ARFrame mesh as OBJ
        // Use ARMeshAnchor or your scanning library
        // Return OBJ file data
        return nil // Implement based on your scanning method
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arManager: ARAlignmentManager
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arManager.arView = arView
        
        // Configure ARView for LiDAR scanning
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        arView.session.run(config)
        
        // Load room model
        loadRoomModel(into: arView)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    func loadRoomModel(into arView: ARView) {
        // Load your room.obj model
        guard let modelEntity = try? ModelEntity.loadModel(named: "room.obj") else {
            return
        }
        
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(modelEntity)
        arView.scene.addAnchor(anchor)
        
        arManager.roomModelAnchor = anchor
    }
}
```

## Server Configuration

### Environment Variables

```bash
# Server port (default: 3000)
export PORT=3000

# Model file location
export MODEL_PATH=assets/room.obj
```

### Production Deployment

```bash
# Build optimized binary
cargo build --release --bin align_server

# Run with systemd (Linux) or launchd (macOS)
./target/release/align_server

# Or with Docker
docker build -t alignment-server .
docker run -p 3000:6000 -v $(pwd)/assets:/app/assets alignment-server
```

## API Reference

### POST /align

**Request**:
- Method: `POST`
- Content-Type: `application/octet-stream`
- Body: Raw OBJ file data (iPhone LiDAR scan)

**Response**:
```json
{
  "matrix": [[f32; 4]; 4],              // Column-major 4x4 transform
  "translation": [f32; 3],               // [x, y, z] in meters
  "rotation_angle_degrees": f32,         // Rotation angle
  "rotation_axis": [f32; 3],             // Normalized rotation axis
  "icp_iterations": usize,               // Number of ICP iterations (100)
  "scan_points": usize,                  // Number of points in scan
  "model_points": usize,                 // Number of points in model
  "floor_normal": [f32; 3]               // Detected floor normal
}
```

**Error Response**:
```json
{
  "error": "Error message"
}
```

Status codes:
- `200 OK` - Success
- `400 Bad Request` - Empty body or invalid data
- `500 Internal Server Error` - Processing failed

## Performance

- **Scan size**: 100K-200K points (typical iPhone LiDAR)
- **Processing time**: ~5-10 seconds
- **Memory usage**: ~200MB during processing
- **Network**: Scan file ~5-10MB

## Troubleshooting

### "Address already in use"
```bash
pkill -9 align_server
```

### "Model file not found"
Place `room.obj` in `assets/` directory before starting server.

### "Too many duplicate points"
- Increase voxel downsampling in server
- Or pre-filter your scan before uploading

### Connection timeout
- Increase timeout in Swift URLRequest
- Server processing can take 5-10 seconds for large scans

## Tips

1. **Coordinate System**: Both scan and model assumed to be Y-up (iPhone/Blender standard)
2. **File Size**: Server accepts up to 100MB OBJ files
3. **Caching**: Consider caching the transformation if model doesn't change
4. **Preview**: Test with `assets/room_scan.obj` before using real iPhone scans

## Example Test

```bash
# Test the server
curl -X POST http://localhost:6000/align \
  --data-binary "@assets/room_scan.obj" \
  -H "Content-Type: application/octet-stream" \
  -s | jq '.translation, .rotation_angle_degrees'
```

Expected output:
```json
[-1.596, -1.737, 0.098]
16.3
```

---

**Need help?** Check the logs: `tail -f server.log`
