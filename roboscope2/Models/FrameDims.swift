//
//  FrameDims.swift
//  roboscope2
//
//  Data models for Marker Frame Dimensions feature
//  See docs/MARKER_FRAME_DIMS.ms for specification
//

import Foundation
import simd

// MARK: - Frame Dimensions Data Models

/// Axis-Aligned Bounding Box in FrameOrigin coordinates
struct AABB: Codable, Hashable {
    let min: SIMD3<Float>
    let max: SIMD3<Float>
    
    var dimensions: SIMD3<Float> {
        max - min
    }
    
    init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }
    
    // Custom Codable to encode as arrays
    enum CodingKeys: String, CodingKey {
        case min, max
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([min.x, min.y, min.z], forKey: .min)
        try container.encode([max.x, max.y, max.z], forKey: .max)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minArray = try container.decode([Float].self, forKey: .min)
        let maxArray = try container.decode([Float].self, forKey: .max)
        
        guard minArray.count == 3, maxArray.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .min,
                in: container,
                debugDescription: "AABB min/max must have 3 components"
            )
        }
        
        self.min = SIMD3<Float>(minArray[0], minArray[1], minArray[2])
        self.max = SIMD3<Float>(maxArray[0], maxArray[1], maxArray[2])
    }
}

/// Oriented Bounding Box in FrameOrigin coordinates (using PCA)
struct OBB: Codable {
    let center: SIMD3<Float>
    let axes: simd_float3x3  // Column-major: each column is a principal direction
    let extents: SIMD3<Float>  // Half-widths along each principal axis
    
    init(center: SIMD3<Float>, axes: simd_float3x3, extents: SIMD3<Float>) {
        self.center = center
        self.axes = axes
        self.extents = extents
    }
    
    // Custom Codable to encode as arrays
    enum CodingKeys: String, CodingKey {
        case center, axes, extents
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([center.x, center.y, center.z], forKey: .center)
        
        // Encode axes as 3x3 array
        let axesArray: [[Float]] = [
            [axes.columns.0.x, axes.columns.0.y, axes.columns.0.z],
            [axes.columns.1.x, axes.columns.1.y, axes.columns.1.z],
            [axes.columns.2.x, axes.columns.2.y, axes.columns.2.z]
        ]
        try container.encode(axesArray, forKey: .axes)
        try container.encode([extents.x, extents.y, extents.z], forKey: .extents)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let centerArray = try container.decode([Float].self, forKey: .center)
        let axesArray = try container.decode([[Float]].self, forKey: .axes)
        let extentsArray = try container.decode([Float].self, forKey: .extents)
        
        guard centerArray.count == 3, extentsArray.count == 3,
              axesArray.count == 3, axesArray.allSatisfy({ $0.count == 3 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .center,
                in: container,
                debugDescription: "OBB components must have correct dimensions"
            )
        }
        
        self.center = SIMD3<Float>(centerArray[0], centerArray[1], centerArray[2])
        self.extents = SIMD3<Float>(extentsArray[0], extentsArray[1], extentsArray[2])
        
        // Reconstruct axes matrix
        let col0 = SIMD3<Float>(axesArray[0][0], axesArray[0][1], axesArray[0][2])
        let col1 = SIMD3<Float>(axesArray[1][0], axesArray[1][1], axesArray[1][2])
        let col2 = SIMD3<Float>(axesArray[2][0], axesArray[2][1], axesArray[2][2])
        self.axes = simd_float3x3(columns: (col0, col1, col2))
    }
}

// Hashable conformance for OBB
extension OBB: Hashable {
    static func == (lhs: OBB, rhs: OBB) -> Bool {
        return lhs.center == rhs.center &&
               lhs.extents == rhs.extents &&
               lhs.axes.columns.0 == rhs.axes.columns.0 &&
               lhs.axes.columns.1 == rhs.axes.columns.1 &&
               lhs.axes.columns.2 == rhs.axes.columns.2
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(center.x)
        hasher.combine(center.y)
        hasher.combine(center.z)
        hasher.combine(extents.x)
        hasher.combine(extents.y)
        hasher.combine(extents.z)
        hasher.combine(axes.columns.0.x)
        hasher.combine(axes.columns.0.y)
        hasher.combine(axes.columns.0.z)
        hasher.combine(axes.columns.1.x)
        hasher.combine(axes.columns.1.y)
        hasher.combine(axes.columns.1.z)
        hasher.combine(axes.columns.2.x)
        hasher.combine(axes.columns.2.y)
        hasher.combine(axes.columns.2.z)
    }
}

/// Per-edge, per-point distances
struct EdgeDistances: Codable, Hashable {
    let perPoint: [String: Float]  // e.g., "p1": 0.42, "p2": 0.41, ...
    
    init(perPoint: [String: Float]) {
        self.perPoint = perPoint
    }
    
    enum CodingKeys: String, CodingKey {
        case perPoint = "per_point"
    }
}

/// Aggregated minimal distances from marker to each RM edge/surface
struct FrameDimsAggregate: Codable, Hashable {
    let left: Float
    let right: Float
    let near: Float
    let far: Float
    let top: Float
    let bottom: Float
    
    init(left: Float, right: Float, near: Float, far: Float, top: Float, bottom: Float) {
        self.left = left
        self.right = right
        self.near = near
        self.far = far
        self.top = top
        self.bottom = bottom
    }
}

/// Size metrics for marker
struct FrameDimsSizes: Codable, Hashable {
    let aabb: AABB
    let obb: OBB
    
    init(aabb: AABB, obb: OBB) {
        self.aabb = aabb
        self.obb = obb
    }
}

/// Optional projected dimensions
struct FrameDimsProjected: Codable, Hashable {
    let aabb: AABB?
    let obb: OBB?
    
    init(aabb: AABB?, obb: OBB?) {
        self.aabb = aabb
        self.obb = obb
    }
}

/// Metadata for frame dims computation
struct FrameDimsMeta: Codable, Hashable {
    let computedAtIso: String
    let epsilon: Float
    let notes: String?
    
    init(computedAtIso: String = ISO8601DateFormatter().string(from: Date()),
         epsilon: Float = 1e-5,
         notes: String? = nil) {
        self.computedAtIso = computedAtIso
        self.epsilon = epsilon
        self.notes = notes
    }
    
    enum CodingKeys: String, CodingKey {
        case computedAtIso = "computed_at_iso"
        case epsilon
        case notes
    }
}

/// Plane definition in FrameOrigin coordinates
struct Plane: Codable, Hashable {
    let n: SIMD3<Float>  // Unit normal
    let d: Float         // Signed offset
    
    init(n: SIMD3<Float>, d: Float) {
        self.n = n
        self.d = d
    }
    
    /// Unsigned distance from point to plane
    func distance(to point: SIMD3<Float>) -> Float {
        abs(simd_dot(n, point) + d)
    }
    
    // Custom Codable
    enum CodingKeys: String, CodingKey {
        case n, d
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([n.x, n.y, n.z], forKey: .n)
        try container.encode(d, forKey: .d)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nArray = try container.decode([Float].self, forKey: .n)
        self.d = try container.decode(Float.self, forKey: .d)
        
        guard nArray.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .n,
                in: container,
                debugDescription: "Plane normal must have 3 components"
            )
        }
        
        self.n = SIMD3<Float>(nArray[0], nArray[1], nArray[2])
    }
}

/// Frame axes description
struct FrameAxes: Codable, Hashable {
    let x: String
    let y: String
    let z: String
    
    init(x: String = "left-right", y: String = "up-down", z: String = "near-far") {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Complete frame dimensions result
struct FrameDimsResult: Codable, Hashable {
    let version: Int
    let units: String
    let foAxes: FrameAxes
    let rmKind: String?
    let planes: [String: Plane]?
    let perEdge: [String: EdgeDistances]
    let aggregate: FrameDimsAggregate
    let sizes: FrameDimsSizes
    let projected: FrameDimsProjected?
    let meta: FrameDimsMeta
    
    init(
        version: Int = 1,
        units: String = "m",
        foAxes: FrameAxes = FrameAxes(),
        rmKind: String? = "room",
        planes: [String: Plane]? = nil,
        perEdge: [String: EdgeDistances],
        aggregate: FrameDimsAggregate,
        sizes: FrameDimsSizes,
        projected: FrameDimsProjected? = nil,
        meta: FrameDimsMeta = FrameDimsMeta()
    ) {
        self.version = version
        self.units = units
        self.foAxes = foAxes
        self.rmKind = rmKind
        self.planes = planes
        self.perEdge = perEdge
        self.aggregate = aggregate
        self.sizes = sizes
        self.projected = projected
        self.meta = meta
    }
    
    enum CodingKeys: String, CodingKey {
        case version, units, planes, aggregate, sizes, projected, meta
        case foAxes = "fo_axes"
        case rmKind = "rm_kind"
        case perEdge = "per_edge"
    }
}

// MARK: - Custom Props Key
extension Marker {
    /// Key for accessing frame_dims in custom_props
    static let frameDimsKey = "frame_dims"
    
    /// Get frame dims from custom props
    var frameDims: FrameDimsResult? {
        guard let frameDimsData = customProps[Self.frameDimsKey],
              let dict = frameDimsData.value as? [String: Any] else {
            return nil
        }
        
        // Convert to JSON and decode
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: dict)
            let result = try JSONDecoder().decode(FrameDimsResult.self, from: jsonData)
            return result
        } catch {
            print("Failed to decode frame_dims: \(error)")
            return nil
        }
    }
}
