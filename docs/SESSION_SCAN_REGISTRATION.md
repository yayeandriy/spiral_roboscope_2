# Session Scan & Model Registration

## Overview

The Session Scan & Registration feature enables real-time AR alignment between a physical space and its digital 3D model. This allows users to:

1. Scan the physical environment during a work session
2. Register (align) the scan with the pre-existing Space model
3. Place markers that are consistently positioned in the Space's coordinate system
4. Collaborate with accurate spatial references

## Architecture

### Components

```
ARSessionView (Main AR Session)
    ├── SessionScanView (Scanning & Registration)
    │   ├── CaptureSession (Mesh Scanning)
    │   ├── SpaceService (Model Download)
    │   └── ModelRegistrationService (ICP Algorithm)
    └── FrameOrigin (Coordinate System)
        ├── Gizmo Visualization
        └── Marker Coordinate Transform
```

### Data Flow

```
1. User initiates scan
2. ARKit captures mesh → Export to OBJ
3. Download Space USDC model
4. Extract point clouds from both models
5. Run ICP registration algorithm
6. Compute transformation matrix
7. Update FrameOrigin coordinate system
8. Transform existing markers to new coordinates
9. Display alignment gizmo
```

## Features

### 1. Session Scanning

**Location**: `ARSessionView.swift`

- **Trigger**: "Scan" button in bottom-left of AR view
- **Behavior**: Opens `SessionScanView` as a sheet
- **Auto-start**: Scanning begins immediately when view appears
- **Shared AR Session**: Uses same `CaptureSession` as parent to maintain coordinate system

#### Implementation Details

```swift
// Shared AR session ensures same origin
SessionScanView(
    session: session,
    captureSession: captureSession,  // Same instance
    onRegistrationComplete: { transform in
        frameOriginTransform = transform
        placeFrameOriginGizmo(at: transform)
        updateMarkersForNewFrameOrigin()
    }
)
```

**Key Points**:
- AR session continues running in background
- No tracking reset between views
- Mesh anchors accumulated during scanning

### 2. Scan Controls

**Stop Scan Button**:
- Appears while scanning is active
- Red button with stop icon
- Calls `captureSession.stopScanning()`
- Preserves captured mesh anchors

**Find Space Button**:
- Appears after scan is stopped
- Blue button with magnifying glass icon
- Initiates model registration process

**Session Context Menu** (Ellipsis Menu):
- **Location**: Top-right corner of SessionScanView, top-left corner of ARSessionView
- **Icon**: Ellipsis circle (⋯) in SessionScanView, Ellipsis in liquid glass button in ARSessionView
- **Options**:
  - **Show Reference Model**: Toggle to display/hide the Space's USDC model at FrameOrigin
    - Model is downloaded from `space.model_usdc_url`
    - Placed at world origin (FrameOrigin) for spatial reference
    - Useful for visual verification before running full registration
    - Can be toggled on/off at any time during scanning or active session
    - Available in both SessionScanView (during scan) and ARSessionView (during active work session)

### 3. Model Registration

**Algorithm**: Iterative Closest Point (ICP)

**Process Steps**:

1. **Fetch Space Data** (~0.5s)
   - Retrieve Space metadata from backend
   - Validate USDC model URL exists

2. **Download USDC Model** (~3-5s)
   - Download from cloud storage
   - Save to temporary directory as `.usdc`
   - File handling: `FileManager.default.temporaryDirectory`

3. **Export Scan Mesh** (~2-3s)
   - Convert ARKit mesh anchors to OBJ format
   - Export to Documents directory
   - Uses `CaptureSession.exportMeshData()`

4. **Load Models** (~4-5s)
   - Load both models into SceneKit
   - Flatten scene hierarchy
   - Extract geometry nodes
   - **Optimization**: Background loading with `Task.detached(priority: .userInitiated)`

5. **Extract Point Clouds** (~2-3s)
   - Sample vertices from geometry
   - Model: 5,000 points
   - Scan: 10,000 points
   - **Optimization**: Reduced from 10k model points for speed

6. **ICP Registration** (~6-8s)
   - Iterative alignment algorithm
   - Max 30 iterations (optimized from 50)
   - Convergence threshold: 0.001 (relaxed from 0.0001)
   - Outputs: transformation matrix, RMSE, inlier fraction

**Total Time**: ~15-25 seconds (optimized from 30-45s)

### 4. Performance Optimizations

#### AR Session Pause
```swift
// Pause AR during registration to free resources
captureSession.session.pause()

defer {
    // Resume after completion
    captureSession.session.run(configuration!)
}
```
**Benefit**: 30-40% CPU/GPU freed

#### Optimized Parameters
| Parameter | Space 3D | Session (Old) | Session (New) |
|-----------|----------|---------------|---------------|
| Model Points | 5,000 | 10,000 | 5,000 ✅ |
| Scan Points | 10,000 | 10,000 | 10,000 |
| Max Iterations | 30 | 50 | 30 ✅ |
| Convergence | 0.001 | 0.0001 | 0.001 ✅ |

#### Background Processing
```swift
await Task.detached(priority: .userInitiated) {
    // Load models off main thread
    let modelScene = try SCNScene(url: modelPath, options: [
        .checkConsistency: false  // Skip validation
    ])
}
```

#### Performance Profiling
Detailed timing logs for each step:
```
[SessionScan] ⏱️ Step 1 (Fetch space): 0.5s
[SessionScan] ⏱️ Step 2 (Download model): 3.2s
[SessionScan] ⏱️ Step 3 (Export scan): 2.1s
[SessionScan] ⏱️ Step 4 (Load models): 4.3s
[SessionScan] ⏱️ Step 5 (Extract points): 2.8s
[SessionScan] ⏱️ Step 6 (ICP registration): 6.5s
[SessionScan] ⏱️ TOTAL TIME: 19.4s
```

### 5. FrameOrigin Coordinate System

**Definition**: FrameOrigin is the reference coordinate system that represents the initial position and orientation of the AR camera when the session starts. It serves as the world origin (0, 0, 0) in AR space.

**Purpose**: Unified coordinate system for all markers and spatial data across scanning, registration, and collaboration.

**Physical Meaning**:
- **Position**: The device's physical location when AR tracking begins
- **Orientation**: The device's facing direction at AR session start
- **Persistence**: Remains consistent throughout the AR session lifecycle
- **Usage**: All spatial markers are stored relative to FrameOrigin, enabling consistent positioning across sessions after registration

**States**:
- **Before Registration**: FrameOrigin = AR Session Origin (identity matrix)
- **After Registration**: FrameOrigin = Space Model Origin (transformation matrix)

#### FrameOrigin in Practice

**Placement**:
- Reference models placed at FrameOrigin appear at world origin (0, 0, 0)
- This represents where the device was when tracking started
- Useful for understanding the relationship between physical space and digital coordinates

**Visualization**:
- The "Show Reference Model" feature places the Space USDC model at FrameOrigin
- Helps users understand spatial alignment before running registration
- Toggle via Session Context Menu in SessionScanView

#### Coordinate Transformations

**To FrameOrigin** (for storage):
```swift
func transformPointsToFrameOrigin(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    let inverseTransform = frameOriginTransform.inverse
    return points.map { point in
        let worldPoint = SIMD4<Float>(point.x, point.y, point.z, 1.0)
        let framePoint = inverseTransform * worldPoint
        return SIMD3<Float>(framePoint.x, framePoint.y, framePoint.z)
    }
}
```

**From FrameOrigin** (for display):
```swift
func transformPointsFromFrameOrigin(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
    return points.map { point in
        let framePoint = SIMD4<Float>(point.x, point.y, point.z, 1.0)
        let worldPoint = frameOriginTransform * framePoint
        return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
    }
}
```

### 6. FrameOrigin Gizmo

**Visualization**: 3D coordinate axes showing the reference frame origin

**Components**:
- **Yellow center sphere** (4.5cm radius): Origin point
- **Red X-axis** (50cm length, 1cm thick): Right direction
- **Green Y-axis** (50cm length, 1cm thick): Up direction
- **Blue Z-axis** (50cm length, 1cm thick): Forward direction
- **Colored spheres** (3cm radius): Axis endpoints

**Implementation**:
```swift
func placeFrameOriginGizmo(at transform: simd_float4x4) {
    let anchor = AnchorEntity(world: transform)
    
    // Create coordinate axes
    let axisLength: Float = 0.5  // 50cm
    let axisRadius: Float = 0.01  // 1cm
    
    // X-axis (Red)
    let xAxis = ModelEntity(
        mesh: .generateCylinder(height: axisLength, radius: axisRadius),
        materials: [SimpleMaterial(color: .red, isMetallic: false)]
    )
    // ... Y and Z axes
    
    arView.scene.addAnchor(anchor)
}
```

**Lifecycle**:
- Appears automatically when AR session starts (at origin)
- Updates position when registration completes
- Persists throughout session
- Removed automatically on session end

### 7. Marker Coordinate Handling

#### Creation
```swift
// Marker placed in AR world coordinates
let spatial = markerService.placeMarkerReturningSpatial(targetCorners: corners)

// Transform to FrameOrigin before saving
let frameOriginPoints = transformPointsToFrameOrigin(spatial.nodes)

// Save to backend in FrameOrigin coordinates
try await markerApi.createMarker(
    CreateMarker(workSessionId: session.id, points: frameOriginPoints)
)
```

#### Loading
```swift
// Load from backend (in FrameOrigin coordinates)
let persisted = try await markerApi.getMarkersForSession(session.id)

// Transform to AR world coordinates for display
let transformedMarkers = persisted.map { marker -> Marker in
    let worldPoints = transformPointsFromFrameOrigin(marker.points)
    return Marker(/* ... with worldPoints ... */)
}

markerService.loadPersistedMarkers(transformedMarkers)
```

#### Updating
```swift
// After moving marker, transform to FrameOrigin before saving
if let (backendId, version, updatedNodes) = markerService.endMoveSelectedEdge() {
    let frameOriginPoints = transformPointsToFrameOrigin(updatedNodes)
    
    try await markerApi.updateMarkerPosition(
        id: backendId,
        workSessionId: session.id,
        points: frameOriginPoints,
        version: version
    )
}
```

#### Post-Registration Update
```swift
// When FrameOrigin changes, reload all markers
func updateMarkersForNewFrameOrigin() {
    let persisted = try await markerApi.getMarkersForSession(session.id)
    
    // Transform using NEW frameOriginTransform
    let transformedMarkers = persisted.map { marker -> Marker in
        let worldPoints = transformPointsFromFrameOrigin(marker.points)
        return Marker(/* ... */)
    }
    
    markerService.loadPersistedMarkers(transformedMarkers)
}
```

## User Workflow

### Typical Session Flow

1. **Start Session** → ARSessionView opens
   - FrameOrigin gizmo appears at AR origin
   - Load existing markers (if any)

2. **Scan Environment** → Tap "Scan" button
   - SessionScanView opens
   - Mesh scanning starts automatically
   - Move device to capture space

3. **Stop Scanning** → Tap "Stop Scan"
   - Mesh capture ends
   - "Find Space" button appears

4. **Register to Space** → Tap "Find Space"
   - Progress overlay shows steps
   - Model downloads and processes
   - ICP registration runs (~15-25s)

5. **Registration Complete** → Success overlay
   - Shows RMSE, inlier %, iterations
   - Tap "Dismiss" to return to AR

6. **Post-Registration** → Back in ARSessionView
   - FrameOrigin gizmo moved to space origin
   - Existing markers updated to new coordinates
   - New markers created in space coordinates

7. **Place Markers** → Continue work
   - All markers stored in FrameOrigin coordinates
   - Consistent across sessions and devices

## API Integration

### Endpoints Used

**Get Space**:
```
GET /api/v1/spaces/{spaceId}
Response: Space { modelUsdcUrl, ... }
```

**Get Markers**:
```
GET /api/v1/markers?work_session_id={sessionId}
Response: [Marker] (points in FrameOrigin coords)
```

**Create Marker**:
```
POST /api/v1/markers
Body: { workSessionId, points: [FrameOrigin coords] }
```

**Update Marker**:
```
PUT /api/v1/markers/{markerId}
Body: { points: [FrameOrigin coords], version }
```

## Error Handling

### Common Issues

**No USDC Model**:
```
Error: Space has no USDC model
Solution: Ensure Space has modelUsdcUrl set
```

**Failed to Export Scan**:
```
Error: Failed to export scan
Cause: No mesh anchors captured
Solution: Scan more of the environment
```

**Registration Failed**:
```
Error: Registration failed
Causes:
- Insufficient point overlap
- Models too different in scale
- Poor scan quality
Solutions:
- Rescan with better coverage
- Ensure models represent same space
- Check USDC model quality
```

**Not Enough Points**:
```
Error: Not enough points for registration
Cause: Model has < 100 extractable points
Solution: Check USDC model has geometry
```

## Performance Considerations

### Optimization Checklist

✅ **Pause AR Session** during registration  
✅ **Reduce model point sampling** to 5,000  
✅ **Limit ICP iterations** to 30  
✅ **Relax convergence** to 0.001  
✅ **Background model loading** with Task.detached  
✅ **Skip consistency checks** in SceneKit  
✅ **Performance profiling** with timing logs  

### Future Optimizations

🔮 **KD-Tree for nearest neighbor** (2-3x faster)  
🔮 **GPU-accelerated ICP** (5-10x faster)  
🔮 **Progressive point cloud** (better UX)  
🔮 **Model caching** (eliminate re-downloads)  
🔮 **Spatial hashing** (faster correspondence)  

## Testing

### Manual Test Cases

1. **Basic Scan Flow**
   - Start session → Scan → Stop → Find Space
   - Verify: Gizmo moves, no errors

2. **Marker Consistency**
   - Place marker before registration
   - Complete registration
   - Verify: Marker updates position correctly

3. **Multiple Markers**
   - Create several markers before registration
   - Register to space
   - Verify: All markers update positions

4. **Session Persistence**
   - Create markers after registration
   - Close and reopen session
   - Verify: Markers load in correct positions

5. **Performance**
   - Time registration process
   - Target: < 25 seconds total
   - Check console for timing breakdown

### Validation Metrics

- **RMSE**: < 0.1m (good), < 0.05m (excellent)
- **Inlier Fraction**: > 60% (acceptable), > 80% (good)
- **Iterations**: < 30 (fast convergence)
- **Total Time**: < 25s (acceptable), < 20s (good)

## Code Organization

### Key Files

```
roboscope2/
├── Views/
│   ├── ARSessionView.swift          # Main AR session view
│   ├── SessionScanView.swift        # Scan & registration view
│   └── Space3DViewer.swift          # Reference implementation
├── Services/
│   ├── CaptureSession.swift         # ARKit mesh scanning
│   ├── ModelRegistrationService.swift  # ICP algorithm
│   ├── SpatialMarkerService.swift   # Marker management
│   ├── SpaceService.swift           # Space API
│   └── MarkerService.swift          # Marker API
└── Models/
    ├── Space.swift                  # Space data model
    ├── Marker.swift                 # Marker data model
    └── WorkSession.swift            # Session data model
```

### State Management

**ARSessionView State**:
```swift
@State private var frameOriginTransform: simd_float4x4 = matrix_identity_float4x4
@State private var frameOriginAnchor: AnchorEntity?
@State private var showScanView = false
```

**SessionScanView State**:
```swift
@State private var isScanning = false
@State private var hasScanData = false
@State private var isRegistering = false
@State private var registrationProgress: String = ""
@State private var showRegistrationResult = false
@State private var transformMatrix: simd_float4x4?
```

## Best Practices

### For Users

1. **Scan Coverage**: Cover 60%+ of the space for good registration
2. **Lighting**: Ensure good lighting for mesh quality
3. **Movement**: Move slowly and steadily during scanning
4. **Features**: Scan areas with distinct geometric features
5. **Patience**: Wait for registration to complete (~20s)

### For Developers

1. **Always transform** markers to/from FrameOrigin
2. **Update markers** after FrameOrigin changes
3. **Validate point clouds** before registration
4. **Log performance** metrics for optimization
5. **Handle errors** gracefully with user-friendly messages
6. **Test edge cases** (no model, poor scan, etc.)

## Troubleshooting

### Registration Taking Too Long

**Check**:
- Is AR session paused during registration? ✓
- Are optimized parameters being used? ✓
- Is background loading enabled? ✓

**Profile**:
```
Look for timing logs:
Step 4 (Load models) > 10s? → Model too large
Step 6 (ICP) > 15s? → Too many iterations
```

### Markers in Wrong Position

**Check**:
- Is `updateMarkersForNewFrameOrigin()` called after registration? ✓
- Are transformations using correct `frameOriginTransform`? ✓
- Are loaded markers transformed from FrameOrigin? ✓

**Debug**:
```swift
print("FrameOrigin: \(frameOriginTransform)")
print("Marker world: \(markerWorldPosition)")
print("Marker frame: \(transformPointsToFrameOrigin([markerWorldPosition]))")
```

### Gizmo Not Visible

**Check**:
- Is `placeFrameOriginGizmo()` called on view appear? ✓
- Is `frameOriginAnchor` added to scene? ✓
- Is gizmo scale appropriate (0.5m axes)? ✓

**Verify**:
```swift
print("Gizmo anchor: \(frameOriginAnchor?.position(relativeTo: nil))")
```

## Version History

- **v1.1** (Nov 2025): Settings System
  - Centralized AppSettings with presets (Fast/Balanced/Accurate)
  - Configurable point cloud sampling, ICP iterations, convergence threshold
  - Performance toggles (AR pause, background loading, consistency checks)
  - Settings UI with real-time estimates
  - Applied to both Session and Space registration

- **v1.0** (Oct 2025): Initial implementation
  - Session scanning
  - Model registration
  - FrameOrigin coordinate system
  - Performance optimizations
  - Marker coordinate transformations

## Settings & Configuration

### AppSettings

**Location**: `roboscope2/Models/AppSettings.swift`

All registration parameters are now configurable through the centralized settings system:

#### Registration Presets

| Preset | Time | Accuracy | Use Case |
|--------|------|----------|----------|
| **Instant** | ~5-8s | Low-Medium | Blazing fast rough alignment |
| **Ultra Fast** | ~7-12s | Medium | Very quick with acceptable quality |
| **Fast** | ~10-15s | Medium-High | Quick alignment checks |
| **Balanced** | ~15-25s | High | Recommended for most users |
| **Accurate** | ~30-40s | Very High | Critical measurements |
| **Custom** | Varies | Varies | Manual parameter tuning |

#### Point Cloud Sampling

- **Model Points**: 1,000 - 20,000 (default: 5,000)
  - Sample count from Space USDC model
  - Higher = more accuracy, slower processing
  
- **Scan Points**: 1,000 - 30,000 (default: 10,000)
  - Sample count from AR mesh scan
  - Keep higher than model for better coverage

#### ICP Algorithm Parameters

- **Max Iterations**: 10 - 100 (default: 30)
  - Maximum number of ICP iterations
  - Higher = better convergence, longer time
  
- **Convergence Threshold**: 0.0001 - 0.005 (default: 0.001)
  - Exit early when change is below threshold
  - Lower = more precise, longer time

#### Performance Optimizations

- **Pause AR During Registration**: ON (recommended)
  - Frees 30-40% CPU/GPU resources
  - Faster registration times
  
- **Background Model Loading**: ON (recommended)
  - Keeps UI responsive during load
  - No performance impact
  
- **Skip Consistency Checks**: ON (recommended)
  - Faster USDC/OBJ loading
  - Less validation

- **Show Performance Logs**: OFF
  - Displays detailed timing information
  - Useful for debugging and optimization

### Accessing Settings

**Settings UI**: MainTabView → Settings tab

**Programmatic Access**:
```swift
let settings = AppSettings.shared

// Read values
let modelPoints = settings.modelPointsSampleCount
let iterations = settings.maxICPIterations

// Apply preset
settings.applyPreset(.fast)

// Custom configuration
settings.modelPointsSampleCount = 7000
settings.maxICPIterations = 40
```

### Settings Integration

Both Session and Space registration use the same settings:

**SessionScanView.swift**:
```swift
@StateObject private var settings = AppSettings.shared

let modelPoints = ModelRegistrationService.extractPointCloud(
    from: model,
    sampleCount: settings.modelPointsSampleCount
)

let result = await ModelRegistrationService.registerModels(
    modelPoints: modelPoints,
    scanPoints: scanPoints,
    maxIterations: settings.maxICPIterations,
    convergenceThreshold: settings.icpConvergenceThreshold
)
```

**Space3DViewer.swift**: Same integration pattern

### Performance Estimates

The Settings UI provides real-time estimates based on current configuration:

- **Estimated Time**: Calculated from point counts and iterations
- **Expected RMSE**: Based on convergence threshold
- **Expected Accuracy**: Based on total point counts

Example:
```
Balanced Preset:
- 5,000 model points + 10,000 scan points
- 30 iterations, 0.001 threshold
- AR pause enabled
- Estimated time: ~15-25s
- Expected RMSE: < 0.10m (Good)
- Expected accuracy: High
```

## Related Documentation

- [ARKit Integration](./ARKIT_APPLICATION_GUIDE.md)
- [Model Registration](./MODEL_REGISTRATION.md)
- [Spatial Intelligence](./SPATIAL_INTELLIGENCE_INTEGRATION.md)
- [API Documentation](./api/IOS_ARKIT_INTEGRATION.md)

