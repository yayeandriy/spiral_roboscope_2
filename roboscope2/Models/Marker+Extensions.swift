//
//  Marker+Extensions.swift
//  roboscope2
//
//  Convenience extensions for Marker: typed accessors, measurements, filtering.
//

import Foundation

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
    
    /// Priority (1 = highest)
    var priority: Int? {
        customProps[CustomPropsKeys.priority]?.value as? Int
    }
    
    /// Inspector name
    var inspector: String? {
        customProps[CustomPropsKeys.inspector]?.value as? String
    }
    
    /// Whether follow-up is required
    var requiresFollowUp: Bool {
        customProps[CustomPropsKeys.followUpRequired]?.value as? Bool ?? false
    }
    
    /// Whether the marker has been reviewed
    var isReviewed: Bool {
        status?.lowercased() == "reviewed" || status?.lowercased() == "approved"
    }
    
    /// Tags associated with the marker
    var tags: [String]? {
        customProps[CustomPropsKeys.tags]?.value as? [String]
    }

    // MARK: - Measurement Accessors
    
    /// Length measurement
    var measurementLength: Double? {
        customProps[CustomPropsKeys.length]?.value as? Double
    }
    
    /// Width measurement
    var measurementWidth: Double? {
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

// MARK: - Array Extensions

extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
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
