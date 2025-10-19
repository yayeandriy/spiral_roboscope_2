# Model Alignment Feature

## Overview

The "Fix model" button allows you to automatically align a placed 3D model (room.usdc) with the real-world environment using LiDAR scanning and a remote alignment server.

## How It Works

### 1. Place Model
- Tap the **"Place model"** button (cube icon, bottom-right)
- Model appears 1.5m in front of camera
- Button turns green when model is placed

### 2. Fix Model (Alignment)
- **"Fix model"** button appears next to the placed model button (orange color)
- Tap **"Fix model"** to start alignment scanning
- Button changes to **"Stop scan"** (red) while scanning is active
- Scanner collects LiDAR mesh data of the real environment

### 3. Stop Scan & Align
- Tap **"Stop scan"** to finish scanning
- App automatically:
  1. Exports the scanned mesh to OBJ format
  2. Sends it to the alignment server (localhost:6000/align)
  3. Receives a 4x4 transformation matrix
  4. Applies the transformation to the placed model
- Progress overlay shows each step

### 4. Result
- Model is now aligned with the real-world space
- Remove model by tapping the cube button again

## Server Configuration

The alignment server URL is currently set to:
```swift
let serverURL = "http://localhost:6000/align"
```

### Change Server URL

Edit `ContentView.swift`, line ~470:
```swift
// Replace localhost with your server IP/domain
let serverURL = "http://YOUR_SERVER_IP:6000/align"
```

### Server Requirements

See `SPATIAL_INTELLIGENCE_INTEGRATION.md` for:
- Starting the Rust alignment server
- Server API specification
- Response format
- Testing commands

## UI Elements

### Buttons
1. **Place model** (bottom-right, circular)
   - Icon: cube / cube.fill
   - Colors: white (inactive) / green (active)
   
2. **Fix model** (bottom-right, capsule)
   - Only visible when model is placed
   - Text: "Fix model" / "Stop scan"
   - Colors: orange (inactive) / red (scanning)

### Progress Overlay
Shows during alignment:
- Progress bar (0-100%)
- Status messages:
  - "Preparing scan for alignment..."
  - "Sending to alignment server..."
  - "Processing alignment..."
  - "Applying transformation..."
  - "Model aligned!" (success)
  - "Alignment failed: [error]" (error)

## Technical Details

### Workflow
1. **Start Alignment Scan**: Starts AR mesh reconstruction
2. **Stop Scan**: Exports mesh to OBJ, initiates alignment
3. **Export (0-50% progress)**: Converts ARMeshAnchors to OBJ with decimation
4. **Server Request (50-60%)**: HTTP POST with OBJ data
5. **Processing (60-80%)**: Server runs ICP alignment algorithm
6. **Apply Transform (80-100%)**: Updates model anchor transform

### Transform Matrix
- Format: `simd_float4x4` (column-major)
- Received as `[[Float; 4]; 4]` from server JSON
- Applied directly to `AnchorEntity.transform`

### Error Handling
- Network timeout: 30 seconds
- Failed export: Shows error in console
- Server errors: Shows error message in UI
- Invalid response: Shows parse error

## State Variables

```swift
@State private var isAlignmentScanning = false  // True while scanning for alignment
@State private var alignmentScanData = false    // True when scan data ready (unused currently)
```

## Integration Points

### CaptureSession
- `startScanning()`: Begins mesh reconstruction
- `stopScanning()`: Ends reconstruction
- `exportMeshData(progress:completion:)`: Exports to OBJ with decimation

### Model Management
- `roomModel`: Loaded ModelEntity (from room.usdc)
- `placedModelAnchor`: AnchorEntity containing the model
- Transform applied to anchor, not model directly

## Future Enhancements

1. **Server Discovery**: Auto-detect alignment server on local network
2. **Offline Mode**: Cache alignment for repeated placements
3. **Manual Adjustment**: Fine-tune alignment with gestures
4. **Visual Feedback**: Show alignment quality score
5. **Preview Mode**: Preview alignment before applying

## Troubleshooting

### "Alignment failed: URLError"
- Check server is running: `cargo run --bin align_server`
- Verify server URL matches your network configuration
- Check firewall/network permissions

### "Failed to export scan data"
- Ensure scanning captured mesh data (check console for anchor count)
- Try scanning for longer duration (5-10 seconds)

### Model doesn't align correctly
- Scan more of the room for better alignment
- Ensure room model matches the real space
- Check server logs for ICP convergence issues

### Progress stuck at "Sending to server"
- Server may be processing (wait up to 30 seconds)
- Check server console for errors
- Verify OBJ file is valid (test with curl)

## Example Server Test

```bash
# Test alignment server locally
curl -X POST http://localhost:6000/align \
  --data-binary "@scan.obj" \
  -H "Content-Type: application/octet-stream" \
  -s | jq .

# Expected response includes:
# - "matrix": 4x4 transformation array
# - "translation": [x, y, z] offset
# - "rotation_angle_degrees": rotation amount
```

## Notes

- Alignment uses ICP (Iterative Closest Point) algorithm
- Works best when scanning the full room
- Model must match the real-world geometry for good results
- Transform is in ARKit's Y-up coordinate system
