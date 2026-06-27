//
//  AnchorService.swift
//  roboscope2
//
//  Manages Anchor persistence for each work session: creates/updates anchors
//  via the API (with upsert semantics on session_id + local_z) and maintains
//  an in-memory cache per session.
//

import Foundation
import Combine
import simd

final class AnchorService: ObservableObject {
    static let shared = AnchorService()

    private let networkManager = NetworkManager.shared

    // MARK: - Published Properties

    /// All anchors for the currently active session.
    @Published var anchors: [Anchor] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    private init() {}

    // MARK: - CRUD

    /// Fetch all anchors for a given session and cache them locally.
    @discardableResult
    func listAnchors(sessionId: UUID) async throws -> [Anchor] {
        await setLoading(true)
        defer { Task { await setLoading(false) } }

        do {
            let queryItems = [URLQueryItem(name: "session_id", value: sessionId.uuidString)]
            let fetched: [Anchor] = try await networkManager.get(
                endpoint: "/anchors",
                queryItems: queryItems
            )
            await updateAnchors(fetched)
            await clearError()
            return fetched
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }

    func getAnchor(id: UUID) async throws -> Anchor {
        await setLoading(true)
        defer { Task { await setLoading(false) } }

        do {
            let anchor: Anchor = try await networkManager.get(endpoint: "/anchors/\(id.uuidString)")
            await clearError()
            return anchor
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }

    /// Creates (or upserts) an anchor for the given session run at `localZ` with
    /// the provided world-space position. If an anchor already exists for this
    /// session + run + localZ triple, the server will overwrite its world_position.
    ///
    /// - Parameters:
    ///   - sessionId: The work session this anchor belongs to.
    ///   - run:       AR session run index (1-based); anchors in the same run share a world frame.
    ///   - localZ:    Canonical Z value of the laser guide table row (discrete).
    ///   - position:  World-space ARKit position where the origin was placed.
    /// - Returns: The created or updated anchor.
    @discardableResult
    func placeAnchor(
        sessionId: UUID,
        run: Int,
        localZ: Double,
        position: SIMD3<Float>
    ) async throws -> Anchor {
        await setLoading(true)
        defer { Task { await setLoading(false) } }

        do {
            let dto = CreateAnchor(sessionId: sessionId, run: run, localZ: localZ, worldPosition: position)
            let anchor: Anchor = try await networkManager.post(endpoint: "/anchors", body: dto)
            await upsertAnchor(anchor)
            await clearError()
            return anchor
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func updateAnchorPosition(id: UUID, position: SIMD3<Float>) async throws -> Anchor {
        await setLoading(true)
        defer { Task { await setLoading(false) } }

        do {
            let dto = UpdateAnchor(worldPosition: position)
            let anchor: Anchor = try await networkManager.patch(
                endpoint: "/anchors/\(id.uuidString)",
                body: dto
            )
            await upsertAnchor(anchor)
            await clearError()
            return anchor
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }

    func deleteAnchor(id: UUID) async throws {
        await setLoading(true)
        defer { Task { await setLoading(false) } }

        do {
            try await networkManager.delete(endpoint: "/anchors/\(id.uuidString)")
            await removeAnchor(id: id)
            await clearError()
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Convenience

    /// Returns the cached anchor for a given local_z value (if already fetched).
    func anchor(forLocalZ localZ: Double) -> Anchor? {
        anchors.first { abs($0.localZ - localZ) < 1e-9 }
    }

    /// Clears the in-memory cache (e.g. when changing the active session).
    func clearCache() {
        Task { await updateAnchors([]) }
    }

    // MARK: - State Management (MainActor)

    @MainActor
    private func setLoading(_ loading: Bool) { isLoading = loading }

    @MainActor
    private func setError(_ msg: String) { error = msg }

    @MainActor
    private func clearError() { error = nil }

    @MainActor
    private func updateAnchors(_ newAnchors: [Anchor]) { anchors = newAnchors }

    /// Inserts or replaces an anchor in the cache (matching on id).
    @MainActor
    private func upsertAnchor(_ anchor: Anchor) {
        if let idx = anchors.firstIndex(where: { $0.id == anchor.id }) {
            anchors[idx] = anchor
        } else {
            anchors.append(anchor)
        }
        anchors.sort { $0.localZ < $1.localZ }
    }

    @MainActor
    private func removeAnchor(id: UUID) {
        anchors.removeAll { $0.id == id }
    }
}
