# Key Metrics Calculation Guide

## Overview

This document explains how to calculate the key metrics displayed in the Marker Details panel from raw marker data. These metrics provide essential spatial information about marker positioning and dimensions.

## Marker Data Structure

A marker consists of four corner points (p1, p2, p3, p4), where each point is a 3D coordinate:

```typescript
interface Marker {
  p1: [number, number, number]  // [x, y, z] in meters
  p2: [number, number, number]
  p3: [number, number, number]
  p4: [number, number, number]
  calibrated_data?: {
    p1: [number, number, number]
    p2: [number, number, number]
    p3: [number, number, number]
    p4: [number, number, number]
  }
}
```

## Key Metrics Categories

### 1. Raw Metrics
Calculated directly from the raw marker points (p1, p2, p3, p4).

### 2. Calibrated Metrics
Calculated from calibrated_data points when available. These account for space calibration transformations.

### 3. Size Metrics
Dimensional measurements that remain constant regardless of calibration (assuming no rotation/scaling).

---

## Metric Calculations

### Center

**Definition**: The geometric centroid of the four corner points.

**Formula**:
```
Center = (p1 + p2 + p3 + p4) / 4
```

**Component-wise**:
```
Center.x = (p1[0] + p2[0] + p3[0] + p4[0]) / 4
Center.y = (p1[1] + p2[1] + p3[1] + p4[1]) / 4
Center.z = (p1[2] + p2[2] + p3[2] + p4[2]) / 4
```

**Example**:
```typescript
// Raw points
const p1 = [-0.230, 0.060, 0.030]
const p2 = [-0.165, 0.057, 0.037]
const p3 = [-0.167, 0.050, 0.262]
const p4 = [-0.232, 0.053, 0.255]

// Calculate center
const centerX = (-0.230 + -0.165 + -0.167 + -0.232) / 4 = -0.198
const centerY = (0.060 + 0.057 + 0.050 + 0.053) / 4 = 0.055
const centerZ = (0.030 + 0.037 + 0.262 + 0.255) / 4 = 0.146

// Result: Center = (-0.198, 0.055, 0.146)
```

**Purpose**: Provides the average position of the marker in 3D space.

---

### Z dist (Z Distance)

**Definition**: The minimum Z coordinate among all four corner points.

**Formula**:
```
Z_dist = min(p1[2], p2[2], p3[2], p4[2])
```

**Example**:
```typescript
const zValues = [0.030, 0.037, 0.262, 0.255]
const zDist = Math.min(...zValues) = 0.030  // or 0.029m in the example
```

**Purpose**: Indicates the closest distance of the marker to the Z=0 plane (typically the starting edge along the longitudinal axis).

**Calibrated Version**:
```
Z_dist_calibrated = min(calibrated_p1[2], calibrated_p2[2], calibrated_p3[2], calibrated_p4[2])
```

---

### X dist (X Distance)

**Definition**: The X coordinate value that is closest to zero (with its sign preserved).

**Formula**:
```
X_dist = X_value where |X_value| = min(|p1[0]|, |p2[0]|, |p3[0]|, |p4[0]|)
```

**Algorithm**:
1. Calculate absolute value of each X coordinate
2. Find which coordinate has the minimum absolute value
3. Return the original (signed) X coordinate value

**Example**:
```typescript
const xValues = [-0.230, -0.165, -0.167, -0.232]
const absXValues = [0.230, 0.165, 0.167, 0.232]
const minAbsIndex = 1  // index of -0.165 (absolute value 0.165)
const xDist = xValues[minAbsIndex] = -0.165  // or -0.094m in the example
```

**Purpose**: Indicates which side of the X=0 plane (centerline) the marker is on and how close it is to the centerline. The sign indicates:
- **Negative value**: Marker is on the negative X side
- **Positive value**: Marker is on the positive X side

**Calibrated Version**: Uses the same algorithm on calibrated_data points.

---

### Width (X)

**Definition**: The extent of the marker along the X axis (cross direction).

**Formula**:
```
Width_X = max(p1[0], p2[0], p3[0], p4[0]) - min(p1[0], p2[0], p3[0], p4[0])
```

**Example**:
```typescript
const xValues = [-0.230, -0.165, -0.167, -0.232]
const maxX = Math.max(...xValues) = -0.165
const minX = Math.min(...xValues) = -0.232
const widthX = -0.165 - (-0.232) = 0.067  // or 0.206m in the example
```

**Purpose**: Physical width of the marker perpendicular to the longitudinal axis.

**Note**: Width should remain constant between raw and calibrated data if only translation is applied (no rotation/scaling).

---

### Length (Z)

**Definition**: The extent of the marker along the Z axis (longitudinal direction).

**Formula**:
```
Length_Z = max(p1[2], p2[2], p3[2], p4[2]) - min(p1[2], p2[2], p3[2], p4[2])
```

**Example**:
```typescript
const zValues = [0.030, 0.037, 0.262, 0.255]
const maxZ = Math.max(...zValues) = 0.262
const minZ = Math.min(...zValues) = 0.030
const lengthZ = 0.262 - 0.030 = 0.232  // or 0.233m in the example
```

**Purpose**: Physical length of the marker along the longitudinal axis.

**Note**: Length should remain constant between raw and calibrated data if only translation is applied (no rotation/scaling).

---

## Calibration Difference Detection

The UI marks calibrated metrics with an asterisk (*) when they differ from raw metrics.

**Detection Formula**:
```typescript
const epsilon = 1e-6  // Tolerance for floating-point comparison

function calibratedDiffers(raw: number, calibrated: number): boolean {
  return Math.abs(calibrated - raw) > epsilon
}
```

**Checked Differences**:
1. Center X, Y, Z coordinates
2. Width (X) - should typically not differ
3. Length (Z) - should typically not differ
4. Z dist
5. X dist

**Example**:
```typescript
// Raw center
const rawCenter = [-0.198, 0.056, 0.146]
// Calibrated center
const calibratedCenter = [-0.198, 0.056, 1.146]

// Check Z coordinate difference
const zDiffers = Math.abs(1.146 - 0.146) > 0.000001  // true
// Result: "Calibrated*" label is shown
```

---

## Implementation Reference

The calculations are implemented in `/components/marker-details.tsx` within the Key Metrics section:

```typescript
// Extract coordinates
const rawPts: [number, number, number][] = [marker.p1, marker.p2, marker.p3, marker.p4]
const rawXs = rawPts.map(p => p[0])
const rawYs = rawPts.map(p => p[1])
const rawZs = rawPts.map(p => p[2])

// Calculate center
const centerRaw: [number, number, number] = [
  (rawXs[0] + rawXs[1] + rawXs[2] + rawXs[3]) / 4,
  (rawYs[0] + rawYs[1] + rawYs[2] + rawYs[3]) / 4,
  (rawZs[0] + rawZs[1] + rawZs[2] + rawZs[3]) / 4,
]

// Calculate Z dist
const minZRaw = Math.min(...rawZs)

// Calculate signed X dist (closest to zero)
const idxMinAbsXRaw = rawXs.reduce((iMin, x, i, arr) => 
  (Math.abs(x) < Math.abs(arr[iMin]) ? i : iMin), 0
)
const signedXClosestRaw = rawXs[idxMinAbsXRaw]

// Calculate dimensions
const widthXRaw = Math.max(...rawXs) - Math.min(...rawXs)
const lengthZRaw = Math.max(...rawZs) - Math.min(...rawZs)
```

---

## Common Use Cases

### 1. Finding Markers Near Centerline
Sort markers by `Math.abs(X_dist)` - smaller values are closer to centerline.

### 2. Finding Markers at Specific Positions
Use `Z_dist` to locate markers at specific distances from the starting edge.

### 3. Validating Calibration
Compare raw and calibrated Width/Length - they should be identical (or very close) if only translation was applied.

### 4. Quality Control
- Check if Width and Length are within expected tolerances
- Verify Center coordinates are within the space boundaries
- Ensure Z dist and X dist are consistent with marker placement rules

---

## Coordinate System

- **X-axis**: Cross direction (perpendicular to movement)
  - Negative: Left side
  - Positive: Right side
  - Zero: Centerline
  
- **Y-axis**: Vertical direction (height)
  - Zero: Reference plane (e.g., floor or surface)
  
- **Z-axis**: Longitudinal direction (along movement)
  - Zero: Starting edge
  - Increasing: Forward direction

---

## Notes and Considerations

1. **Precision**: All calculations use floating-point arithmetic. Use epsilon (1e-6) for equality comparisons.

2. **Units**: All measurements are in meters.

3. **Calibration**: Calibration typically applies translation to align points to a reference coordinate system. If Width or Length differ significantly between raw and calibrated, this may indicate rotation or scaling was applied.

4. **Signed X dist**: Preserving the sign is important for determining which side of the centerline the marker is on, not just the distance.

5. **Point Order**: The order of p1, p2, p3, p4 doesn't matter for these calculations (they're symmetric operations).

6. **Missing Data**: If calibrated_data is not present, only raw metrics are displayed.

---

## Troubleshooting

**Problem**: Width or Length differs between raw and calibrated
- **Possible Cause**: Calibration included rotation or scaling
- **Solution**: Review calibration parameters to ensure only translation is applied

**Problem**: X dist shows unexpected values
- **Possible Cause**: Marker points are incorrectly recorded
- **Solution**: Verify all four corner points are within expected bounds

**Problem**: Center coordinates seem incorrect
- **Possible Cause**: One or more points are outliers
- **Solution**: Inspect individual point coordinates for data entry errors

---

## Related Documentation

- [Marker Data Model](../data-model/entities.md#marker)
- [Space Calibration](../api/SPACE_CALIBRATION_FEATURE.md)
- [Marker Details Implementation](../backend/MARKER_DETAILS_IMPLEMENTATION_GUIDE.md)
