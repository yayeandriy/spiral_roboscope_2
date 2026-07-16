//
//  RepairModels.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Codable DTOs bound EXACTLY to spiral-roboscope-veranda/docs/implementation/02-contracts.md
//  (the frozen wire contract). Explicit CodingKeys everywhere; decoder uses .iso8601.
//  NEVER enable convertFromSnakeCase (00-rules-and-boundaries.md §0.9).
//
//  These are intentionally separate from the existing Roboscope `Space`/`Marker`/etc. models:
//  Repair talks to a different backend (Veranda) with a different, frozen JSON shape
//  (e.g. proxied Space has a STRING id, not a UUID like the local Roboscope `Space` model).
//

import Foundation
import UIKit

// MARK: - CoremlModel (02-contracts.md §2.1)

struct CoremlModel: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let description: String?
    let storageUrl: String
    let fileHash: String
    let classLabels: [String]
    let isDefault: Bool
    let isActive: Bool
    /// Per-class marker appearance + reference-sheet corner, admin-configured in the web portal
    /// (app/admin/models — mobile is read-only here). Keyed by class label (a subset of
    /// `classLabels` — a class may have no entry at all). Optional at the model level too, in
    /// case some response omits the key entirely rather than sending `{}`.
    let classStyles: [String: RepairClassStyle]?
    /// v0.4 — Planning/Validation sub-mode split. Admin-set flags indicating which model is the
    /// default for each mode; independent of the legacy `isDefault` (kept as the Planning
    /// fallback for backends that haven't set `is_default_planning` yet). Optional/lenient:
    /// treated as `false` when absent, so an older backend response without these keys at all
    /// still decodes fine.
    let isDefaultPlanning: Bool?
    let isDefaultValidation: Bool?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case storageUrl = "storage_url"
        case fileHash = "file_hash"
        case classLabels = "class_labels"
        case isDefault = "is_default"
        case isActive = "is_active"
        case classStyles = "class_styles"
        case isDefaultPlanning = "is_default_planning"
        case isDefaultValidation = "is_default_validation"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - RepairClassStyle (class_styles v0.2 — per-class marker appearance + reference-sheet corner)
//
// Backend contract (2026-07-15): every entry's 3 fields are independently optional — a class may
// have only `corner` set, only `shape`+`color`, all three, or no entry at all in `class_styles`.
// `shape`/`color` are display-only (marker appearance, admin-set in the portal). `corner` marks
// which corner of a physical reference/calibration sheet this class's marker corresponds to —
// purely a hint for us; the API/web never interpret it. We use it to decide WHERE on the
// detected bounding box to raycast/place the pin: the same corner of the box as the marker's
// role on the sheet, in the convention of a user looking at the phone in portrait (top_left =
// physical top-left of the screen) — see RepairARSessionView+Logic.anchorPoint for how that's
// resolved against the actual (frequently rotated/mirrored) camera-buffer coordinate space.

struct RepairClassStyle: Codable, Hashable {
    let shape: String?
    let color: String?
    let corner: RepairMarkerCorner?

    enum CodingKeys: String, CodingKey {
        case shape, color, corner
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decodeIfPresent(String.self, forKey: .shape)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        // Lenient per backend guidance: an unrecognized/future corner value becomes nil
        // (falls back to centroid placement) instead of failing the whole model decode.
        if let raw = try container.decodeIfPresent(String.self, forKey: .corner) {
            corner = RepairMarkerCorner(rawValue: raw)
        } else {
            corner = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(shape, forKey: .shape)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(corner?.rawValue, forKey: .corner)
    }
}

enum RepairMarkerCorner: String, Codable {
    case topLeft = "top_left"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"
}

extension RepairClassStyle {
    /// Deterministic fallback color keyed by class label, spread across a fixed palette — used
    /// when a model's `class_styles` doesn't specify an explicit color for a class. Validation
    /// models in particular usually aren't the corner-marker models `class_styles` was built
    /// for (02-contracts.md v0.2 was scoped to Planning's l1/l2/r1/r2-style markers), so without
    /// this every class in a multi-class Validation overlay would otherwise collapse onto the
    /// same default green. Same label always maps to the same color within a run (Hasher's seed
    /// is randomized per process launch, not per call), which is enough for "different classes
    /// look different" — it doesn't need to be stable across app restarts.
    static func autoColor(for label: String) -> UIColor {
        var hasher = Hasher()
        hasher.combine(label)
        let index = abs(hasher.finalize()) % autoPalette.count
        return autoPalette[index]
    }

    private static let autoPalette: [UIColor] = [
        .systemGreen, .systemBlue, .systemOrange, .systemPurple, .systemPink,
        .systemYellow, .systemTeal, .systemRed, .systemIndigo, .systemMint, .systemBrown, .systemCyan,
    ]
}

// MARK: - RepairSession (02-contracts.md §2.1)

struct RepairSession: Codable, Identifiable, Hashable {
    let id: UUID
    let spaceId: String
    let spaceNameCache: String?
    let coremlModelId: UUID
    let status: String
    let deviceLabel: String?
    let startedAt: Date
    let closedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    /// Some list endpoints add a computed pin_count — optional, clients must tolerate absence.
    let pinCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, status
        case spaceId = "space_id"
        case spaceNameCache = "space_name_cache"
        case coremlModelId = "coreml_model_id"
        case deviceLabel = "device_label"
        case startedAt = "started_at"
        case closedAt = "closed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pinCount = "pin_count"
    }

    var isActive: Bool { status == "active" }
    var isClosed: Bool { status == "closed" }
}

// MARK: - Pin (02-contracts.md §2.1)

struct Pin: Codable, Identifiable, Hashable {
    let id: UUID
    let repairSessionId: UUID
    /// [x, y, z] meters, raw ARKit world (session-relative). No transform is ever applied server-side.
    let position: [Double]
    let detectionClass: String
    let confidence: Float
    let customProps: [String: AnyCodable]?
    /// Set via `POST /pins/{id}/photo` (0006_pin_photo.sql); null until a photo is attached.
    let photoUrl: String?
    /// Optional 3D box around the detection, same coordinate space as `position` (v0.3). Stored
    /// as opaque JSON server-side and returned unchanged — nil for pins created without one.
    let boundingBox: RepairBoundingBox?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, position, confidence
        case repairSessionId = "repair_session_id"
        case detectionClass = "detection_class"
        case customProps = "custom_props"
        case photoUrl = "photo_url"
        case boundingBox = "bounding_box"
        case createdAt = "created_at"
    }

    /// Convenience accessor for AR/RealityKit use. Falls back to zero if malformed (should never happen
    /// against a contract-conformant server, but guards against a crash on a bad payload).
    var worldPosition: SIMD3<Float> {
        guard position.count == 3 else { return SIMD3<Float>(0, 0, 0) }
        return SIMD3<Float>(Float(position[0]), Float(position[1]), Float(position[2]))
    }
}

// MARK: - Space (proxied, read-only — 02-contracts.md §2.1)

/// Deliberately distinct from the existing local `Space` model: the Veranda spaces proxy
/// passes through Roboscope's space JSON, whose `id` is treated here as an opaque STRING
/// (never validated against a local table — 02-contracts.md §2.5). Only `id` + `name` are
/// required for the picker; other fields are decoded leniently to tolerate passthrough drift.
struct RepairSpace: Codable, Identifiable, Hashable {
    let id: String
    let key: String?
    let name: String
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id, key, name
        case isActive = "is_active"
    }
}

/// GET /v1/spaces response envelope (NOT a bare array — see 02-contracts.md §2.3).
struct RepairSpacesResponse: Codable {
    let spaces: [RepairSpace]
    let stale: Bool?
    let warning: String?
}

// MARK: - Request bodies (02-contracts.md §2.2, §2.6)

struct CreateRepairSession: Codable {
    let spaceId: String
    let spaceNameCache: String?
    let coremlModelId: UUID
    let deviceLabel: String?

    enum CodingKeys: String, CodingKey {
        case spaceId = "space_id"
        case spaceNameCache = "space_name_cache"
        case coremlModelId = "coreml_model_id"
        case deviceLabel = "device_label"
    }
}

struct CreatePin: Codable {
    let repairSessionId: UUID
    let position: [Double]
    let detectionClass: String
    let confidence: Float
    /// Optional 3D box around the detection, same coordinate space as `position` (v0.3). Set
    /// once at creation time — there's no separate endpoint/PATCH to add or update it later.
    let boundingBox: RepairBoundingBox?

    enum CodingKeys: String, CodingKey {
        case position, confidence
        case repairSessionId = "repair_session_id"
        case detectionClass = "detection_class"
        case boundingBox = "bounding_box"
    }

    init(
        repairSessionId: UUID,
        world: SIMD3<Float>,
        detectionClass: String,
        confidence: Float,
        boundingBoxCorners: [SIMD3<Float>]? = nil
    ) {
        self.repairSessionId = repairSessionId
        self.position = [Double(world.x), Double(world.y), Double(world.z)]
        self.detectionClass = detectionClass
        self.confidence = confidence
        if let boundingBoxCorners, boundingBoxCorners.count == 8 {
            self.boundingBox = RepairBoundingBox(corners: boundingBoxCorners.map {
                [Double($0.x), Double($0.y), Double($0.z)]
            })
        } else {
            self.boundingBox = nil
        }
    }
}

struct CreatePinsBulk: Codable {
    /// All entries must share one repair_session_id (API validates this too).
    let pins: [CreatePin]
}

/// Pin.bounding_box (v0.3) — exactly 8 [x,y,z] corners, same raw ARKit-world space as
/// `position`. Corner order: 0,1,2,3 form one face (closed loop 0->1->2->3->0), 4,5,6,7 form the
/// opposite face in the same winding, and corner i connects straight across to corner i+4 for i
/// in 0..3. The API stores/returns this as opaque JSON and never validates it — getting the
/// 8-corner order right and consistent is entirely on the client (us).
struct RepairBoundingBox: Codable, Hashable {
    let corners: [[Double]]
}

// MARK: - RepairSessionPhoto (0007_session_photos.sql — manual "take picture" captures)

/// One manual capture event: always a `raw` frame, plus a best-effort `annotated` (pins baked
/// in) frame that may be null if that render/upload failed. Not tied to any specific pin —
/// distinct from `Pin.photoUrl`.
struct RepairSessionPhoto: Codable, Identifiable, Hashable {
    let id: UUID
    let repairSessionId: UUID
    let rawUrl: String
    let annotatedUrl: String?
    let capturedAt: Date
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case repairSessionId = "repair_session_id"
        case rawUrl = "raw_url"
        case annotatedUrl = "annotated_url"
        case capturedAt = "captured_at"
        case createdAt = "created_at"
    }
}

/// GET /repair-sessions/{id}/photos response envelope (not a bare array).
struct RepairSessionPhotosResponse: Codable {
    let photos: [RepairSessionPhoto]
}
