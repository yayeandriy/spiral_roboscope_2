//
//  MarkerService.swift
//  roboscope2
//
//  API service for Marker management
//

import Foundation
import Combine
import simd

/// Service for managing Markers (3D annotations in AR space)
final class MarkerService: ObservableObject {
    static let shared = MarkerService()
    
    private let networkManager = NetworkManager.shared
    
    // MARK: - Published Properties
    
    @Published var markers: [Marker] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    
    private init() {}
    
    // MARK: - Marker Operations
    
    /// List markers, optionally filtered by work session
    /// - Parameter workSessionId: Optional work session filter
    /// - Returns: Array of markers
    func listMarkers(workSessionId: UUID? = nil) async throws -> [Marker] {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            var queryItems: [URLQueryItem] = []
            if let workSessionId = workSessionId {
                queryItems.append(URLQueryItem(name: "work_session_id", value: workSessionId.uuidString))
            }
            
            let markers: [Marker] = try await networkManager.get(
                endpoint: "/markers",
                queryItems: queryItems.isEmpty ? nil : queryItems
            )
            
            await updateMarkers(markers)
            await clearError()
            return markers
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Get a specific marker by ID
    /// - Parameter id: Marker UUID
    /// - Returns: The requested marker
    func getMarker(id: UUID) async throws -> Marker {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let marker: Marker = try await networkManager.get(endpoint: "/markers/\(id.uuidString)")
            await clearError()
            return marker
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Create a new marker
    /// - Parameter marker: CreateMarker DTO
    /// - Returns: The created marker
    func createMarker(_ marker: CreateMarker) async throws -> Marker {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let createdMarker: Marker = try await networkManager.post(
                endpoint: "/markers",
                body: marker
            )
            
            await addMarker(createdMarker)
            await clearError()
            return createdMarker
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Create multiple markers in bulk
    /// - Parameter markers: Array of CreateMarker DTOs
    /// - Returns: Array of created markers
    func bulkCreateMarkers(_ markers: [CreateMarker]) async throws -> [Marker] {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let bulk = BulkCreateMarkers(markers: markers)
            let createdMarkers: [Marker] = try await networkManager.post(
                endpoint: "/markers/bulk",
                body: bulk
            )
            
            await addMarkers(createdMarkers)
            await clearError()
            return createdMarkers
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Update an existing marker
    /// - Parameters:
    ///   - id: Marker UUID
    ///   - update: UpdateMarker DTO
    /// - Returns: The updated marker
    func updateMarker(id: UUID, update: UpdateMarker) async throws -> Marker {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let updatedMarker: Marker = try await networkManager.patch(
                endpoint: "/markers/\(id.uuidString)",
                body: update
            )
            
            await replaceMarker(updatedMarker)
            await clearError()
            return updatedMarker
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Delete a marker
    /// - Parameter id: Marker UUID
    func deleteMarker(id: UUID) async throws {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            try await networkManager.delete(endpoint: "/markers/\(id.uuidString)")
            await removeMarker(id: id)
            await clearError()
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - ARKit Integration Helpers
    
    /// Create a marker from ARKit raycast points
    /// - Parameters:
    ///   - workSessionId: The work session to add the marker to
    ///   - points: 4 corner points from ARKit
    ///   - label: Optional label for the marker
    ///   - color: Optional color (defaults to red)
    /// - Returns: The created marker
    func createMarkerFromARPoints(
        workSessionId: UUID,
        points: [SIMD3<Float>],
        label: String? = nil,
        color: String? = nil
    ) async throws -> Marker {
        guard points.count == 4 else {
            throw APIError.badRequest(message: "Marker must have exactly 4 points")
        }
        
        let markerRequest = CreateMarker(
            workSessionId: workSessionId,
            label: label,
            points: points,
            color: color
        )
        
        return try await createMarker(markerRequest)
    }
    
    /// Update marker position with new ARKit points
    /// - Parameters:
    ///   - id: Marker UUID
    ///   - points: New 4 corner points
    ///   - version: Current marker version for optimistic locking
    /// - Returns: The updated marker
    func updateMarkerPosition(
        id: UUID,
        points: [SIMD3<Float>],
        version: Int64
    ) async throws -> Marker {
        guard points.count == 4 else {
            throw APIError.badRequest(message: "Marker must have exactly 4 points")
        }
        
        let update = UpdateMarker(
            points: points,
            version: version
        )
        
        return try await updateMarker(id: id, update: update)
    }
    
    /// Update marker label and color
    /// - Parameters:
    ///   - id: Marker UUID
    ///   - label: New label
    ///   - color: New color
    ///   - version: Current marker version for optimistic locking
    /// - Returns: The updated marker
    func updateMarkerAppearance(
        id: UUID,
        label: String? = nil,
        color: String? = nil,
        version: Int64
    ) async throws -> Marker {
        let update = UpdateMarker(
            label: label,
            color: color,
            version: version
        )
        
        return try await updateMarker(id: id, update: update)
    }
    
    // MARK: - Convenience Methods
    
    /// Get all markers for a specific work session
    func getMarkersForSession(_ sessionId: UUID) async throws -> [Marker] {
        return try await listMarkers(workSessionId: sessionId)
    }
    
    /// Create a simple marker with just position and label
    func createSimpleMarker(
        workSessionId: UUID,
        position: SIMD3<Float>,
        size: Float = 0.1,
        label: String? = nil,
        color: String? = nil
    ) async throws -> Marker {
        // Create a square marker around the position
        let halfSize = size / 2
        let points = [
            SIMD3<Float>(position.x - halfSize, position.y, position.z - halfSize), // Bottom-left
            SIMD3<Float>(position.x + halfSize, position.y, position.z - halfSize), // Bottom-right
            SIMD3<Float>(position.x + halfSize, position.y, position.z + halfSize), // Top-right
            SIMD3<Float>(position.x - halfSize, position.y, position.z + halfSize)  // Top-left
        ]
        
        return try await createMarkerFromARPoints(
            workSessionId: workSessionId,
            points: points,
            label: label,
            color: color
        )
    }
    
    /// Delete all markers for a work session
    func deleteAllMarkersForSession(_ sessionId: UUID) async throws {
        let markers = try await getMarkersForSession(sessionId)
        
        // Delete markers in parallel for better performance
        try await withThrowingTaskGroup(of: Void.self) { group in
            for marker in markers {
                group.addTask {
                    try await self.deleteMarker(id: marker.id)
                }
            }
            
            // Wait for all deletions to complete
            for try await _ in group {}
        }
    }
    
    /// Get markers by color
    func getMarkersByColor(_ color: String) -> [Marker] {
        return markers.filter { $0.displayColor.lowercased() == color.lowercased() }
    }
    
    /// Get markers with labels
    func getMarkersWithLabels() -> [Marker] {
        return markers.filter { $0.label != nil && !$0.label!.isEmpty }
    }
    
    /// Search markers by label
    func searchMarkers(query: String) -> [Marker] {
        return markers.filter { marker in
            guard let label = marker.label else { return false }
            return label.localizedCaseInsensitiveContains(query)
        }
    }
    
    // MARK: - Statistics
    
    /// Get marker statistics for a work session
    func getMarkerStats(workSessionId: UUID) async throws -> MarkerStats {
        let sessionMarkers = try await getMarkersForSession(workSessionId)
        
        let totalMarkers = sessionMarkers.count
        let labeledMarkers = sessionMarkers.filter { $0.label != nil && !$0.label!.isEmpty }.count
        
        let colorCounts = Dictionary(
            grouping: sessionMarkers,
            by: { $0.displayColor }
        ).mapValues { $0.count }
        
        let averageSize = sessionMarkers.isEmpty ? 0 : sessionMarkers.map { $0.approximateSize }.reduce(0, +) / Float(sessionMarkers.count)
        
        return MarkerStats(
            totalMarkers: totalMarkers,
            labeledMarkers: labeledMarkers,
            colorDistribution: colorCounts,
            averageSize: averageSize
        )
    }
    
    // MARK: - State Management
    
    @MainActor
    private func setLoading(_ loading: Bool) {
        isLoading = loading
    }
    
    @MainActor
    private func setError(_ errorMessage: String) {
        error = errorMessage
    }
    
    @MainActor
    private func clearError() {
        error = nil
    }
    
    @MainActor
    private func updateMarkers(_ newMarkers: [Marker]) {
        markers = newMarkers
    }
    
    @MainActor
    private func addMarker(_ marker: Marker) {
        if !markers.contains(where: { $0.id == marker.id }) {
            markers.append(marker)
        }
    }
    
    @MainActor
    private func addMarkers(_ newMarkers: [Marker]) {
        for marker in newMarkers {
            if !markers.contains(where: { $0.id == marker.id }) {
                markers.append(marker)
            }
        }
    }
    
    @MainActor
    private func replaceMarker(_ marker: Marker) {
        if let index = markers.firstIndex(where: { $0.id == marker.id }) {
            markers[index] = marker
        } else {
            markers.append(marker)
        }
    }
    
    @MainActor
    private func removeMarker(id: UUID) {
        markers.removeAll { $0.id == id }
    }
}

// MARK: - Supporting Types

/// Statistics for markers
struct MarkerStats {
    let totalMarkers: Int
    let labeledMarkers: Int
    let colorDistribution: [String: Int]
    let averageSize: Float
    
    var labeledPercentage: Double {
        guard totalMarkers > 0 else { return 0 }
        return Double(labeledMarkers) / Double(totalMarkers) * 100
    }
    
    var mostUsedColor: String? {
        return colorDistribution.max(by: { $0.value < $1.value })?.key
    }
    
    var averageSizeFormatted: String {
        return String(format: "%.2f m", averageSize)
    }
}