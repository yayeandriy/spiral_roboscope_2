//
//  ModelRegistryService.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Read-only from iOS: the phone only lists active models and reads the default. Model
//  writes (create/update/delete/set-default) are "admin only" in the Robovision web UI —
//  open at the API in v0, but iOS never needs to call those routes (00 §0.7.3).
//

import Foundation
import Combine

final class ModelRegistryService: ObservableObject {
    static let shared = ModelRegistryService()

    @Published var isLoading: Bool = false
    @Published var lastError: String? = nil

    private let http = RepairHTTP.shared

    private init() {}

    /// GET /v1/models — active models only (bare array).
    func list() async throws -> [CoremlModel] {
        try await http.get("/models")
    }

    /// GET /v1/models/default — returns nil on 404 (no default set), per 02-contracts.md §2.3.
    func getDefault() async throws -> CoremlModel? {
        do {
            return try await http.get("/models/default")
        } catch RepairAPIError.notFound {
            return nil
        }
    }
}
