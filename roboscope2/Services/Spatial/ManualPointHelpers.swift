//
//  ManualPointHelpers.swift
//  roboscope2
//
//  Shared helpers for Measure-app-style two-point placement:
//  dotted vertical lines, measurement line, distance badge, reticle dot.
//

import RealityKit
import UIKit

enum ManualPointHelpers {

    // MARK: - Dotted vertical line

    /// Creates a dotted vertical line entity made of short cylinder segments.
    /// - Parameters:
    ///   - basePosition: world position at the bottom of the line (where it meets the surface).
    ///   - height: total height of the dotted line in meters (e.g. 0.30 for 30 cm).
    ///   - color: the colour of each segment.
    ///   - segmentLength: height of a single dash segment.
    ///   - gapLength: height of the gap between segments.
    static func makeDottedVerticalLine(
        basePosition: SIMD3<Float>,
        height: Float = 0.30,
        color: UIColor,
        segmentLength: Float = 0.018,
        gapLength: Float = 0.014
    ) -> ModelEntity {
        let root = ModelEntity()
        root.name = "dotted_line"
        let step = segmentLength + gapLength
        let radius: Float = 0.001  // 1 mm thin

        var y: Float = height * 0.5  // centre vertically above base
        while y < height {
            let cyl = ModelEntity(
                mesh: .generateCylinder(height: segmentLength, radius: radius),
                materials: [UnlitMaterial(color: color)]
            )
            cyl.position = SIMD3<Float>(0, y, 0)
            root.addChild(cyl)
            y += step
        }
        // Position root so bottom of first segment sits at basePosition.
        root.position = basePosition
        return root
    }

    // MARK: - Measurement line (solid, between two world points)

    /// Creates a thin solid cylinder connecting `from` to `to`.
    static func makeMeasurementLine(from: SIMD3<Float>, to: SIMD3<Float>) -> ModelEntity {
        let mid = (from + to) / 2
        let dir = to - from
        let len = simd_length(dir)
        guard len > 0.0001 else { return ModelEntity() }

        let line = ModelEntity(
            mesh: .generateCylinder(height: len, radius: 0.001),
            materials: [UnlitMaterial(color: UIColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 1.0))]  // warm yellow
        )
        line.position = mid
        // Orient cylinder (Y-up) along dir
        let up = normalize(dir)
        let yAxis = SIMD3<Float>(0, 1, 0)
        let crossVal = cross(yAxis, up)
        if simd_length(crossVal) > 0.0001 {
            let axis = normalize(crossVal)
            let angle = acos(dot(yAxis, up))
            line.orientation = simd_quatf(angle: angle, axis: axis)
        }
        line.name = "measurement_line"
        return line
    }

    // MARK: - Distance badge

    /// Creates a dark pill-shaped badge plane.
    /// Text is rendered via screen-space SwiftUI overlay (see the view layer).
    static func makeDistanceBadge(distanceMeters: Float) -> ModelEntity {
        let root = ModelEntity()
        root.name = "distance_badge"

        let bg = ModelEntity(
            mesh: .generatePlane(width: 0.10, height: 0.04, cornerRadius: 0.02),
            materials: [UnlitMaterial(color: UIColor(white: 0.15, alpha: 0.92))]
        )
        bg.name = "badge_bg"
        root.addChild(bg)

        return root
    }

    // MARK: - Reticle dot (white dot with ring that tracks surfaces)

    static func makeReticleDot() -> ModelEntity {
        let root = ModelEntity()
        root.name = "reticle_root"

        // Flat ring — sits directly on the surface (y=0)
        let ring = ModelEntity(
            mesh: .generateCylinder(height: 0.0003, radius: 0.018),
            materials: [UnlitMaterial(color: UIColor(white: 0.85, alpha: 0.9))]
        )
        ring.name = "reticle_ring"
        root.addChild(ring)

        // Sphere sits on top of the ring, centered at y = radius
        let sphereRadius: Float = 0.012
        let dot = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [UnlitMaterial(color: .white)]
        )
        dot.name = "reticle_dot"
        dot.position = SIMD3<Float>(0, sphereRadius, 0)
        root.addChild(dot)

        return root
    }

    // MARK: - Point disk (7 cm solid white)

    static func makePointDisk(name: String) -> ModelEntity {
        let disk = ModelEntity(
            mesh: .generateCylinder(height: 0.001, radius: 0.035),  // 7 cm diameter
            materials: [UnlitMaterial(color: .white)]
        )
        disk.name = name
        disk.generateCollisionShapes(recursive: false)
        return disk
    }
}
