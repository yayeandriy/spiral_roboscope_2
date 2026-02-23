//
//  LaserMLDetectionService+CoordinateMapping.swift
//  roboscope2
//
//  Normalized coordinate transforms between oriented-image space and raw pixel-buffer space.
//  These are called from +Decode.swift and +Segmentation.swift as well as the overlay.
//

import Foundation
import CoreGraphics
import ImageIO

extension LaserMLDetectionService {

    /// Map a single normalized point from oriented/model space back to raw pixel-buffer
    /// normalized space (origin top-left). `orientation` is what was passed to VNImageRequestHandler.
    static func mapNormalizedPointFromOrientedToRaw(
        _ p: CGPoint,
        orientation: CGImagePropertyOrientation
    ) -> CGPoint {
        switch orientation {
        case .up:
            return p
        case .down:
            return CGPoint(x: 1.0 - p.x, y: 1.0 - p.y)
        case .left:
            // Inverse of CCW rotation: (x,y) -> (1 - y, x)
            return CGPoint(x: 1.0 - p.y, y: p.x)
        case .right:
            // Inverse of CW rotation: (x,y) -> (y, 1 - x)
            return CGPoint(x: p.y, y: 1.0 - p.x)
        case .upMirrored:
            return CGPoint(x: 1.0 - p.x, y: p.y)
        case .downMirrored:
            return CGPoint(x: p.x, y: 1.0 - p.y)
        case .leftMirrored:
            let base = CGPoint(x: 1.0 - p.y, y: p.x)
            return CGPoint(x: 1.0 - base.x, y: base.y)
        case .rightMirrored:
            let base = CGPoint(x: p.y, y: 1.0 - p.x)
            return CGPoint(x: 1.0 - base.x, y: base.y)
        @unknown default:
            return p
        }
    }

    /// Map a rect from oriented/model space to raw pixel-buffer normalized space by
    /// transforming all four corners and computing the enclosing axis-aligned rect.
    static func mapNormalizedRectFromOrientedToRaw(
        _ rect: CGRect,
        orientation: CGImagePropertyOrientation
    ) -> CGRect {
        let p1 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.minX, y: rect.minY), orientation: orientation)
        let p2 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.maxX, y: rect.minY), orientation: orientation)
        let p3 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.minX, y: rect.maxY), orientation: orientation)
        let p4 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.maxX, y: rect.maxY), orientation: orientation)

        let xs = [p1.x, p2.x, p3.x, p4.x]
        let ys = [p1.y, p2.y, p3.y, p4.y]

        // Clamp just in case the inverse crop mapping produces slight overshoot.
        let minX = max(0, min(1, xs.min() ?? 0))
        let minY = max(0, min(1, ys.min() ?? 0))
        let maxX = max(0, min(1, xs.max() ?? 0))
        let maxY = max(0, min(1, ys.max() ?? 0))

        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
