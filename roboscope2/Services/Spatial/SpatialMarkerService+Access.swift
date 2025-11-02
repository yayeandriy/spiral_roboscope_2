//
//  SpatialMarkerService+Access.swift
//  roboscope2
//
//  Accessors and simple updates for spatial markers.
//

import Foundation

extension SpatialMarkerService {
    func getMarkerByBackendId(_ backendId: UUID) -> SpatialMarker? {
        return markers.first(where: { $0.backendId == backendId })
    }
    
    func updateMarkerDetails(backendId: UUID, details: MarkerDetails) {
        if let idx = markers.firstIndex(where: { $0.backendId == backendId }) {
            markers[idx].details = details
        }
    }
}
