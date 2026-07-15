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
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case storageUrl = "storage_url"
        case fileHash = "file_hash"
        case classLabels = "class_labels"
        case isDefault = "is_default"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
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
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, position, confidence
        case repairSessionId = "repair_session_id"
        case detectionClass = "detection_class"
        case customProps = "custom_props"
        case photoUrl = "photo_url"
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

    enum CodingKeys: String, CodingKey {
        case position, confidence
        case repairSessionId = "repair_session_id"
        case detectionClass = "detection_class"
    }

    init(repairSessionId: UUID, world: SIMD3<Float>, detectionClass: String, confidence: Float) {
        self.repairSessionId = repairSessionId
        self.position = [Double(world.x), Double(world.y), Double(world.z)]
        self.detectionClass = detectionClass
        self.confidence = confidence
    }
}

struct CreatePinsBulk: Codable {
    /// All entries must share one repair_session_id (API validates this too).
    let pins: [CreatePin]
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
