//
//  Anchor.swift
//  roboscope2
//
//  A 3D origin point placed by the user for a given laser guide table
//  segmentation (identified by local_z) within a work session run.
//

import Foundation
import simd

// MARK: - Anchor

struct Anchor: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionId: UUID
    /// AR session run index (1-based). Anchors within the same run share a world-coordinate frame.
    /// A new run starts each time the iOS app relaunches the AR session for this work session.
    let run: Int
    /// Z coordinate in the local coordinate system of the laser guide table row.
    let localZ: Double
    /// Position in world (ARKit) coordinates: [x, y, z].
    let worldPosition: [Double]
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case run
        case localZ = "local_z"
        case worldPosition = "world_position"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Convenience accessor as SIMD3<Float> for ARKit / RealityKit operations.
    var worldPositionSIMD: SIMD3<Float> {
        guard worldPosition.count == 3 else { return .zero }
        return SIMD3<Float>(Float(worldPosition[0]),
                            Float(worldPosition[1]),
                            Float(worldPosition[2]))
    }
}

// MARK: - DTOs

struct CreateAnchor: Codable {
    let sessionId: UUID
    let run: Int
    let localZ: Double
    let worldPosition: [Double]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case run
        case localZ = "local_z"
        case worldPosition = "world_position"
    }

    init(sessionId: UUID, run: Int, localZ: Double, worldPosition: SIMD3<Float>) {
        self.sessionId = sessionId
        self.run = run
        self.localZ = localZ
        self.worldPosition = [Double(worldPosition.x),
                              Double(worldPosition.y),
                              Double(worldPosition.z)]
    }
}

struct UpdateAnchor: Codable {
    let worldPosition: [Double]

    enum CodingKeys: String, CodingKey {
        case worldPosition = "world_position"
    }

    init(worldPosition: SIMD3<Float>) {
        self.worldPosition = [Double(worldPosition.x),
                              Double(worldPosition.y),
                              Double(worldPosition.z)]
    }
}
