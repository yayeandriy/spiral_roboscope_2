//
//  RepairSessionService.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  API service for RepairSession lifecycle. Mirrors the shape of the existing
//  WorkSessionService/MarkerService pattern, but talks to the Veranda API via RepairHTTP.
//

import Foundation
import Combine

final class RepairSessionService: ObservableObject {
    static let shared = RepairSessionService()

    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private let http = RepairHTTP.shared

    private init() {}

    /// POST /v1/repair-sessions — created with status "active".
    func create(
        spaceId: String,
        spaceNameCache: String?,
        coremlModelId: UUID,
        deviceLabel: String? = nil
    ) async throws -> RepairSession {
        let body = CreateRepairSession(
            spaceId: spaceId,
            spaceNameCache: spaceNameCache,
            coremlModelId: coremlModelId,
            deviceLabel: deviceLabel
        )
        return try await http.post("/repair-sessions", body: body)
    }

    /// GET /v1/repair-sessions (bare array; may include pin_count per 02-contracts.md §2.4).
    func list() async throws -> [RepairSession] {
        try await http.get("/repair-sessions")
    }

    /// GET /v1/repair-sessions/{id}
    func get(id: UUID) async throws -> RepairSession {
        try await http.get("/repair-sessions/\(id.uuidString)")
    }

    /// POST /v1/repair-sessions/{id}/close — idempotent (200 if already closed).
    func close(id: UUID) async throws -> RepairSession {
        try await http.post("/repair-sessions/\(id.uuidString)/close")
    }

    /// DELETE /v1/repair-sessions/{id} — cascades pins server-side.
    func delete(id: UUID) async throws {
        try await http.delete("/repair-sessions/\(id.uuidString)")
    }
}
