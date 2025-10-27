//
//  CustomPropsExamples.swift
//  roboscope2
//
//  Usage examples for the custom_props feature
//

import Foundation
import simd

// MARK: - Example 1: Creating a Marker with Custom Props

func example1_createMarkerWithCustomProps() {
    let sessionId = UUID()
    
    // Define custom properties for an inspection marker
    let customProps: [String: Any] = [
        CustomPropsKeys.severity: "high",
        CustomPropsKeys.category: "damage",
        CustomPropsKeys.priority: 1,
        CustomPropsKeys.inspector: "John Doe",
        CustomPropsKeys.tags: ["urgent", "structural"],
        "measurements": [
            "width": 15.5,
            "depth": 3.2
        ]
    ]
    
    // Create marker with 4 corner points
    let points: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(1, 1, 0),
        SIMD3<Float>(0, 1, 0)
    ]
    
    let marker = CreateMarker(
        workSessionId: sessionId,
        label: "Critical Structural Issue",
        points: points,
        color: "#FF0000",
        meta: nil,
        customProps: customProps
    )
    
    print("Created marker with custom props")
}

// MARK: - Example 2: Creating a Marker Without Custom Props

func example2_createSimpleMarker() {
    let sessionId = UUID()
    
    let points: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(1, 1, 0),
        SIMD3<Float>(0, 1, 0)
    ]
    
    // Create marker without custom props (will default to {} on backend)
    let marker = CreateMarker(
        workSessionId: sessionId,
        label: "Simple Marker",
        points: points,
        color: nil,
        meta: nil,
        customProps: nil  // Optional - defaults to empty object
    )
    
    print("Created simple marker")
}

// MARK: - Example 3: Updating Custom Props

func example3_updateMarkerCustomProps(markerId: UUID, currentUser: String) {
    let updateRequest = UpdateMarker(
        workSessionId: nil,
        label: nil,
        points: nil,
        color: nil,
        version: nil,
        meta: nil,
        customProps: [
            CustomPropsKeys.status: "reviewed",
            CustomPropsKeys.reviewedAt: ISO8601DateFormatter().string(from: Date()),
            CustomPropsKeys.reviewedBy: currentUser
        ]
    )
    
    print("Updated marker status to reviewed")
}

// MARK: - Example 4: Accessing Custom Props

func example4_accessCustomProps(marker: Marker) {
    // Using convenience properties
    if let severity = marker.severity {
        print("Severity: \(severity)")
    }
    
    if let priority = marker.priority {
        print("Priority: \(priority)")
    }
    
    if let tags = marker.tags {
        print("Tags: \(tags.joined(separator: ", "))")
    }
    
    // Using convenience methods
    if marker.isReviewed {
        print("✓ This marker has been reviewed")
    }
    
    if marker.isHighPriority {
        print("⚠️ High priority marker")
    }
    
    if marker.hasTag("urgent") {
        print("🔴 Urgent marker")
    }
    
    // Direct access to custom props
    if let inspector = marker.customProps[CustomPropsKeys.inspector]?.value as? String {
        print("Inspector: \(inspector)")
    }
}

// MARK: - Example 5: Filtering Markers

func example5_filterMarkers(markers: [Marker]) {
    // Get high priority markers
    let highPriority = markers.highPriority()
    print("High priority markers: \(highPriority.count)")
    
    // Get unreviewed markers
    let unreviewed = markers.unreviewed()
    print("Unreviewed markers: \(unreviewed.count)")
    
    // Get markers with specific severity
    let criticalMarkers = markers.withSeverity("critical")
    print("Critical markers: \(criticalMarkers.count)")
    
    // Get markers with specific tag
    let urgentMarkers = markers.withTag("urgent")
    print("Urgent markers: \(urgentMarkers.count)")
    
    // Get markers requiring follow-up
    let followUpMarkers = markers.requiresFollowUp()
    print("Follow-up required: \(followUpMarkers.count)")
    
    // Get markers by category
    let damageMarkers = markers.inCategory("damage")
    print("Damage markers: \(damageMarkers.count)")
    
    // Complex filtering
    let urgentUnreviewed = markers
        .unreviewed()
        .withTag("urgent")
        .withSeverity("high")
    print("Urgent unreviewed high-severity: \(urgentUnreviewed.count)")
}

// MARK: - Example 6: Inspection Workflow

func example6_inspectionWorkflow() {
    let sessionId = UUID()
    let points: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(1, 1, 0),
        SIMD3<Float>(0, 1, 0)
    ]
    
    let inspectionProps: [String: Any] = [
        CustomPropsKeys.inspector: "Jane Smith",
        CustomPropsKeys.inspectionDate: ISO8601DateFormatter().string(from: Date()),
        CustomPropsKeys.findings: "Requires immediate attention",
        CustomPropsKeys.followUpRequired: true,
        CustomPropsKeys.severity: "high",
        CustomPropsKeys.category: "inspection",
        CustomPropsKeys.status: "pending"
    ]
    
    let marker = CreateMarker(
        workSessionId: sessionId,
        label: "Safety Inspection Point",
        points: points,
        color: "#FFA500",
        customProps: inspectionProps
    )
    
    print("Created inspection marker")
}

// MARK: - Example 7: Damage Assessment

func example7_damageAssessment() {
    let sessionId = UUID()
    let points: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(1, 1, 0),
        SIMD3<Float>(0, 1, 0)
    ]
    
    let damageProps: [String: Any] = [
        CustomPropsKeys.damageType: "structural",
        CustomPropsKeys.severity: "high",
        CustomPropsKeys.estimatedCost: 5000.00,
        CustomPropsKeys.repairPriority: 1,
        CustomPropsKeys.category: "damage",
        CustomPropsKeys.tags: ["urgent", "structural", "load-bearing"],
        CustomPropsKeys.inspector: "Mike Johnson"
    ]
    
    let marker = CreateMarker(
        workSessionId: sessionId,
        label: "Structural Damage",
        points: points,
        color: "#FF0000",
        customProps: damageProps
    )
    
    print("Created damage assessment marker")
}

// MARK: - Example 8: Measurement Data

func example8_measurementData() {
    let sessionId = UUID()
    let points: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(2.5, 0, 0),
        SIMD3<Float>(2.5, 1.8, 0),
        SIMD3<Float>(0, 1.8, 0)
    ]
    
    let measurementProps: [String: Any] = [
        CustomPropsKeys.unit: "meters",
        CustomPropsKeys.length: 2.5,
        CustomPropsKeys.width: 1.8,
        CustomPropsKeys.area: 4.5,
        CustomPropsKeys.measuredBy: "LiDAR",
        CustomPropsKeys.category: "measurement",
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    
    let marker = CreateMarker(
        workSessionId: sessionId,
        label: "Wall Measurement",
        points: points,
        color: "#00FF00",
        customProps: measurementProps
    )
    
    print("Created measurement marker")
}

// MARK: - Example 9: AR Anchor Tracking

func example9_arAnchorTracking(anchorId: UUID, confidence: Float, worldTransform: simd_float4x4) {
    let sessionId = UUID()
    let points: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0),
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(1, 1, 0),
        SIMD3<Float>(0, 1, 0)
    ]
    
    let arProps: [String: Any] = [
        CustomPropsKeys.anchorId: anchorId.uuidString,
        CustomPropsKeys.confidence: confidence,
        CustomPropsKeys.worldPosition: [
            "x": worldTransform.columns.3.x,
            "y": worldTransform.columns.3.y,
            "z": worldTransform.columns.3.z
        ],
        "trackingState": "tracked",
        "timestamp": ISO8601DateFormatter().string(from: Date())
    ]
    
    let marker = CreateMarker(
        workSessionId: sessionId,
        label: "AR Anchor Point",
        points: points,
        color: "#0000FF",
        customProps: arProps
    )
    
    print("Created AR tracking marker")
}

// MARK: - Example 10: Bulk Operations with Different Custom Props

func example10_bulkCreateWithCustomProps() {
    let sessionId = UUID()
    
    // Create multiple markers with different custom props
    let markers = [
        CreateMarker(
            workSessionId: sessionId,
            label: "High Priority Issue",
            points: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0),
                SIMD3<Float>(0, 1, 0)
            ],
            color: "#FF0000",
            customProps: [
                CustomPropsKeys.priority: 1,
                CustomPropsKeys.severity: "high",
                CustomPropsKeys.category: "damage"
            ]
        ),
        CreateMarker(
            workSessionId: sessionId,
            label: "Medium Priority Issue",
            points: [
                SIMD3<Float>(2, 0, 0),
                SIMD3<Float>(3, 0, 0),
                SIMD3<Float>(3, 1, 0),
                SIMD3<Float>(2, 1, 0)
            ],
            color: "#FFA500",
            customProps: [
                CustomPropsKeys.priority: 2,
                CustomPropsKeys.severity: "medium",
                CustomPropsKeys.category: "inspection"
            ]
        ),
        CreateMarker(
            workSessionId: sessionId,
            label: "Low Priority Note",
            points: [
                SIMD3<Float>(4, 0, 0),
                SIMD3<Float>(5, 0, 0),
                SIMD3<Float>(5, 1, 0),
                SIMD3<Float>(4, 1, 0)
            ],
            color: "#00FF00",
            customProps: [
                CustomPropsKeys.priority: 3,
                CustomPropsKeys.severity: "low",
                CustomPropsKeys.category: "note"
            ]
        )
    ]
    
    let bulkRequest = BulkCreateMarkers(markers: markers)
    print("Bulk creating \(markers.count) markers with different custom props")
}

// MARK: - Example 11: Custom Validation

func example11_validateCustomProps(_ props: [String: Any]) -> Bool {
    // Example validation logic
    
    // Check if severity is valid
    if let severity = props[CustomPropsKeys.severity] as? String {
        let validSeverities = ["low", "medium", "high", "critical"]
        guard validSeverities.contains(severity.lowercased()) else {
            print("Invalid severity level")
            return false
        }
    }
    
    // Check if priority is in valid range
    if let priority = props[CustomPropsKeys.priority] as? Int {
        guard priority >= 1 && priority <= 5 else {
            print("Priority must be between 1 and 5")
            return false
        }
    }
    
    // Check if estimated cost is positive
    if let cost = props[CustomPropsKeys.estimatedCost] as? Double {
        guard cost >= 0 else {
            print("Estimated cost cannot be negative")
            return false
        }
    }
    
    return true
}

// MARK: - Example 12: SwiftUI Integration

#if canImport(SwiftUI)
import SwiftUI

struct MarkerDetailViewExample: View {
    let marker: Marker
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(marker.label ?? "Unnamed Marker")
                .font(.headline)
            
            // Display severity with color
            if let severity = marker.severity {
                HStack {
                    Text("Severity:")
                    Text(severity)
                        .foregroundColor(severityColor(severity))
                        .bold()
                }
            }
            
            // Display category
            if let category = marker.category {
                HStack {
                    Text("Category:")
                    Text(category)
                        .foregroundColor(.secondary)
                }
            }
            
            // Display priority
            if let priority = marker.priority {
                HStack {
                    Text("Priority:")
                    Text("\(priority)")
                        .foregroundColor(priority <= 2 ? .red : .orange)
                }
            }
            
            // Display inspector
            if let inspector = marker.inspector {
                HStack {
                    Text("Inspector:")
                    Text(inspector)
                }
            }
            
            // Display tags
            if let tags = marker.tags {
                VStack(alignment: .leading) {
                    Text("Tags:")
                        .font(.caption)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            
            // Display review status
            if marker.isReviewed {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Reviewed")
                }
            }
            
            // Display follow-up requirement
            if marker.requiresFollowUp {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Follow-up Required")
                }
            }
            
            // Display measurements
            if let length = marker.length, let width = marker.width {
                VStack(alignment: .leading) {
                    Text("Measurements:")
                        .font(.caption)
                    Text("Length: \(String(format: "%.2f", length)) \(marker.measurementUnit ?? "m")")
                    Text("Width: \(String(format: "%.2f", width)) \(marker.measurementUnit ?? "m")")
                    if let area = marker.area {
                        Text("Area: \(String(format: "%.2f", area)) \(marker.measurementUnit ?? "m")²")
                    }
                }
            }
        }
        .padding()
    }
    
    func severityColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "critical", "high": return .red
        case "medium": return .orange
        case "low": return .yellow
        default: return .gray
        }
    }
}
#endif
