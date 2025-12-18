# Laser Guide (iOS Guide)

This document explains how the iOS app should **fetch** and **use** a Space’s Laser Guide to render a guide/grid overlay.

## What Laser Guide is

A Laser Guide is a per-space configuration that describes a grid as **a list of segments**.

- The iOS app typically treats it as **read-only** (configured via Portal/Admin).
- The iOS app fetches it by `space_id` and renders it as lines/segments in the space coordinate system.

## API: fetch by Space

Use:

- `GET /api/v1/spaces/{space_id}/laser-guide`

Behavior:

- `200 OK`: Laser Guide exists; response is a full Laser Guide object.
- `404 Not Found`: No Laser Guide configured for this space yet (treat as “no guide”, not an error).

### Response shape

```json
{
  "id": "uuid",
  "space_id": "uuid",
  "grid": [
    { "x": 0.0, "z": 0.0, "segment_length": 0.5 },
    { "x": 0.5, "z": 0.0, "segment_length": 0.5 }
  ],
  "meta": {},
  "created_at": "2025-...",
  "updated_at": "2025-..."
}
```

## Data model (important)

The `grid` is an **array** of segments:

```json
{
  "grid": [
    { "x": 1.5, "z": 1.23, "segment_length": 0.5 }
  ]
}
```

Field meanings:

- `x`: X position in the space coordinate system (meters)
- `z`: Z position in the space coordinate system (meters)
- `segment_length`: length of this segment (meters)

Notes:

- Laser Guide segments are **2D on the floor plane** (X/Z). There is no `y` in the payload.
- Units are **meters**.

## iOS decoding (Swift)

You can decode the payload with `Codable`. The only mildly “custom” field is `meta`, which is arbitrary JSON.

### Suggested models

```swift
import Foundation

struct LaserGuide: Codable, Identifiable {
    let id: UUID
    let spaceId: UUID
    let grid: [GridSegment]
    let meta: [String: JSONValue]
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, grid, meta
        case spaceId = "space_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GridSegment: Codable {
    let x: Double
    let z: Double
    let segmentLength: Double

    enum CodingKeys: String, CodingKey {
        case x, z
        case segmentLength = "segment_length"
    }
}

// Minimal JSON representation for meta.
// If you already have an AnyCodable/JSONValue type in the app, use that instead.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        }
    }
}
```

### Fetch function (treat 404 as “no guide”)

```swift
import Foundation

func fetchLaserGuide(baseURL: URL, spaceId: UUID, token: String) async throws -> LaserGuide? {
    var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/spaces/\(spaceId.uuidString)/laser-guide"))
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }

    if http.statusCode == 404 {
        return nil
    }

    guard (200...299).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LaserGuide.self, from: data)
}
```

## Rendering guidance (RealityKit/SceneKit)

How you render depends on your overlay pipeline, but the safest assumptions are:

- Treat each segment’s position as a point on the **floor plane** in space-local coordinates.
- Convert to your engine’s vector type:
  - RealityKit: `SIMD3<Float>(Float(x), 0, Float(z))`
  - SceneKit: `SCNVector3(x, 0, z)`
- Apply the same **space alignment / calibration transform** you already use for other space-local overlays.

### Practical defaults

- When there is **no Laser Guide** (404): hide the overlay and proceed normally.
- Fetch once when:
  - the user selects/enters a space
  - and/or a scanning/work session starts
- Refresh only on explicit user action or when you know the guide was updated.

## Validation & error handling

- If `grid` is empty, treat it as “nothing to render”.
- If any segment has `segment_length <= 0`, ignore that segment.
- Network failures should not block core scanning flows; show overlay only when available.
