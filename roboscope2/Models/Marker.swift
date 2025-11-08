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
    
    /// Width (X) and Length (Z) estimated like raw: average of opposite edges
    var width: Float {
        let e01 = simd_distance(point1, point2)
        let e23 = simd_distance(point3, point4)
        return (e01 + e23) / 2.0
    }
    var length: Float {
        let e12 = simd_distance(point2, point3)
        let e30 = simd_distance(point4, point1)
        return (e12 + e30) / 2.0
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

// MARK: - UIColor Extension for Hex Colors

extension UIColor {
    convenience init?(hex: String) {
        let r, g, b, a: CGFloat
        
        var hexColor = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexColor.hasPrefix("#") {
            hexColor.removeFirst()
        }
        
        if hexColor.count == 6 {
            let scanner = Scanner(string: hexColor)
            var hexNumber: UInt64 = 0
            
            if scanner.scanHexInt64(&hexNumber) {
                r = CGFloat((hexNumber & 0xff0000) >> 16) / 255
                g = CGFloat((hexNumber & 0x00ff00) >> 8) / 255
                b = CGFloat(hexNumber & 0x0000ff) / 255
                a = 1.0
                
                self.init(red: r, green: g, blue: b, alpha: a)
                return
            }
        }
        
        return nil
    }
    
    var hexString: String {
        let components = self.cgColor.components
        let r: CGFloat = components?[0] ?? 0.0
        let g: CGFloat = components?[1] ?? 0.0
        let b: CGFloat = components?[2] ?? 0.0
        
        let hexString = String.init(format: "#%02lX%02lX%02lX",
                                   lroundf(Float(r * 255)),
                                   lroundf(Float(g * 255)),
                                   lroundf(Float(b * 255)))
        return hexString
    }
}

// MARK: - Custom Props Keys (Constants for type safety)

/// Predefined keys for commonly used custom properties
enum CustomPropsKeys {
    // Inspection & Assessment
    static let severity = "severity"
    static let category = "category"
    static let status = "status"
    static let priority = "priority"
    static let inspector = "inspector"
    static let inspectionDate = "inspectionDate"
    static let findings = "findings"
    static let followUpRequired = "followUpRequired"
    
    // Damage Assessment
    static let damageType = "damageType"
    static let estimatedCost = "estimatedCost"
    static let repairPriority = "repairPriority"
    
    // AR Tracking
    static let anchorId = "anchorId"
    static let confidence = "confidence"
    static let worldPosition = "worldPosition"
    
    // Measurements
    static let unit = "unit"
    static let length = "length"
    static let width = "width"
    static let height = "height"
    static let area = "area"
    static let volume = "volume"
    static let measuredBy = "measuredBy"
    
    // Workflow
    static let reviewedAt = "reviewedAt"
    static let reviewedBy = "reviewedBy"
    static let assignedTo = "assignedTo"
    static let dueDate = "dueDate"
    
    // Tagging
    static let tags = "tags"
}

// MARK: - Marker Custom Props Extensions

extension Marker {
    // MARK: - Typed Accessors for Common Properties
    
    /// Severity level (e.g., "low", "medium", "high", "critical")
    var severity: String? {
        customProps[CustomPropsKeys.severity]?.value as? String
    }
    
    /// Category (e.g., "damage", "inspection", "measurement")
    var category: String? {
        customProps[CustomPropsKeys.category]?.value as? String
    }
    
    /// Status (e.g., "pending", "reviewed", "approved", "rejected")
    var status: String? {
        customProps[CustomPropsKeys.status]?.value as? String
    }
    
    /// Priority as integer (1 = highest)
    var priority: Int? {
        customProps[CustomPropsKeys.priority]?.value as? Int
    }
    
    /// Inspector name
    var inspector: String? {
        customProps[CustomPropsKeys.inspector]?.value as? String
    }
    
    /// Tags array
    var tags: [String]? {
        customProps[CustomPropsKeys.tags]?.value as? [String]
    }
    
    /// Check if marker has been reviewed
    var isReviewed: Bool {
        status == "reviewed"
    }
    
    /// Check if marker requires follow-up
    var requiresFollowUp: Bool {
        customProps[CustomPropsKeys.followUpRequired]?.value as? Bool ?? false
    }
    
    // MARK: - Measurement Accessors
    
    /// Length measurement
    var length: Double? {
        customProps[CustomPropsKeys.length]?.value as? Double
    }
    
    /// Width measurement
    var width: Double? {
        customProps[CustomPropsKeys.width]?.value as? Double
    }
    
    /// Height measurement
    var height: Double? {
        customProps[CustomPropsKeys.height]?.value as? Double
    }
    
    /// Area measurement
    var area: Double? {
        customProps[CustomPropsKeys.area]?.value as? Double
    }
    
    /// Measurement unit (e.g., "meters", "feet", "inches")
    var measurementUnit: String? {
        customProps[CustomPropsKeys.unit]?.value as? String
    }
    
    // MARK: - Filtering Helpers
    
    /// Check if marker has high priority (priority <= 2)
    var isHighPriority: Bool {
        guard let priority = priority else { return false }
        return priority <= 2
    }
    
    /// Check if marker has specific tag
    func hasTag(_ tag: String) -> Bool {
        tags?.contains(tag) ?? false
    }
    
    /// Check if marker matches severity level
    func hasSeverity(_ level: String) -> Bool {
        severity?.lowercased() == level.lowercased()
    }
}

// MARK: - Array Extensions for Filtering

extension Array where Element == Marker {
    /// Get markers with high priority
    func highPriority() -> [Marker] {
        filter { $0.isHighPriority }
    }
    
    /// Get unreviewed markers
    func unreviewed() -> [Marker] {
        filter { !$0.isReviewed }
    }
    
    /// Get markers with specific severity
    func withSeverity(_ level: String) -> [Marker] {
        filter { $0.hasSeverity(level) }
    }
    
    /// Get markers with specific tag
    func withTag(_ tag: String) -> [Marker] {
        filter { $0.hasTag(tag) }
    }
    
    /// Get markers requiring follow-up
    func requiresFollowUp() -> [Marker] {
        filter { $0.requiresFollowUp }
    }
    
    /// Get markers by category
    func inCategory(_ category: String) -> [Marker] {
        filter { $0.category?.lowercased() == category.lowercased() }
    }
}
