# Custom Props Feature - iOS Integration Guide

## Overview

The `custom_props` field has been added to the Marker entity, allowing you to store arbitrary JSON metadata with each marker. This is useful for domain-specific data like severity levels, categories, inspector info, priorities, tags, and custom annotations.

## What's New

### Marker Model Update

Add the `customProps` property to your existing `Marker` struct:

```swift
struct Marker: Codable, Identifiable {
    let id: String
    let workSessionId: String
    let position: Position
    let normal: Normal?
    let title: String
    let description: String?
    let markerType: String
    let createdAt: String
    let updatedAt: String
    
    // NEW: Custom properties field
    let customProps: [String: AnyCodable]  // or [String: Any] with custom decoding
    
    enum CodingKeys: String, CodingKey {
        case id, position, normal, title, description
        case workSessionId = "work_session_id"
        case markerType = "marker_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case customProps = "custom_props"  // NEW
    }
}
```

### Create Marker Request

Update your `CreateMarkerRequest` to include custom properties:

```swift
struct CreateMarkerRequest: Codable {
    let workSessionId: String
    let position: Position
    let normal: Normal?
    let title: String
    let description: String?
    let markerType: String
    let customProps: [String: AnyCodable]?  // NEW: Optional
    
    enum CodingKeys: String, CodingKey {
        case position, normal, title, description
        case workSessionId = "work_session_id"
        case markerType = "marker_type"
        case customProps = "custom_props"  // NEW
    }
}
```

### Update Marker Request

Add custom_props to your `UpdateMarkerRequest`:

```swift
struct UpdateMarkerRequest: Codable {
    let position: Position?
    let normal: Normal?
    let title: String?
    let description: String?
    let markerType: String?
    let customProps: [String: AnyCodable]?  // NEW
    
    enum CodingKeys: String, CodingKey {
        case position, normal, title, description
        case markerType = "marker_type"
        case customProps = "custom_props"  // NEW
    }
}
```

## AnyCodable Helper

To handle arbitrary JSON values, use this helper struct:

```swift
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
```

## Usage Examples

### Creating a Marker with Custom Props

```swift
func createMarker(sessionId: String, position: Position) async throws {
    let customProps: [String: AnyCodable] = [
        "severity": AnyCodable("high"),
        "category": AnyCodable("damage"),
        "priority": AnyCodable(1),
        "inspector": AnyCodable("John Doe"),
        "tags": AnyCodable(["urgent", "structural"]),
        "measurements": AnyCodable([
            "width": 15.5,
            "depth": 3.2
        ])
    ]
    
    let request = CreateMarkerRequest(
        workSessionId: sessionId,
        position: position,
        normal: nil,
        title: "Critical Structural Issue",
        description: "Crack detected in load-bearing wall",
        markerType: "issue",
        customProps: customProps  // NEW
    )
    
    let marker = try await apiClient.createMarker(request)
}
```

### Creating a Marker Without Custom Props

```swift
// If you don't provide customProps, it defaults to an empty object {}
let request = CreateMarkerRequest(
    workSessionId: sessionId,
    position: position,
    normal: nil,
    title: "Simple Marker",
    description: nil,
    markerType: "note",
    customProps: nil  // Will default to {}
)
```

### Updating Custom Props

```swift
func updateMarkerStatus(markerId: String, status: String) async throws {
    let updateRequest = UpdateMarkerRequest(
        position: nil,
        normal: nil,
        title: nil,
        description: nil,
        markerType: nil,
        customProps: [
            "status": AnyCodable(status),
            "reviewedAt": AnyCodable(ISO8601DateFormatter().string(from: Date())),
            "reviewedBy": AnyCodable(currentUser.name)
        ]
    )
    
    let updatedMarker = try await apiClient.updateMarker(id: markerId, request: updateRequest)
}
```

### Accessing Custom Props

```swift
func displayMarkerDetails(marker: Marker) {
    // Access custom properties
    if let severity = marker.customProps["severity"]?.value as? String {
        print("Severity: \(severity)")
    }
    
    if let priority = marker.customProps["priority"]?.value as? Int {
        print("Priority: \(priority)")
    }
    
    if let tags = marker.customProps["tags"]?.value as? [String] {
        print("Tags: \(tags.joined(separator: ", "))")
    }
    
    // Check if reviewed
    if let status = marker.customProps["status"]?.value as? String,
       status == "reviewed" {
        print("✓ This marker has been reviewed")
    }
}
```

### Filtering Markers by Custom Props

```swift
func getHighPriorityMarkers(markers: [Marker]) -> [Marker] {
    return markers.filter { marker in
        if let priority = marker.customProps["priority"]?.value as? Int {
            return priority >= 3
        }
        return false
    }
}

func getUnreviewedMarkers(markers: [Marker]) -> [Marker] {
    return markers.filter { marker in
        let status = marker.customProps["status"]?.value as? String
        return status != "reviewed"
    }
}
```

## UI Integration Examples

### SwiftUI View with Custom Props

```swift
struct MarkerDetailView: View {
    let marker: Marker
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(marker.title)
                .font(.headline)
            
            if let description = marker.description {
                Text(description)
                    .font(.body)
            }
            
            // Display custom properties
            if let severity = marker.customProps["severity"]?.value as? String {
                HStack {
                    Text("Severity:")
                    Text(severity)
                        .foregroundColor(severityColor(severity))
                        .bold()
                }
            }
            
            if let category = marker.customProps["category"]?.value as? String {
                HStack {
                    Text("Category:")
                    Text(category)
                        .foregroundColor(.secondary)
                }
            }
            
            if let tags = marker.customProps["tags"]?.value as? [String] {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(8)
                        }
                    }
                }
            }
        }
        .padding()
    }
    
    func severityColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "critical", "high": return .red
        case "medium": return .orange
        case "low": return .yellow
        default: return .gray
        }
    }
}
```

## Common Use Cases

### 1. Inspection Workflow
```swift
let inspectionProps: [String: AnyCodable] = [
    "inspector": AnyCodable(inspector.name),
    "inspectionDate": AnyCodable(ISO8601DateFormatter().string(from: Date())),
    "findings": AnyCodable("Requires immediate attention"),
    "followUpRequired": AnyCodable(true)
]
```

### 2. Damage Assessment
```swift
let damageProps: [String: AnyCodable] = [
    "damageType": AnyCodable("structural"),
    "severity": AnyCodable("high"),
    "estimatedCost": AnyCodable(5000.00),
    "repairPriority": AnyCodable(1)
]
```

### 3. AR Annotations
```swift
let arProps: [String: AnyCodable] = [
    "anchorId": AnyCodable(arAnchor.identifier.uuidString),
    "confidence": AnyCodable(arAnchor.confidence),
    "worldPosition": AnyCodable([
        "x": arAnchor.transform.columns.3.x,
        "y": arAnchor.transform.columns.3.y,
        "z": arAnchor.transform.columns.3.z
    ])
]
```

### 4. Measurement Data
```swift
let measurementProps: [String: AnyCodable] = [
    "unit": AnyCodable("meters"),
    "length": AnyCodable(2.5),
    "width": AnyCodable(1.8),
    "area": AnyCodable(4.5),
    "measuredBy": AnyCodable("LiDAR")
]
```

## API Endpoint Reference

All marker endpoints now support `custom_props`:

- **POST** `/api/v1/markers` - Create marker (customProps optional, defaults to {})
- **POST** `/api/v1/markers/bulk` - Bulk create markers (each can have different customProps)
- **PATCH** `/api/v1/markers/{id}` - Update marker (customProps optional)
- **GET** `/api/v1/markers/{id}` - Get marker (includes customProps)
- **GET** `/api/v1/work-sessions/{id}/markers` - List markers (all include customProps)

## Migration Notes

- Existing markers automatically get `customProps = {}` (empty object)
- No breaking changes - the field is always present but can be empty
- The field is indexed with GIN index for efficient JSON queries
- Maximum JSON nesting and size follows PostgreSQL JSONB limits

## Best Practices

1. **Use consistent keys**: Define constants for frequently used keys
   ```swift
   enum CustomPropsKeys {
       static let severity = "severity"
       static let category = "category"
       static let status = "status"
       static let priority = "priority"
   }
   ```

2. **Type safety**: Create typed wrappers for specific use cases
   ```swift
   extension Marker {
       var severity: String? {
           customProps["severity"]?.value as? String
       }
       
       var priority: Int? {
           customProps["priority"]?.value as? Int
       }
   }
   ```

3. **Validation**: Validate custom props before sending to API
   ```swift
   func validateCustomProps(_ props: [String: AnyCodable]) -> Bool {
       // Add your validation logic
       return true
   }
   ```

4. **Don't store large binary data**: Use custom_props for metadata, not files

## Testing

Test the feature using the provided test script:
```bash
./scripts/test-custom-props.sh
```

All tests should pass, verifying:
- Creating markers with custom_props
- Default empty object behavior
- Updating custom_props via PATCH
- Bulk operations
- List operations returning custom_props

## Support

For issues or questions about this feature, refer to:
- API Documentation: `/api/v1/docs`
- OpenAPI Spec: `static/openapi.json`
- Migration: `migrations/20251027000001_add_custom_props_to_markers.sql`
