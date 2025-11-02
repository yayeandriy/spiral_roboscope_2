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
        print("[SpatialMarkerService] Auto-refreshing marker details for \(markers.count) markers")
        for marker in markers {
            guard let backendId = marker.backendId else { continue }
            do {
                let details = try await markerAPI.getMarkerDetails(for: backendId)
                await MainActor.run {
                    if let index = markers.firstIndex(where: { $0.id == marker.id }) {
                        markers[index].details = details
                        print("[SpatialMarkerService] Updated details for marker \(backendId)")
                    }
                }
            } catch {
                print("[SpatialMarkerService] Failed to refresh details for marker \(backendId): \(error)")
            }
        }
        await MainActor.run { self.objectWillChange.send() }
    }

    /// Refresh or calculate details for a specific marker by backend ID
    func refreshMarkerDetails(backendId: UUID) async {
        print("[MarkerDetails] [Refresh] Starting refresh for marker \(backendId)")
        guard let markerIndex = markers.firstIndex(where: { $0.backendId == backendId }) else {
            print("[MarkerDetails] [Refresh] Marker with backendId \(backendId) not found")
            return
        }
        do {
            let newDetails: MarkerDetails?
            if let details = try await markerAPI.getMarkerDetails(for: backendId) {
                print("[MarkerDetails] [Refresh] Found existing details for marker \(backendId)")
                newDetails = details
            } else {
                print("[MarkerDetails] [Refresh] Details not found for marker \(backendId), calculating…")
                let calculated = try await markerAPI.calculateMarkerDetails(for: backendId)
                print("[MarkerDetails] [Refresh] Calculated details for marker \(backendId): Long=\(calculated.longSize), Cross=\(calculated.crossSize)")
                newDetails = calculated
            }
            await MainActor.run {
                markers[markerIndex].details = newDetails
                self.objectWillChange.send()
            }
        } catch {
            print("[MarkerDetails] [Refresh] Failed to refresh details for marker \(backendId): \(error)")
        }
    }

    /// Update marker details after transform
    func updateDetailsAfterTransform(backendId: UUID) async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refreshMarkerDetails(backendId: backendId)
    }
}
