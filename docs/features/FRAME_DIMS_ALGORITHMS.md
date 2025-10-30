# Frame Dimensions Algorithms Comparison

## Overview
The Marker Frame Dimensions feature uses two complementary algorithms to compute distances from marker corner points to reference model boundaries. Both algorithms output the same `FrameDimsResult` structure, enabling direct comparison.

## Algorithm 1: Plane-Based (Simple & Fast)

### Approach
Approximates the reference model boundary with 6 axis-aligned planes derived from the model's AABB (Axis-Aligned Bounding Box).

### Steps
1. **Extract AABB** from reference model (`model_usdc_url`)
2. **Create 6 planes**:
   - Left: normal `(1, 0, 0)` at `x_min`
   - Right: normal `(-1, 0, 0)` at `x_max`
   - Near: normal `(0, 0, 1)` at `z_min`
   - Far: normal `(0, 0, -1)` at `z_max`
   - Bottom: normal `(0, 1, 0)` at `y_min`
   - Top: normal `(0, -1, 0)` at `y_max`
3. **Compute distance** from each marker corner to each plane using:
   ```
   distance = |dot(point - plane_point, plane_normal)|
   ```
4. **Aggregate** minimum distance per edge across all 4 corners

### Advantages
✅ Very fast (~1ms per marker)  
✅ Simple geometry  
✅ Works well for rectangular rooms  
✅ Minimal computational overhead  

### Limitations
❌ Assumes axis-aligned boundaries  
❌ Cannot handle curved surfaces  
❌ Inaccurate for non-rectangular geometries (e.g., turbine blades)  
❌ May report incorrect distances for concave shapes  

### Storage
- Key: `custom_props.frame_dims`
- Implementation: `FrameDimsService.swift`

---

## Algorithm 2: Mesh-Based Raycasting (Complex & Accurate)

### Approach
Uses SceneKit raycasting (`SCNNode.hitTestWithSegment`) to find actual surface intersections along 6 cardinal directions from the marker's center.

### Steps
1. **Load SCNNode** mesh from reference model
2. **Compute marker center** from 4 corner points
3. **Raycast in 6 directions** from center:
   - Left: `-X` direction `(-1, 0, 0)`
   - Right: `+X` direction `(1, 0, 0)`
   - Near: `-Z` direction `(0, 0, -1)`
   - Far: `+Z` direction `(0, 0, 1)`
   - Bottom: `-Y` direction `(0, -1, 0)`
   - Top: `+Y` direction `(0, 1, 0)`
4. **Bidirectional search**: For each direction, try both forward and backward rays
5. **Find closest hit** among all intersections
6. **Compute distance** as vector magnitude from center to hit point

### Raycasting Details
```swift
// Example: Raycast to find left edge
let origin = markerCenter
let direction = simd_float3(-1, 0, 0) // Left
let rayLength: Float = 100.0 // meters
let end = origin + direction * rayLength

let hits = meshNode.hitTestWithSegment(
    from: SCNVector3(origin),
    to: SCNVector3(end),
    options: nil
)

if let firstHit = hits.first {
    let hitPoint = firstHit.worldCoordinates
    let distance = simd_distance(origin, hitPoint)
}
```

### Advantages
✅ Accurate for any geometry  
✅ Handles curved surfaces (turbine blades, organic shapes)  
✅ Works with concave/convex meshes  
✅ Uses actual mesh topology  

### Limitations
❌ Slower (~5-10ms per marker)  
❌ Requires loaded SCNNode mesh  
❌ More complex implementation  
❌ May fail on degenerate geometry  

### Storage
- Key: `custom_props.frame_dims_mesh`
- Implementation: `MeshFrameDimsService.swift`

---

## Data Structure (Both Algorithms)

Both algorithms produce the same output structure:

```swift
struct FrameDimsResult: Codable, Hashable {
    let aabb: AABB
    let obb: OBB
    let sizes: FrameDimsSizes
    let edgeDistances: EdgeDistances
    let aggregate: FrameDimsAggregate  // This is displayed in UI
    let projected: FrameDimsProjected?
    let frameAxes: FrameAxes
    let meta: FrameDimsMeta
}

struct FrameDimsAggregate: Codable, Hashable {
    let left: Float    // meters
    let right: Float   // meters
    let near: Float    // meters
    let far: Float     // meters
    let top: Float     // meters
    let bottom: Float  // meters
}
```

---

## When to Use Each Algorithm

### Use Plane-Based When:
- Room is rectangular or mostly axis-aligned
- Performance is critical (many markers)
- Real-time updates are needed
- Approximate measurements are acceptable

### Use Mesh-Based When:
- Geometry is complex or curved
- Accurate measurements are required
- Comparing against known dimensions
- Validating plane-based results

### Use Both When:
- Evaluating algorithm accuracy
- Debugging marker placement
- Analyzing complex surfaces
- Quality assurance testing

---

## Example Output Comparison

For a marker in a rectangular room at position `(x=-1.7, y=0.5, z=-3.1)`:

### Plane-Based Result
```json
{
  "aggregate": {
    "left": 0.036,
    "right": 3.036,
    "near": 1.432,
    "far": 4.568,
    "bottom": 1.750,
    "top": 0.750
  }
}
```

### Mesh-Based Result (Same Marker)
```json
{
  "aggregate": {
    "left": 0.038,
    "right": 3.034,
    "near": 1.429,
    "far": 4.571,
    "bottom": 1.748,
    "top": 0.752
  }
}
```

**Difference**: ~2-3mm, within acceptable tolerance for rectangular rooms.

---

## For a turbine blade marker at curved surface:

### Plane-Based Result (Incorrect)
```json
{
  "aggregate": {
    "left": 0.850,
    "right": 0.850,
    "near": 1.200,
    "far": 0.300,  // ← Incorrect: assumes flat surface
    "bottom": 0.150,
    "top": 1.850
  }
}
```

### Mesh-Based Result (Correct)
```json
{
  "aggregate": {
    "left": 0.847,
    "right": 0.853,
    "near": 1.198,
    "far": 0.125,  // ← Correct: actual curved surface distance
    "bottom": 0.148,
    "top": 1.852
  }
}
```

**Difference**: ~175mm on curved edge, demonstrating mesh-based accuracy.

---

## Implementation Notes

### Persistence
Both results are stored in the same marker's `custom_props` JSON field:
```json
{
  "custom_props": {
    "frame_dims": { /* plane-based result */ },
    "frame_dims_mesh": { /* mesh-based result */ }
  }
}
```

### UI Display
The `MarkerBadgeView` currently displays the plane-based result (`frame_dims`). To compare:
1. Read marker from database
2. Access both `custom_props.frame_dims` and `custom_props.frame_dims_mesh`
3. Compare `aggregate` values

### Coordinate System
Both algorithms use **FrameOrigin (FO)** coordinates:
- **+X**: Right
- **-X**: Left
- **+Y**: Up (Top)
- **-Y**: Down (Bottom)
- **+Z**: Far
- **-Z**: Near

### Computation Timing
- Plane-based: Computed on marker create/update (synchronous)
- Mesh-based: Computed on marker create/update (synchronous, slightly slower)
- Both: Results cached in `custom_props`, no recomputation on load

---

## Future Enhancements

### Potential Improvements
1. **Hybrid approach**: Use plane-based for real-time preview, mesh-based for final save
2. **Confidence scores**: Report accuracy estimate based on geometry complexity
3. **Multi-direction raycasting**: Cast multiple rays per edge for better coverage
4. **Adaptive algorithm selection**: Auto-choose based on geometry analysis
5. **UI toggle**: Let user switch between plane-based and mesh-based display

### Performance Optimization
- Cache SCNNode mesh across all markers in session
- Use parallel raycasting for all 6 directions
- GPU-accelerated distance field computation
- Octree spatial indexing for large meshes
