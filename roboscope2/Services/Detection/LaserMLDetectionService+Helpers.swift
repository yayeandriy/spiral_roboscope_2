//
//  LaserMLDetectionService+Helpers.swift
//  roboscope2
//
//  Shared detection helpers used by both AR and Video Mode views.
//

import Foundation
import CoreGraphics

extension LaserMLDetectionService {

    /// Removes line detections that overlap any dot detection.
    /// Used to prevent the laser line's reflection from being misclassified as a line
    /// when it overlaps the dot on the target.
    static func filterLineOverDot(
        _ detections: [LaserMLDetection],
        enabled: Bool
    ) -> [LaserMLDetection] {
        guard enabled else { return detections }
        let dots = detections.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
        guard !dots.isEmpty else { return detections }
        return detections.filter { det in
            let isLine = det.classIndex == 1 || det.label.lowercased().contains("line")
            guard isLine else { return true }
            return !dots.contains { dot in det.boundingBox.intersects(dot.boundingBox) }
        }
    }
}
