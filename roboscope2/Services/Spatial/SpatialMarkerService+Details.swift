//
//  SpatialMarkerService+Details.swift
//  roboscope2
//
//  Marker details fetching and calculation orchestration.
//

import Foundation
import Combine

extension SpatialMarkerService {
    /// Automatically refresh marker details for all markers
    func autoRefreshMarkerDetails(for sessionId: UUID) async {
        guard !markers.isEmpty else { return }
        for marker in markers {
            guard let backendId = marker.backendId else { continue }
            do {
                let details = try await markerAPI.getMarkerDetails(for: backendId)
                await MainActor.run {
                    if let index = markers.firstIndex(where: { $0.id == marker.id }) {
                        markers[index].details = details
                    }
                }
            } catch {
            }
        }
        await MainActor.run { self.objectWillChange.send() }
    }

    /// Refresh or calculate details for a specific marker by backend ID
    func refreshMarkerDetails(backendId: UUID) async {
        guard let markerIndex = markers.firstIndex(where: { $0.backendId == backendId }) else {
            return
        }
        do {
            let newDetails: MarkerDetails?
            if let details = try await markerAPI.getMarkerDetails(for: backendId) {
                newDetails = details
            } else {
                let calculated = try await markerAPI.calculateMarkerDetails(for: backendId)
                newDetails = calculated
            }
            await MainActor.run {
                markers[markerIndex].details = newDetails
                self.objectWillChange.send()
            }
        } catch {
        }
    }

    /// Update marker details after transform
    func updateDetailsAfterTransform(backendId: UUID) async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshMarkerDetails(backendId: backendId)
    }
}
