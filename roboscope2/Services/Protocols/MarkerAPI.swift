//
//  MarkerAPI.swift
//  roboscope2
//
//  Protocol for Marker service to enable dependency injection and testing.
//

import Foundation
import simd

protocol MarkerAPI {
    func getMarkersForSession(_ sessionId: UUID) async throws -> [Marker]
    func updateMarkerPosition(
        id: UUID,
        workSessionId: UUID,
        points: [SIMD3<Float>],
        version: Int64,
        customProps: [String: Any]?
    ) async throws -> Marker
    func getMarkerDetails(for markerId: UUID) async throws -> MarkerDetails?
    func calculateMarkerDetails(for markerId: UUID) async throws -> MarkerDetails
}

extension MarkerService: MarkerAPI {}
