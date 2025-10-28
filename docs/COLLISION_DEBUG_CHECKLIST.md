# Collision & Raycasting Debug Checklist

## Issue
Marker shows ~1.849m to left edge but is visually partially outside the surface. This suggests:
1. Raycasting against bounding box instead of actual mesh surface
2. Model placement issue
3. Collision shapes not generated correctly

## Changes Made (Oct 28, 2025)

### 1. Collision Generation
**Location**: `ARSessionView.swift` `loadRoomPlanesFromSpace()`

**Changed from:**
```swift
if modelEntity.collision == nil {
    modelEntity.generateCollisionShapes(recursive: true)
}
```

**Changed to:**
```swift
modelEntity.generateCollisionShapes(recursive: false)
```

**Reason**: `recursive: false` generates collision shapes from the actual mesh geometry of the root entity, rather than potentially simplifying or wrapping child entities. This should give us accurate surface collision detection.

### 2. Enhanced Debug Logging
Added comprehensive logging to verify:
- Collision shape type and count
- Visual bounds vs collision bounds
- Test raycast from model center to verify we hit mesh surface, not just bbox
- Scene hierarchy validation

### 3. Raycast Provider Debug
Enhanced `RealityKitRaycastProvider` to log:
- Scene availability
- Mesh bounds
- Visual bounds
- Collision shapes count
- Ray hits/misses with warnings

## What to Check

### In Xcode Console (when loading reference model):

1. **Collision Generation**
   ```
   ✅ Generated collision shapes for ModelEntity (recursive:false for accurate mesh collision)
   🔍 Collision shapes count: [should be > 0]
   ```

2. **Test Raycast**
   ```
   🎯 TEST RAYCAST from center-top: hit at SIMD3<Float>(x, y, z)
   🎯 Distance from top: X.XXXm (should be << model height if hitting actual surface)
   ```
   - If distance is very small (< 0.5m for a room-sized model), we're hitting the surface ✅
   - If distance ≈ model height, we're hitting the bounding box ❌

3. **Scene Hierarchy**
   ```
   🔍 ModelEntity scene: YES
   🔍 ModelEntity parent: YES (AnchorEntity)
   🔍 Anchor in scene: YES
   ```

### During Marker Selection:

Look for raycast logs:
```
===REALITYKIT: raycastDown from: SIMD3<Float>(...)
===REALITYKIT: collision shapes count: [should match count from loading]
===REALITYKIT: raycastDown first hit: SIMD3<Float>(...) or nil
```

If you see:
```
⚠️ NO HIT - point may be outside mesh or collision shapes not generated correctly
```
Then the marker point is genuinely outside the model bounds.

## Expected Behavior

### If Raycasting Works Correctly:
- Marker partially outside surface → Left/Right distance should be SMALL or ZERO
- Marker well inside surface → Distance reflects actual arc to edge
- Near value = 0.000m confirms marker is at/near the front edge (correct in your screenshot)

### If Still Hitting Bounding Box:
- Distances will be measured to the box edges, not actual surface
- Need to investigate RealityKit collision generation limitations with USDC models

## Next Steps

1. **Run the app** and check Xcode console for the debug logs above
2. **Share the console output** when:
   - Loading the reference model (look for the test raycast result)
   - Selecting a marker (especially one that looks outside the surface)
3. **Compare**:
   - Visual bounds min/max
   - Test raycast hit position
   - Marker raycast hit positions

## Potential Issues

### If generateCollisionShapes() creates only a bounding box:
- RealityKit may simplify complex USDC geometry
- May need to manually create ShapeResource from MeshResource
- Alternative: Use hit-testing against the actual mesh triangles (more complex)

### If the model transform is wrong:
- Verify `frameOriginTransform` is set correctly
- Check that anchor.transform matches the expected FrameOrigin
- Markers should be in same coordinate space as model

## Reference

- RealityKit Raycasting: Uses collision shapes for hit detection
- `generateCollisionShapes(recursive:)`: Creates convex hull or approximate shapes
- `scene.raycast(relativeTo:)`: Transforms ray to entity's local space
- Model-local space: All measurements in model's coordinate system (Y-up, Z-forward)
