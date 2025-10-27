# Custom Props Quick Reference

## Quick Start

### 1. Create Marker with Custom Props

```swift
let customProps: [String: Any] = [
    CustomPropsKeys.severity: "high",
    CustomPropsKeys.priority: 1,
    CustomPropsKeys.tags: ["urgent", "structural"]
]

let marker = CreateMarker(
    workSessionId: sessionId,
    label: "Issue Title",
    points: fourCornerPoints,
    customProps: customProps
)
```

### 2. Access Custom Props

```swift
// Typed accessors
marker.severity      // String?
marker.priority      // Int?
marker.category      // String?
marker.tags          // [String]?
marker.inspector     // String?

// Boolean helpers
marker.isReviewed           // Bool
marker.isHighPriority       // Bool
marker.requiresFollowUp     // Bool
marker.hasTag("urgent")     // Bool
```

### 3. Filter Markers

```swift
markers.highPriority()           // [Marker]
markers.unreviewed()             // [Marker]
markers.withSeverity("high")     // [Marker]
markers.withTag("urgent")        // [Marker]
markers.requiresFollowUp()       // [Marker]
markers.inCategory("damage")     // [Marker]

// Chain filters
markers.highPriority().unreviewed().withTag("urgent")
```

### 4. Update Custom Props

```swift
let update = UpdateMarker(
    customProps: [
        CustomPropsKeys.status: "reviewed",
        CustomPropsKeys.reviewedBy: userName
    ]
)
```

## Common Keys

```swift
// Inspection
CustomPropsKeys.severity          // "low", "medium", "high", "critical"
CustomPropsKeys.category          // "damage", "inspection", "measurement"
CustomPropsKeys.status            // "pending", "reviewed", "approved"
CustomPropsKeys.priority          // Int (1 = highest)
CustomPropsKeys.inspector         // String
CustomPropsKeys.tags              // [String]

// Measurements
CustomPropsKeys.length            // Double
CustomPropsKeys.width             // Double
CustomPropsKeys.height            // Double
CustomPropsKeys.area              // Double
CustomPropsKeys.unit              // "meters", "feet", "inches"

// Workflow
CustomPropsKeys.reviewedAt        // ISO8601 date string
CustomPropsKeys.reviewedBy        // String
CustomPropsKeys.assignedTo        // String
```

## Common Patterns

### Inspection Marker
```swift
[
    CustomPropsKeys.inspector: "Jane Smith",
    CustomPropsKeys.severity: "high",
    CustomPropsKeys.category: "inspection",
    CustomPropsKeys.status: "pending",
    CustomPropsKeys.followUpRequired: true
]
```

### Damage Assessment
```swift
[
    CustomPropsKeys.damageType: "structural",
    CustomPropsKeys.severity: "critical",
    CustomPropsKeys.estimatedCost: 5000.00,
    CustomPropsKeys.repairPriority: 1,
    CustomPropsKeys.tags: ["urgent", "structural"]
]
```

### Measurement
```swift
[
    CustomPropsKeys.length: 2.5,
    CustomPropsKeys.width: 1.8,
    CustomPropsKeys.area: 4.5,
    CustomPropsKeys.unit: "meters",
    CustomPropsKeys.measuredBy: "LiDAR"
]
```

## SwiftUI Display

```swift
struct MarkerCard: View {
    let marker: Marker
    
    var body: some View {
        VStack(alignment: .leading) {
            Text(marker.label ?? "Unnamed")
            
            if let severity = marker.severity {
                Text("Severity: \(severity)")
                    .foregroundColor(severityColor(severity))
            }
            
            if let tags = marker.tags {
                HStack {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(4)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }
        }
    }
}
```

## Tips

✅ **Do:**
- Use `CustomPropsKeys` constants
- Validate data before sending
- Use typed accessors
- Chain filters for complex queries

❌ **Don't:**
- Store large binary data
- Use inconsistent key names
- Forget to handle nil values
- Skip validation

## Full Examples

See `/docs/examples/CustomPropsExamples.swift` for 12 complete examples.
