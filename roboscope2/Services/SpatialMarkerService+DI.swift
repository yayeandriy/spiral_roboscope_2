//
//  SpatialMarkerService+DI.swift
//  roboscope2
//
//  Dependency injection hooks for SpatialMarkerService.
//

import Foundation

extension SpatialMarkerService {
    static var markerAPIProvider: MarkerAPI = MarkerService.shared
    var markerAPI: MarkerAPI { Self.markerAPIProvider }
}
