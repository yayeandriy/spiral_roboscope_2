# Marker Badge Visual Reference

## Enhanced Badge Layout (With Details)

```
┌─────────────────────────────────────┐
│           Marker Details         [🗑️]│
├─────────────────────────────────────┤
│                                     │
│    Long Size    │    Cross Size     │
│     2.45 m      │      1.20 m       │
│                                     │
├─────────────────────────────────────┤
│                                     │
│         Edge Distances              │
│  Left  Right  Near   Far            │
│  0.82  0.78   1.15   1.30           │
│  (🔵)  (🟢)   (🟠)   (🟣)           │
│                                     │
├─────────────────────────────────────┤
│                                     │
│   Long (Z)      │    Cross (X)      │
│    -1.23 m      │     0.45 m        │
│                                     │
└─────────────────────────────────────┘
```

## Fallback Badge Layout (Without Details)

```
┌─────────────────────────────────────┐
│                                  [🗑️]│
│                                     │
│     Width       │      Length       │
│     1.20 m      │      2.45 m       │
│                                     │
├─────────────────────────────────────┤
│                                     │
│       X         │        Z          │
│     0.45        │      -1.23        │
│                                     │
└─────────────────────────────────────┘
```

## Color Scheme

### Edge Distance Colors
- **Left**: Blue (#0000FF) - Represents left boundary
- **Right**: Green (#00FF00) - Represents right boundary  
- **Near**: Orange (#FFA500) - Closest edge to origin
- **Far**: Purple (#800080) - Farthest edge from origin

### Background & Frame
- **Background**: Ultra-thin material (glass morphism)
- **Border**: White gradient (30% → 10% opacity)
- **Shadow**: Black 20% opacity, 10pt radius

## Size Guidelines

### Text Sizes
- **Title**: 13pt semibold
- **Primary Values**: 16pt semibold (sizes)
- **Secondary Values**: 14pt medium (coordinates)
- **Labels**: 11pt medium
- **Edge Labels**: 10pt medium
- **Edge Values**: 13pt semibold

### Spacing
- **Horizontal Padding**: 20pt
- **Vertical Padding**: 16pt
- **Section Spacing**: 12pt
- **Label-Value Spacing**: 4pt
- **Edge Item Spacing**: 12pt

### Delete Button
- **Size**: 12pt icon
- **Padding**: 8pt
- **Background**: Red 90% opacity circle
- **Border**: White 70% opacity, 1pt
- **Offset**: (8pt, -8pt) from top-trailing

## Measurements Reference

### Long vs Cross Axes
```
         Long Axis (Z)
              ↑
              │
      ┌───────┼───────┐
      │       │       │
Cross │   ┌───┴───┐   │ 
Axis  ├───┤ Marker│───┤
(X) ←─┤   └───────┘   │
      │               │
      └───────────────┘
```

### Edge Distances
```
           Far Distance
    ┌─────────────────────┐
    │                     │
Left│   P1 ────── P2     │Right
Dist│   │          │     │Dist
    │   │  CENTER  │     │
    │   │          │     │
    │   P4 ────── P3     │
    │                     │
    └─────────────────────┘
         Near Distance
```

## States & Transitions

### Initial State
- Badge hidden (no marker selected)

### Selected (No Details)
- Fade in with scale animation
- Show basic dimensions
- Computed from local node positions

### Selected (With Details)
- Same fade in animation
- Show enhanced layout
- Display server-computed metrics

### Deselected
- Fade out with scale animation
- Remove from view hierarchy

## Accessibility

### Labels
- All measurements have descriptive labels
- Proper semantic hierarchy (title → sections → values)
- High contrast text on glass background

### Touch Targets
- Delete button: minimum 44×44pt touch area
- Entire badge: non-interactive (info display only)

## Usage Context

### When to Show Badge
- ✅ Marker selected via tap or target tracking
- ✅ Marker has valid spatial position
- ✅ AR session is active

### When to Hide Badge
- ❌ No marker selected
- ❌ AR session paused/stopped
- ❌ Marker being moved/resized
- ❌ View transitioning away

## Data Format

### Metric Precision
- **Distances/Sizes**: 2 decimal places (e.g., "1.23 m")
- **Coordinates**: 2 decimal places (e.g., "-0.45")
- **Unit**: Always meters in AR context

### Null Handling
- If `details == nil`: Show fallback layout
- If individual field is null: Show "N/A" or omit
- If marker invalid: Don't show badge
