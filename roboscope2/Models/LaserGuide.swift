//
//  LaserGuide.swift
//  roboscope2
//
//  Data models for Space Laser Guide (grid segments)
//

import Foundation

struct LaserGuide: Codable, Identifiable, Hashable {
    let id: UUID
    let spaceId: UUID
    let grid: [LaserGuideGridSegment]
    let meta: [String: AnyCodable]?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, grid, meta
        case spaceId = "space_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct LaserGuideGridSegment: Codable, Hashable {
    let x: Double
    let z: Double
    let segmentLength: Double

    enum CodingKeys: String, CodingKey {
        case x, z
        case segmentLength = "segment_length"
    }
}
