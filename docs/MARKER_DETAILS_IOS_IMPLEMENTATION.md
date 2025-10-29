# Marker Details - iOS Implementation Summary

## Overview
This document summarizes the iOS implementation of the Marker Details feature, which displays server-computed geometric measurements for markers in the AR badge view.

## Implementation Date
29 October 2025

## Changes Made

### 1. Data Models (`roboscope2/Models/Marker.swift`)

#### Added `MarkerDetails` Struct
```swift
struct MarkerDetails: Codable, Sendable, Hashable {
    let markerId: UUID
    let centerLocationLong: Float      // Z axis position
    let centerLocationCross: Float     // X axis position
    let leftDistance: Float
    let rightDistance: Float
    let farDistance: Float
    let nearDistance: Float
    let longSize: Float                // Size along long axis
    let crossSize: Float               // Size along cross axis
    let customProps: [String: AnyCodable]
    let createdAt: Date
    let updatedAt: Date
}
```

#### Updated `Marker` Struct
- Added optional `details: MarkerDetails?` field
- Updated `CodingKeys` to include `details`
- Field is optional to handle cases where server hasn't computed details yet

### 2. Spatial Marker Service (`roboscope2/Services/SpatialMarkerService.swift`)

#### Updated `SpatialMarker` Struct
- Added `var details: MarkerDetails? = nil` to store server-computed details

#### Enhanced `addMarker` Method
- Added `details: MarkerDetails? = nil` parameter
- Passes details to new `SpatialMarker` instances

#### Updated `loadPersistedMarkers` Method
- Now passes marker details when loading from server
- Updates existing marker details when refreshing

#### Added Helper Methods
- `selectedMarkerDetails: MarkerDetails?` - Computed property to get details for selected marker
- `updateMarkerDetails(backendId:details:)` - Update details for a specific marker

### 3. UI Components (`roboscope2/Views/ARSessionView.swift`)

#### Enhanced `MarkerBadgeView`
- Added `details: MarkerDetails? = nil` parameter
- Conditional rendering:
  - **With Details**: Shows comprehensive server-computed metrics
    - Long Size × Cross Size dimensions
    - Edge distances (Left, Right, Near, Far) with color coding
    - Center position in Long (Z) and Cross (X) axes
  - **Without Details**: Shows fallback to basic calculated metrics
    - Width × Length
    - Center X and Z coordinates

#### Visual Design
- Title: "Marker Details" when showing detailed metrics
- Color-coded edge distances:
  - Left: Blue
  - Right: Green
  - Near: Orange
  - Far: Purple
- Organized sections with dividers for better readability

#### Updated Badge Usage in ARSessionView
- Now passes `markerService.selectedMarkerDetails` to badge
- Badge automatically adapts based on details availability

### 4. Marker Loading Integration

#### Updated Marker Transformation
- When loading persisted markers, the `details` field is now preserved during coordinate transformation
- Details are loaded from server and passed through to spatial markers

## Data Flow

```
Server API Response (with details)
         ↓
MarkerService.getMarkersForSession()
         ↓
Marker objects (with optional details)
         ↓
ARSessionView transforms coordinates
         ↓
SpatialMarkerService.loadPersistedMarkers()
         ↓
SpatialMarker instances (with details)
         ↓
MarkerBadgeView displays details
```

## Backward Compatibility

✅ **Fully backward compatible**
- All changes are additive
- Optional `details` field gracefully handles null values
- Existing JSON decoding works (ignores unknown fields)
- Badge falls back to computed metrics when details unavailable

## Future Enhancements

### Potential Additions
1. **Pull-to-refresh details**: Allow users to manually trigger detail recalculation
2. **Loading indicator**: Show when details are being computed
3. **Details age indicator**: Visual cue if details are stale
4. **Custom props from details**: Display domain-specific metadata from details.customProps

### Server Integration Points
- `POST /api/v1/markers/{id}/details/calculate` - Trigger detail calculation
- `GET /api/v1/markers/{id}/details` - Fetch only details
- Automatic polling if details are initially null

## Testing Checklist

- [x] Models compile without errors
- [x] Badge displays with basic metrics (no details)
- [ ] Badge displays with full details (when available)
- [ ] Edge distance colors are distinct and readable
- [ ] Transition between basic/detailed views is smooth
- [ ] Details persist through marker updates
- [ ] Details update when refetching markers

## UI/UX Considerations

### Badge Layout
- Compact design fits comfortably in AR view
- Glass morphism background for modern AR aesthetic
- Sufficient contrast for outdoor visibility
- Touch targets adequately sized (delete button)

### Information Hierarchy
1. **Primary**: Size measurements (most frequently used)
2. **Secondary**: Edge distances (spatial context)
3. **Tertiary**: Center coordinates (reference data)

## Dependencies

### Internal
- `Marker` model
- `SpatialMarkerService`
- `MarkerService` (API client)

### External
- SwiftUI
- RealityKit (for SIMD types)
- Combine (for @Published properties)

## References

- Server Implementation: `docs/backend/MARKER_DETAILS_IMPLEMENTATION_GUIDE.md`
- Architecture Changes: `docs/MARKER_DETAILS_CHANGES.md`
- Custom Props Guide: `docs/CUSTOM_PROPS_GUIDE.md`
