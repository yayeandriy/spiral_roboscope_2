//
//  Marker.swift
//  roboscope2
//
//  Data models for AR Marker management
//

import Foundation
import simd
import UIKit

// MARK: - Marker Models

/// Detailed metrics for a marker, computed server-side from the 4 corner points
struct MarkerDetails: Codable, Sendable, Hashable {
    let markerId: UUID
    let centerLocationLong: Float
    let centerLocationCross: Float
    let xNegative: Float
    let xPositive: Float
    let zPositive: Float
    let zNegative: Float
    let longSize: Float
    let crossSize: Float
    let customProps: [String: AnyCodable]
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case markerId = "marker_id"
        case centerLocationLong = "center_location_long"
        case centerLocationCross = "center_location_cross"
        case xNegative = "x_negative"
        case xPositive = "x_positive"
        case zPositive = "z_positive"
        case zNegative = "z_negative"
        case longSize = "long_size"
        case crossSize = "cross_size"
        case customProps = "custom_props"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Core Marker model representing a 3D annotation in space with 4 corner points
struct Marker: Codable, Identifiable, Hashable {
    let id: UUID
    let workSessionId: UUID
    let label: String?
    let p1: [Double]
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    /// Optional server-provided calibrated coordinates for the marker
    let calibratedData: CalibratedData?
    let color: String?
    let version: Int64
    let meta: [String: AnyCodable]
    let customProps: [String: AnyCodable]  // Custom properties for domain-specific metadata
    let createdAt: Date
    let updatedAt: Date
    var details: MarkerDetails? // Server-computed details (may be nil if not yet calculated)
    
    enum CodingKeys: String, CodingKey {
        case id, label, p1, p2, p3, p4, color, version, meta, details
        case workSessionId = "work_session_id"
        case customProps = "custom_props"
        case calibratedData = "calibrated_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    // MARK: - ARKit Convenience Properties
    
    /// Convert p1 to SIMD3<Float> for ARKit
    var point1: SIMD3<Float> {
        SIMD3<Float>(Float(p1[0]), Float(p1[1]), Float(p1[2]))
    }
    
    /// Convert p2 to SIMD3<Float> for ARKit
    var point2: SIMD3<Float> {
        SIMD3<Float>(Float(p2[0]), Float(p2[1]), Float(p2[2]))
    }
    
    /// Convert p3 to SIMD3<Float> for ARKit
    var point3: SIMD3<Float> {
        SIMD3<Float>(Float(p3[0]), Float(p3[1]), Float(p3[2]))
    }
    
    /// Convert p4 to SIMD3<Float> for ARKit
    var point4: SIMD3<Float> {
        SIMD3<Float>(Float(p4[0]), Float(p4[1]), Float(p4[2]))
    }
    
    /// All four corner points as SIMD3<Float> array for ARKit
    var points: [SIMD3<Float>] {
        [point1, point2, point3, point4]
    }
    
    /// Center point of the marker
    var center: SIMD3<Float> {
        let sum = point1 + point2 + point3 + point4
        return sum / 4.0
    }
    
    /// Approximate size of the marker (distance from center to farthest corner)
    var approximateSize: Float {
        let center = self.center
        let distances = points.map { simd_distance($0, center) }
        return distances.max() ?? 0.0
    }
    
    // MARK: - Color Helpers
    
    /// Get UIColor from hex color string
    var uiColor: UIColor? {
        guard let color = color else { return nil }
        return UIColor(hex: color)
    }
    
    /// Get default color if none specified
    static let defaultColor = "#FF0000" // Red
    
    /// Get display color (default to red if none specified)
    var displayColor: String {
        return color ?? Self.defaultColor
    }
    
    // MARK: - Custom Props Keys
    
    /// Key for plane-based frame dimensions in customProps
    static let frameDimsKey = "frame_dims"
    
    /// Key for mesh-based frame dimensions in customProps
    static let meshFrameDimsKey = "frame_dims_mesh"
}

// MARK: - Calibrated Data

/// Server-provided calibrated coordinate set for a marker
/// Matches docs: JSON object with p1..p4 and center, each [x,y,z] in meters
struct CalibratedData: Codable, Hashable, Sendable {
    let p1: [Double]
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    let center: [Double]
    
    // Convenience: SIMD conversions
    var point1: SIMD3<Float> { SIMD3<Float>(Float(p1[0]), Float(p1[1]), Float(p1[2])) }
    var point2: SIMD3<Float> { SIMD3<Float>(Float(p2[0]), Float(p2[1]), Float(p2[2])) }
    var point3: SIMD3<Float> { SIMD3<Float>(Float(p3[0]), Float(p3[1]), Float(p3[2])) }
    var point4: SIMD3<Float> { SIMD3<Float>(Float(p4[0]), Float(p4[1]), Float(p4[2])) }
    var centerPoint: SIMD3<Float> { SIMD3<Float>(Float(center[0]), Float(center[1]), Float(center[2])) }
    var points: [SIMD3<Float>] { [point1, point2, point3, point4] }
    
    /// Width (X) and Length (Z) calculated as axis-aligned extents
    var width: Float {
        let xs = [point1.x, point2.x, point3.x, point4.x]
        guard let minX = xs.min(), let maxX = xs.max() else { return 0 }
        return maxX - minX
    }
    var length: Float {
        let zs = [point1.z, point2.z, point3.z, point4.z]
        guard let minZ = zs.min(), let maxZ = zs.max() else { return 0 }
        return maxZ - minZ
    }
}

// MARK: - Marker DTOs

/// DTO for creating a new Marker
struct CreateMarker: Codable {
    let workSessionId: UUID
    let label: String?
    let p1: [Double]
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    let color: String?
    let meta: [String: AnyCodable]?
    let customProps: [String: AnyCodable]?  // Custom properties (optional, defaults to {} on backend)
    
    enum CodingKeys: String, CodingKey {
        case label, p1, p2, p3, p4, color, meta
        case workSessionId = "work_session_id"
        case customProps = "custom_props"
    }
    
    /// Initialize with SIMD3<Float> points (for ARKit integration)
    init(
        workSessionId: UUID,
        label: String? = nil,
        points: [SIMD3<Float>],
        color: String? = nil,
        meta: [String: Any]? = nil,
        customProps: [String: Any]? = nil
    ) {
        guard points.count == 4 else {
            fatalError("Marker must have exactly 4 points")
        }
        
        self.workSessionId = workSessionId
        self.label = label
        self.p1 = [Double(points[0].x), Double(points[0].y), Double(points[0].z)]
        self.p2 = [Double(points[1].x), Double(points[1].y), Double(points[1].z)]
        self.p3 = [Double(points[2].x), Double(points[2].y), Double(points[2].z)]
        self.p4 = [Double(points[3].x), Double(points[3].y), Double(points[3].z)]
        self.color = color ?? Marker.defaultColor
        self.meta = meta?.mapValues { AnyCodable($0) }
        self.customProps = customProps?.mapValues { AnyCodable($0) }
    }
    
    /// Initialize with Double arrays (for direct API usage)
    init(
        workSessionId: UUID,
        label: String? = nil,
        p1: [Double],
        p2: [Double],
        p3: [Double],
        p4: [Double],
        color: String? = nil,
        meta: [String: Any]? = nil,
        customProps: [String: Any]? = nil
    ) {
        self.workSessionId = workSessionId
        self.label = label
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
        self.p4 = p4
        self.color = color ?? Marker.defaultColor
        self.meta = meta?.mapValues { AnyCodable($0) }
        self.customProps = customProps?.mapValues { AnyCodable($0) }
    }
}

/// DTO for bulk creating multiple markers
struct BulkCreateMarkers: Codable {
    let markers: [CreateMarker]
}

/// DTO for updating an existing Marker
struct UpdateMarker: Codable {
    let workSessionId: UUID?
    let label: String?
    let p1: [Double]?
    let p2: [Double]?
    let p3: [Double]?
    let p4: [Double]?
    let color: String?
    let version: Int64? // For optimistic locking
    let meta: [String: AnyCodable]?
    let customProps: [String: AnyCodable]?  // Custom properties (optional)
    
    enum CodingKeys: String, CodingKey {
        case label, p1, p2, p3, p4, color, version, meta
        case workSessionId = "work_session_id"
        case customProps = "custom_props"
    }
    
    /// Initialize with SIMD3<Float> points (for ARKit integration)
    init(
        workSessionId: UUID? = nil,
        label: String? = nil,
        points: [SIMD3<Float>]? = nil,
        color: String? = nil,
        version: Int64? = nil,
        meta: [String: Any]? = nil,
        customProps: [String: Any]? = nil
    ) {
        self.workSessionId = workSessionId
        self.label = label
        
        if let points = points {
            guard points.count == 4 else {
                fatalError("Marker must have exactly 4 points")
            }
            self.p1 = [Double(points[0].x), Double(points[0].y), Double(points[0].z)]
            self.p2 = [Double(points[1].x), Double(points[1].y), Double(points[1].z)]
            self.p3 = [Double(points[2].x), Double(points[2].y), Double(points[2].z)]
            self.p4 = [Double(points[3].x), Double(points[3].y), Double(points[3].z)]
        } else {
            self.p1 = nil
            self.p2 = nil
            self.p3 = nil
            self.p4 = nil
        }
        
        self.color = color
        self.version = version
        self.meta = meta?.mapValues { AnyCodable($0) }
        self.customProps = customProps?.mapValues { AnyCodable($0) }
    }
}

