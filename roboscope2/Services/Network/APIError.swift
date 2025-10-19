//
//  APIError.swift
//  roboscope2
//
//  API error types and handling
//

import Foundation

enum APIError: Error, LocalizedError {
    case badRequest(message: String)
    case unauthorized
    case forbidden
    case notFound
    case conflict(message: String)
    case unprocessableEntity(message: String)
    case serverError(message: String)
    case networkError(Error)
    case decodingError(Error)
    case encodingError(Error)
    case invalidURL
    case unknown(Error)
    
    var errorDescription: String? {
        switch self {
        case .badRequest(let message):
            return "Bad Request: \(message)"
        case .unauthorized:
            return "Unauthorized: Authentication required"
        case .forbidden:
            return "Forbidden: Access denied"
        case .notFound:
            return "Resource not found"
        case .conflict(let message):
            return "Conflict: \(message)"
        case .unprocessableEntity(let message):
            return "Validation Error: \(message)"
        case .serverError(let message):
            return "Server Error: \(message)"
        case .networkError(let error):
            return "Network Error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding Error: \(error.localizedDescription)"
        case .encodingError(let error):
            return "Encoding Error: \(error.localizedDescription)"
        case .invalidURL:
            return "Invalid URL"
        case .unknown(let error):
            return "Unknown Error: \(error.localizedDescription)"
        }
    }
    
    var isRetryable: Bool {
        switch self {
        case .networkError, .serverError:
            return true
        default:
            return false
        }
    }
}

/// Response wrapper for operations that return no data
struct EmptyResponse: Codable {}
