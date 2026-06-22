//
//  ReferenceSetService.swift
//  roboscope2
//

import Foundation
import Combine

/// Service for managing Reference Sets (calibration markers from admin portal)
final class ReferenceSetService: ObservableObject {
    static let shared = ReferenceSetService()

    private let networkManager = NetworkManager.shared

    // MARK: - Published Properties

    @Published var referenceSets: [ReferenceSet] = []
    @Published var isLoading: Bool = false
    @Published var error: String? = nil

    private init() {}

    // MARK: - Reference Set Operations

    /// List all reference sets for a space
    func listReferenceSets(spaceId: String) async throws -> [ReferenceSet] {
        await setLoading(true)
        defer { Task { await setLoading(false) } }

        do {
            let sets: [ReferenceSet] = try await networkManager.get(
                endpoint: "/spaces/\(spaceId)/reference-sets"
            )
            await updateSets(sets)
            await clearError()
            return sets
        } catch {
            await setError(error.localizedDescription)
            throw error
        }
    }

    // MARK: - State Helpers

    @MainActor
    private func setLoading(_ loading: Bool) {
        isLoading = loading
    }

    @MainActor
    private func setError(_ message: String) {
        error = message
    }

    @MainActor
    private func clearError() {
        error = nil
    }

    @MainActor
    private func updateSets(_ sets: [ReferenceSet]) {
        referenceSets = sets
    }
}
