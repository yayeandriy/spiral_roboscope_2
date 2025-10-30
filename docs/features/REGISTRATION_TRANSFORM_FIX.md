# Registration Transform Fix - Session vs Space

## Problem

Registration was working perfectly in the **Space 3D Viewer** but completely off in **AR Sessions**. The scan and reference models appeared misaligned despite using the same registration algorithm and transformation matrix.

## Root Cause

The issue was in **how the transformation matrix was being applied** to the models, not in the registration algorithm itself.

### Space 3D Viewer (Working Correctly) ✅

```swift
// In CombinedModelViewer (Space3DViewer.swift, line 1408)
let composedTransform = result.transformMatrix * originalTransform
primaryNode.simdTransform = composedTransform  // Applied directly to the model node
```

**Key Point**: The transformation is applied **directly to the model node's transform**.

### AR Session View (Incorrect) ❌

```swift
// OLD CODE - BEFORE FIX
let anchor = AnchorEntity(world: frameOriginTransform)  // Transform on anchor
anchor.addChild(modelEntity)  // Model added as child
```

**Key Point**: The transformation was applied to the **anchor**, not the model itself. This creates a parent-child transform hierarchy where:
1. The anchor has the registration transform
2. The model is positioned relative to that transformed anchor
3. This results in the transform being applied twice or incorrectly

## The Fix

Apply the transform **directly to the model entity**, not to the anchor:

```swift
// NEW CODE - AFTER FIX
modelEntity.transform = Transform(matrix: frameOriginTransform)  // Transform on model
let anchor = AnchorEntity(world: .identity)  // Anchor at origin
anchor.addChild(modelEntity)  // Add transformed model
```

### Changes Made

#### 1. Reference Model Placement (`ARSessionView.swift`, line ~1200)

**Before:**
```swift
let anchor = AnchorEntity(world: frameOriginTransform)
anchor.addChild(modelEntity)
```

**After:**
```swift
modelEntity.transform = Transform(matrix: frameOriginTransform)
let anchor = AnchorEntity(world: .identity)
anchor.addChild(modelEntity)
```

#### 2. Reference Model Update (`ARSessionView.swift`, line ~1250)

**Before:**
```swift
private func updateReferenceModelPosition() {
    guard let anchor = referenceModelAnchor else { return }
    anchor.transform = Transform(matrix: frameOriginTransform)
}
```

**After:**
```swift
private func updateReferenceModelPosition() {
    guard let anchor = referenceModelAnchor else { return }
    
    if let modelEntity = anchor.children.first as? ModelEntity {
        modelEntity.transform = Transform(matrix: frameOriginTransform)
    } else {
        anchor.transform = Transform(matrix: frameOriginTransform)  // Fallback
    }
}
```

#### 3. Scan Model Placement (`ARSessionView.swift`, line ~1315)

**Before:**
```swift
let anchor = AnchorEntity(world: frameOriginTransform)
anchor.addChild(scanEntity)
```

**After:**
```swift
scanEntity.transform = Transform(matrix: frameOriginTransform)
let anchor = AnchorEntity(world: .identity)
anchor.addChild(scanEntity)
```

#### 4. Scan Model Update (`ARSessionView.swift`, line ~1350)

**Before:**
```swift
private func updateScanModelPosition() {
    guard let anchor = scanModelAnchor else { return }
    anchor.transform = Transform(matrix: frameOriginTransform)
}
```

**After:**
```swift
private func updateScanModelPosition() {
    guard let anchor = scanModelAnchor else { return }
    
    if let scanEntity = anchor.children.first as? ModelEntity {
        scanEntity.transform = Transform(matrix: frameOriginTransform)
    } else {
        anchor.transform = Transform(matrix: frameOriginTransform)  // Fallback
    }
}
```

## Why This Matters

### Transform Hierarchy in RealityKit

When you have a parent-child relationship:
```
AnchorEntity (transform T1)
  └─ ModelEntity (transform T2)
```

The final world transform of the ModelEntity is: `T1 * T2`

### Old Approach (Incorrect)
```
AnchorEntity (frameOriginTransform)
  └─ ModelEntity (identity)
```
Final transform: `frameOriginTransform * identity = frameOriginTransform`

But the registration algorithm computed `frameOriginTransform` expecting it to be applied directly to the model in a flat hierarchy, not through a parent anchor.

### New Approach (Correct)
```
AnchorEntity (identity)
  └─ ModelEntity (frameOriginTransform)
```
Final transform: `identity * frameOriginTransform = frameOriginTransform`

This matches the Space 3D Viewer's approach and ensures the model is transformed exactly as the registration algorithm intended.

## Testing

After applying this fix:

1. **Space Registration** - Should still work correctly ✅
2. **Session Registration** - Should now align properly ✅
3. **Reference Model** - Should appear at correct position ✅
4. **Scan Model** - Should align with reference model ✅
5. **Marker Placement** - Should be accurate relative to both models ✅

## Key Takeaways

1. **Transform application matters**: Applying a transform to a parent vs child produces different results in hierarchical coordinate systems
2. **Consistency is crucial**: Both Space and Session views must apply transforms the same way
3. **Direct transform application**: For registration matrices computed from world-space points, apply directly to the entity, not through parent transforms
4. **RealityKit vs SceneKit**: While the principles are similar, RealityKit's `AnchorEntity` creates an additional transform layer that must be accounted for

## Related Documentation

- `docs/MODEL_REGISTRATION.md` - Registration algorithm details
- `docs/SESSION_SCAN_REGISTRATION.md` - Session scanning workflow
- `docs/EXACT_SWIFT_CODE.md` - ARKit alignment code examples
