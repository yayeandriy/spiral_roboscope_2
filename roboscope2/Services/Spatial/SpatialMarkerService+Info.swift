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
    }
    
    /// Info for the currently selected marker (width/length and center components)
    var selectedMarkerInfo: MarkerInfo? {
        guard let selectedID = selectedMarkerID,
              let marker = markers.first(where: { $0.id == selectedID }) else {
            return nil
        }
        let nodes = marker.nodes
        guard nodes.count == 4 else { return nil }
        let center = (nodes[0] + nodes[1] + nodes[2] + nodes[3]) / 4.0
        let edge01 = simd_distance(nodes[0], nodes[1])
        let edge23 = simd_distance(nodes[2], nodes[3])
        let width = (edge01 + edge23) / 2.0
        let edge12 = simd_distance(nodes[1], nodes[2])
        let edge30 = simd_distance(nodes[3], nodes[0])
        let length = (edge12 + edge30) / 2.0
        return MarkerInfo(width: width, length: length, centerX: center.x, centerZ: center.z)
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
