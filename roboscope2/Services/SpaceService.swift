//
//  SpaceService.swift
//  roboscope2
//
//  API service for Space management
//

import Foundation
import Combine

/// Service for managing Spaces (3D environments)
final class SpaceService: ObservableObject {
    static let shared = SpaceService()
    
    private let networkManager = NetworkManager.shared
    
    // MARK: - Published Properties
    
    @Published var spaces: [Space] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    
    private init() {}
    
    // MARK: - Space Operations
    
    /// List all spaces, optionally filtered by key
    /// - Parameter key: Optional key filter
    /// - Returns: Array of spaces
    func listSpaces(key: String? = nil) async throws -> [Space] {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            var queryItems: [URLQueryItem] = []
            if let key = key {
                queryItems.append(URLQueryItem(name: "key", value: key))
            }
            
            let spaces: [Space] = try await networkManager.get(
                endpoint: "/spaces",
                queryItems: queryItems.isEmpty ? nil : queryItems
            )
            
            await updateSpaces(spaces)
            await clearError()
            return spaces
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Get a specific space by ID
    /// - Parameter id: Space UUID
    /// - Returns: The requested space
    func getSpace(id: UUID) async throws -> Space {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let space: Space = try await networkManager.get(endpoint: "/spaces/\(id.uuidString)")
            await clearError()
            return space
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Create a new space
    /// - Parameter space: CreateSpace DTO with space details
    /// - Returns: The created space
    func createSpace(_ space: CreateSpace) async throws -> Space {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let createdSpace: Space = try await networkManager.post(
                endpoint: "/spaces",
                body: space
            )
            
            await addSpace(createdSpace)
            await clearError()
            return createdSpace
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Update an existing space
    /// - Parameters:
    ///   - id: Space UUID to update
    ///   - update: UpdateSpace DTO with changes
    /// - Returns: The updated space
    func updateSpace(id: UUID, update: UpdateSpace) async throws -> Space {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            let updatedSpace: Space = try await networkManager.patch(
                endpoint: "/spaces/\(id.uuidString)",
                body: update
            )
            
            await replaceSpace(updatedSpace)
            await clearError()
            return updatedSpace
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    /// Delete a space
    /// - Parameter id: Space UUID to delete
    func deleteSpace(id: UUID) async throws {
        await setLoading(true)
        defer { Task { await setLoading(false) } }
        
        do {
            try await networkManager.delete(endpoint: "/spaces/\(id.uuidString)")
            await removeSpace(id: id)
            await clearError()
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Create a space with just key and name
    func createSpace(
        key: String,
        name: String,
        description: String? = nil
    ) async throws -> Space {
        let createRequest = CreateSpace(
            key: key,
            name: name,
            description: description
        )
        return try await createSpace(createRequest)
    }
    
    /// Update space name and description
    func updateSpaceBasics(
        id: UUID,
        name: String? = nil,
        description: String? = nil
    ) async throws -> Space {
        let updateRequest = UpdateSpace(
            name: name,
            description: description
        )
        return try await updateSpace(id: id, update: updateRequest)
    }
    
    /// Add 3D model URLs to a space
    func updateSpaceModels(
        id: UUID,
        glbUrl: String? = nil,
        usdcUrl: String? = nil,
        previewUrl: String? = nil
    ) async throws -> Space {
        let updateRequest = UpdateSpace(
            modelGlbUrl: glbUrl,
            modelUsdcUrl: usdcUrl,
            previewUrl: previewUrl
        )
        return try await updateSpace(id: id, update: updateRequest)
    }
    
    /// Search spaces by name or key
    func searchSpaces(query: String) async throws -> [Space] {
        let allSpaces = try await listSpaces()
        return allSpaces.filter { space in
            space.name.localizedCaseInsensitiveContains(query) ||
            space.key.localizedCaseInsensitiveContains(query) ||
            (space.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
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
    private func updateSpaces(_ newSpaces: [Space]) {
        spaces = newSpaces
    }
    
    @MainActor
    private func addSpace(_ space: Space) {
        if !spaces.contains(where: { $0.id == space.id }) {
            spaces.append(space)
        }
    }
    
    @MainActor
    private func replaceSpace(_ space: Space) {
        if let index = spaces.firstIndex(where: { $0.id == space.id }) {
            spaces[index] = space
        } else {
            spaces.append(space)
        }
    }
    
    @MainActor
    private func removeSpace(id: UUID) {
        spaces.removeAll { $0.id == id }
    }
}