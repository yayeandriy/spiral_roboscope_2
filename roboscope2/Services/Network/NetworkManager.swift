//
//  NetworkManager.swift
//  roboscope2
//
//  Core network layer using async/await
//

import Foundation

final class NetworkManager {
    static let shared = NetworkManager()
    
    private let session: URLSession
    private let configuration: APIConfiguration
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    
    private init() {
        self.configuration = APIConfiguration.shared
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout
        
        self.session = URLSession(configuration: config)
        
        // Configure JSON decoder for API date format
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        // Note: NOT using convertFromSnakeCase to maintain explicit CodingKeys control
        
        // Configure JSON encoder
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        // Note: NOT using convertToSnakeCase to maintain explicit CodingKeys control
    }
    
    // MARK: - Generic Request Methods
    
    /// Generic GET request
    func get<T: Decodable>(
        endpoint: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let request = try buildRequest(
            endpoint: endpoint,
            method: "GET",
            queryItems: queryItems
        )
        
        return try await performRequest(request)
    }
    
    /// Generic POST request with body
    func post<T: Decodable, E: Encodable>(
        endpoint: String,
        body: E
    ) async throws -> T {
        let request = try buildRequest(
            endpoint: endpoint,
            method: "POST",
            body: body
        )
        
        return try await performRequest(request)
    }
    
    /// Generic PATCH request with body
    func patch<T: Decodable, E: Encodable>(
        endpoint: String,
        body: E
    ) async throws -> T {
        let request = try buildRequest(
            endpoint: endpoint,
            method: "PATCH",
            body: body
        )
        
        return try await performRequest(request)
    }
    
    /// Generic DELETE request
    func delete<T: Decodable>(
        endpoint: String
    ) async throws -> T {
        let request = try buildRequest(
            endpoint: endpoint,
            method: "DELETE"
        )
        
        return try await performRequest(request)
    }
    
    /// POST request without response body
    func post<E: Encodable>(
        endpoint: String,
        body: E
    ) async throws {
        let _: EmptyResponse = try await post(endpoint: endpoint, body: body)
    }
    
    /// PATCH request without response body
    func patch<E: Encodable>(
        endpoint: String,
        body: E
    ) async throws {
        let _: EmptyResponse = try await patch(endpoint: endpoint, body: body)
    }
    
    /// DELETE request without response body
    func delete(endpoint: String) async throws {
        let _: EmptyResponse = try await delete(endpoint: endpoint)
    }
    
    // MARK: - Request Building
    
    private func buildRequest<E: Encodable>(
        endpoint: String,
        method: String,
        queryItems: [URLQueryItem]? = nil,
        body: E? = nil
    ) throws -> URLRequest {
        guard var urlComponents = URLComponents(string: "\(configuration.baseURL)\(endpoint)") else {
            throw APIError.invalidURL
        }
        
        if let queryItems = queryItems {
            urlComponents.queryItems = queryItems
        }
        
        guard let url = urlComponents.url else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        if let body = body {
            do {
                request.httpBody = try encoder.encode(body)
                
                // Log request body for debugging
                if configuration.enableLogging, let httpBody = request.httpBody,
                   let bodyString = String(data: httpBody, encoding: .utf8) {
                    print("📤 Request body: \(bodyString)")
                }
            } catch {
                throw APIError.encodingError(error)
            }
        }
        
        return request
    }
    
    private func buildRequest(
        endpoint: String,
        method: String,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        return try buildRequest(endpoint: endpoint, method: method, queryItems: queryItems, body: EmptyResponse?.none)
    }
    
    // MARK: - Request Execution
    
    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        if configuration.enableLogging {
            logRequest(request)
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(NSError(domain: "Invalid response", code: -1))
        }
        
        if configuration.enableLogging {
            logResponse(httpResponse, data: data)
        }
        
        try validateResponse(httpResponse, data: data)
        
        // Handle empty responses
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            if configuration.enableLogging {
                print("❌ Decoding error for \(T.self):")
                print("   Error: \(error)")
                if let decodingError = error as? DecodingError {
                    switch decodingError {
                    case .keyNotFound(let key, let context):
                        print("   Missing key: \(key.stringValue) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                    case .typeMismatch(let type, let context):
                        print("   Type mismatch for type \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                        print("   Expected \(type) but found: \(context.debugDescription)")
                    case .valueNotFound(let type, let context):
                        print("   Value not found for type \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
                    case .dataCorrupted(let context):
                        print("   Data corrupted at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)")
                    @unknown default:
                        print("   Unknown decoding error")
                    }
                }
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("   JSON: \(jsonString)")
                }
            }
            throw APIError.decodingError(error)
        }
    }
    
    // MARK: - Response Validation
    
    private func validateResponse(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 400:
            let message = String(data: data, encoding: .utf8) ?? "Bad request"
            throw APIError.badRequest(message: message)
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 409:
            let message = String(data: data, encoding: .utf8) ?? "Version conflict"
            throw APIError.conflict(message: message)
        case 422:
            let message = String(data: data, encoding: .utf8) ?? "Validation failed"
            throw APIError.unprocessableEntity(message: message)
        case 500...599:
            let message = String(data: data, encoding: .utf8) ?? "Server error"
            throw APIError.serverError(message: message)
        default:
            throw APIError.unknown(NSError(domain: "HTTP Error \(response.statusCode)", code: response.statusCode))
        }
    }
    
    // MARK: - Logging
    
    private func logRequest(_ request: URLRequest) {
        print("📤 \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            print("   Body: \(bodyString)")
        }
    }
    
    private func logResponse(_ response: HTTPURLResponse, data: Data) {
        let emoji = (200...299).contains(response.statusCode) ? "✅" : "❌"
        print("\(emoji) \(response.statusCode) \(response.url?.absoluteString ?? "")")
        if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
            print("   Response: \(bodyString.prefix(200))")
        }
    }
}
