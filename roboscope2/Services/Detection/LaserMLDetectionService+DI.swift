//
//  LaserMLDetectionService+DI.swift
//  roboscope2
//
//  Dependency injection hook for LaserMLDetectionService.
//  Allows tests and previews to substitute a mock or pre-configured instance.
//

import Foundation

extension LaserMLDetectionService {
    /// Override in tests to provide a custom instance.
    static var provider: () -> LaserMLDetectionService = { LaserMLDetectionService() }

    /// Convenience: creates a fresh instance via the current provider.
    static func make() -> LaserMLDetectionService { provider() }
}
