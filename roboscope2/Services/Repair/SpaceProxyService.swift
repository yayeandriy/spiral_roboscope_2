//
//  SpaceProxyService.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Calls the Veranda spaces proxy (GET /v1/spaces, GET /v1/spaces/{id}) — a read-only
//  passthrough to Roboscope. Repair never calls the Roboscope API directly (00 §0.3).
//  Spaces are read-only and must be tolerated as possibly stale (§2.5): `space_name_cache`
//  on RepairSession is the display-resilience fallback if this proxy blips.
//

import Foundation
import Combine

final class SpaceProxyService: ObservableObject {
    static let shared = SpaceProxyService()

    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private let http = RepairHTTP.shared

    private init() {}

    /// GET /v1/spaces — envelope response `{spaces:[...], stale?, warning?}`, NOT a bare array.
    func listSpaces() async throws -> RepairSpacesResponse {
        try await http.get("/spaces")
    }

    /// GET /v1/spaces/{id} — may be `Space` or a `{stale, warning}` soft-failure shape.
    /// Returns nil (rather than throwing) on any decode/soft-failure so callers can fall back
    /// to a locally cached display name instead of surfacing a hard error.
    func getSpace(id: String) async -> RepairSpace? {
        do {
            return try await http.get("/spaces/\(id)")
        } catch {
            return nil
        }
    }
}
