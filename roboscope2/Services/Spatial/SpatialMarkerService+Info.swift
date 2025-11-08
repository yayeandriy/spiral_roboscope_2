//
//  SpatialMarkerService+Info.swift
//  roboscope2
//
//  Marker info and selection-derived metrics.
//

import Foundation
import simd

extension SpatialMarkerService {
    struct MarkerInfo {
        let width: Float
        let length: Float
        let centerX: Float
        let centerZ: Float
        let rawCenterY: Float
        // Raw corner nodes used for UI debug/inspection
        let nodes: [SIMD3<Float>]
        let calibratedCenter: SIMD3<Float>?
        let calibratedWidth: Float?
        let calibratedLength: Float?
        // Identity
        let backendId: UUID?
        let localId: UUID
    }
    
    /// Info for the currently selected marker (width/length and center components)
    var selectedMarkerInfo: MarkerInfo? {
        guard let selectedID = selectedMarkerID,
              let marker = markers.first(where: { $0.id == selectedID }) else {
            return nil
        }
        
        // Use frame-origin coordinates for display (the original server coordinates)
        // If not available, fall back to world coordinates (for locally created markers)
        let nodes = marker.frameOriginNodes ?? marker.nodes
        guard nodes.count >= 2 else { return nil }

        // Compute axis-aligned bounds from node coordinates (raw geometry)
        let xs = nodes.map { $0.x }
        let ys = nodes.map { $0.y }
        let zs = nodes.map { $0.z }

        guard let minX = xs.min(), let maxX = xs.max(),
            let minZ = zs.min(), let maxZ = zs.max(),
            let minY = ys.min(), let maxY = ys.max() else { return nil }

        // Width/Length from axis-aligned extents (user definition)
        let width = maxX - minX
        let length = maxZ - minZ

        // Raw center should be the arithmetic mean of all node coordinates (not AABB midpoint)
        let centerX = xs.reduce(0, +) / Float(xs.count)
        let centerZ = zs.reduce(0, +) / Float(zs.count)
        let centerY = ys.reduce(0, +) / Float(ys.count)
        // Calibrated data from spatial marker (if available)
        let calibrated = marker.calibratedData?.centerPoint
        let calibratedWidth = marker.calibratedData?.width
        let calibratedLength = marker.calibratedData?.length
        return MarkerInfo(width: width,
              length: length,
              centerX: centerX,
              centerZ: centerZ,
              rawCenterY: centerY,
                          nodes: nodes,
                          calibratedCenter: calibrated,
                          calibratedWidth: calibratedWidth,
              calibratedLength: calibratedLength,
              backendId: marker.backendId,
              localId: marker.id)
    }
    
    /// Server-computed details for selected marker
    var selectedMarkerDetails: MarkerDetails? {
        guard let selectedID = selectedMarkerID,
              let marker = markers.first(where: { $0.id == selectedID }) else {
            return nil
        }
        return marker.details
    }
}
