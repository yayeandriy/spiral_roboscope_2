//
//  ReferenceSet.swift
//  roboscope2
//

import Foundation

// MARK: - Reference Marker

struct ReferenceMarker: Codable, Identifiable, Hashable {
    let id: UUID
    let label: String?
    let p1: [Double]  // 4 corner points in 3D
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    let color: String?

    // Convenience: center of the marker
    var center: SIMD3<Float> {
        let x = Float((p1[0] + p2[0] + p3[0] + p4[0]) / 4.0)
        let y = Float((p1[1] + p2[1] + p3[1] + p4[1]) / 4.0)
        let z = Float((p1[2] + p2[2] + p3[2] + p4[2]) / 4.0)
        return SIMD3<Float>(x, y, z)
    }

    // Convenience: the 4 corners as SIMD3
    var corners: [SIMD3<Float>] {
        [
            SIMD3<Float>(Float(p1[0]), Float(p1[1]), Float(p1[2])),
            SIMD3<Float>(Float(p2[0]), Float(p2[1]), Float(p2[2])),
            SIMD3<Float>(Float(p3[0]), Float(p3[1]), Float(p3[2])),
            SIMD3<Float>(Float(p4[0]), Float(p4[1]), Float(p4[2])),
        ]
    }

    enum CodingKeys: String, CodingKey {
        case id, label, p1, p2, p3, p4, color
    }
}

// MARK: - Reference Set

struct ReferenceSet: Codable, Identifiable, Hashable {
    let id: UUID
    let spaceId: String
    let name: String
    let description: String?
    let markers: [ReferenceMarker]
    let version: Int64
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case spaceId = "space_id"
        case name, description, markers, version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - DTO: Create Reference Set

struct CreateReferenceSet: Encodable {
    let name: String
    let description: String?
    let markers: [CreateReferenceMarker]
}

struct CreateReferenceMarker: Encodable {
    let id: UUID
    let label: String?
    let p1: [Double]
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    let color: String?
}
