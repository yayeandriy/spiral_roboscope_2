//
//  APIConfiguration.swift
//  roboscope2
//
//  API configuration and environment management
//

import Foundation

enum APIEnvironment {
    case development
    case production
    
    var baseURL: String {
        switch self {
        case .development:
            return "http://localhost:8080/api/v1"
        case .production:
            return "https://spiralroboscope2backend-production.up.railway.app/api/v1"
        }
    }
}

final class APIConfiguration {
    static let shared = APIConfiguration()
    
    var environment: APIEnvironment = .production
    var timeout: TimeInterval = 30.0
    var enableLogging: Bool = true
    
    var baseURL: String {
        environment.baseURL
    }
    
    private init() {}
    
    /// Switch to development environment
    func useDevelopment() {
        environment = .development
    }
    
    /// Switch to production environment
    func useProduction() {
        environment = .production
    }
}
