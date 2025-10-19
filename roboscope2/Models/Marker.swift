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

/// Core Marker model representing a 3D annotation in space with 4 corner points
struct Marker: Codable, Identifiable, Hashable {
    let id: UUID
    let workSessionId: UUID
    let label: String?
    let p1: [Double]
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    let color: String?
    let version: Int64
    let meta: [String: AnyCodable]
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, label, p1, p2, p3, p4, color, version, meta
        case workSessionId = "work_session_id"
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
    
    enum CodingKeys: String, CodingKey {
        case label, p1, p2, p3, p4, color, meta
        case workSessionId = "work_session_id"
    }
    
    /// Initialize with SIMD3<Float> points (for ARKit integration)
    init(
        workSessionId: UUID,
        label: String? = nil,
        points: [SIMD3<Float>],
        color: String? = nil,
        meta: [String: Any]? = nil
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
        meta: [String: Any]? = nil
    ) {
        self.workSessionId = workSessionId
        self.label = label
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
        self.p4 = p4
        self.color = color ?? Marker.defaultColor
        self.meta = meta?.mapValues { AnyCodable($0) }
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
    
    enum CodingKeys: String, CodingKey {
        case label, p1, p2, p3, p4, color, version, meta
        case workSessionId = "work_session_id"
    }
    
    /// Initialize with SIMD3<Float> points (for ARKit integration)
    init(
        workSessionId: UUID? = nil,
        label: String? = nil,
        points: [SIMD3<Float>]? = nil,
        color: String? = nil,
        version: Int64? = nil,
        meta: [String: Any]? = nil
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