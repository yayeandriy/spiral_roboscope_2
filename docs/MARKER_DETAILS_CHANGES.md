# MarkerDetails — iOS Changes (Architecture & Data Only)

This note summarizes only the changes iOS needs to be aware of, without re-explaining the whole feature.

## What changed architecturally

- Marker endpoints now return a wrapper shape (server-side): MarkerWithDetails
  - iOS continues to call the same endpoints (`/markers`, `/markers/{id}`, etc.).
  - Responses may include an extra `details` object alongside the existing marker fields.
  - Immediately after create/update, `details` can be null (computed asynchronously by backend).

- Optional dedicated endpoints exist for details (no requirement to use them):
  - `GET /api/v1/markers/{id}/details` — fetch
  - `PUT /api/v1/markers/{id}/details` — upsert
  - `DELETE /api/v1/markers/{id}/details` — remove
  - `POST /api/v1/markers/{id}/details/calculate` — explicit calculate + upsert

Compatibility:
- Existing decoding works (Swift’s Decodable ignores unknown keys). No breaking change.
- To consume details, add an optional `details` field to the iOS `Marker` model.

## Data representation updates

- New one-to-one table `marker_details` (enforced PK=FK on `marker_id`).
- Center position was split:
  - `center_location_long` (Z axis, "long"), `center_location_cross` (X axis, "cross").
- Measurement fields (meters, floats):
  - `left_distance`, `right_distance`, `far_distance`, `near_distance`, `long_size`, `cross_size`.
- Timestamps and `custom_props` JSON remain standard.

### Suggested Swift models (additive)

```swift
public struct MarkerDetails: Codable, Sendable {
    public let markerId: UUID
    public let centerLocationLong: Float
    public let centerLocationCross: Float
    public let leftDistance: Float
    public let rightDistance: Float
    public let farDistance: Float
    public let nearDistance: Float
    public let longSize: Float
    public let crossSize: Float
    public let customProps: [String: AnyCodable]
    public let createdAt: Date
    public let updatedAt: Date
}

public struct Marker: Codable, Sendable {
    // existing fields …
    public let id: UUID
    public let workSessionId: UUID
    public let label: String?
    public let p1: [Double]
    public let p2: [Double]
    public let p3: [Double]
    public let p4: [Double]
    public let color: String?
    public let version: Int
    public let meta: [String: AnyCodable]
    public let customProps: [String: AnyCodable]
    public let createdAt: Date
    public let updatedAt: Date

    // NEW (optional): present when server has computed details
    public let details: MarkerDetails?
}
```

Notes:
- Use `CodingKeys` if your codebase prefers snake_case mapping or custom date decoding.
- Keep `details` optional; handle `nil` as “not computed yet.”

## Minimal client changes

- No endpoint changes required for happy-path reads.
- If UI needs immediate numbers after create/update, you may:
  1) Call `POST /markers/{id}/details/calculate` then refetch marker; or
  2) Poll the marker until `details != nil` (bounded retries/backoff).
- Existing custom props usage is unchanged.

## References

- Backend spec: portal repo `docs/backend/MARKER_DETAILS_IMPLEMENTATION_GUIDE.md`
- Backend source: `roboscope_2_api/src/routes/{markers.rs,marker_details.rs}`, `roboscope_2_api/src/services/geometry.rs`
- Migrations: `20251029120000_marker_details.sql`, `20251029120001_split_center_location.sql`
