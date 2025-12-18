//
//  LaserGuideService.swift
//  roboscope2
//
//  API service for fetching Laser Guide by Space
//

import Foundation

final class LaserGuideService {
    static let shared = LaserGuideService()

    private let networkManager = NetworkManager.shared

    private init() {}

    /// Fetch Laser Guide for a space.
    /// - Returns: `nil` if the guide does not exist (404).
    func fetchLaserGuide(spaceId: UUID) async throws -> LaserGuide? {
        do {
            let guide: LaserGuide = try await networkManager.get(endpoint: "/spaces/\(spaceId.uuidString)/laser-guide")
            return guide
        } catch let apiError as APIError {
            if case .notFound = apiError {
                return nil
            }
            throw apiError
        }
    }
}
