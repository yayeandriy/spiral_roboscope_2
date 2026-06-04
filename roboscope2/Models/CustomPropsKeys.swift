//
//  CustomPropsKeys.swift
//  roboscope2
//
//  Predefined keys for commonly used custom properties on markers.
//

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
