//
//  RepairHTTP.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Minimal, self-contained HTTP client for the Repair module. The existing `NetworkManager`
//  is hard-wired to the shared `APIConfiguration.shared` singleton (Roboscope base URL), so
//  rather than edit it (copy-don't-disturb, 00-rules-and-boundaries.md §0.2), Repair gets its
//  own thin client that targets `VerandaAPIConfiguration.baseURL` (05-ios-repair.md §5.5).
//
//  Explicit CodingKeys are used on every DTO; decoder uses .iso8601. Never convertFromSnakeCase.
//

import Foundation

enum RepairAPIError: Error, LocalizedError {
    case invalidURL
    case badRequest(message: String)
    case notFound
    case serverError(message: String)
    case decodingError(Error)
    case encodingError(Error)
    case transport(Error)
    case unknown(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Veranda API URL"
        case .badRequest(let message): return "Bad request: \(message)"
        case .notFound: return "Not found"
        case .serverError(let message): return "Veranda server error: \(message)"
        case .decodingError(let error): return "Decoding error: \(error.localizedDescription)"
        case .encodingError(let error): return "Encoding error: \(error.localizedDescription)"
        case .transport(let error): return "Network error: \(error.localizedDescription)"
        case .unknown(let status): return "Unexpected HTTP status \(status)"
        }
    }
}

/// Empty response placeholder for endpoints that return 204/no body.
struct RepairEmptyResponse: Codable {}

/// Thin URLSession-based HTTP client, scoped to the Repair module only.
final class RepairHTTP {
    static let shared = RepairHTTP()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = VerandaAPIConfiguration.timeout
        config.timeoutIntervalForResource = VerandaAPIConfiguration.timeout
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        // Explicit CodingKeys on every DTO — never convertFromSnakeCase (00 §0.9).

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Generic verbs

    func get<T: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> T {
        let request = try buildRequest(path: path, method: "GET", query: query, body: Optional<Int>.none)
        return try await perform(request)
    }

    func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        let request = try buildRequest(path: path, method: "POST", body: body)
        return try await perform(request)
    }

    /// POST with no request body (e.g. close/set-default style actions).
    func post<T: Decodable>(_ path: String) async throws -> T {
        let request = try buildRequest(path: path, method: "POST", body: Optional<Int>.none)
        return try await perform(request)
    }

    func delete(_ path: String) async throws {
        let request = try buildRequest(path: path, method: "DELETE", body: Optional<Int>.none)
        let _: RepairEmptyResponse = try await perform(request, allowEmptyBody: true)
    }

    // MARK: - Multipart (photo uploads — 02-contracts.md §2.1 pin/session photo endpoints)

    struct MultipartFilePart {
        let name: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    /// POST multipart/form-data with one or more file parts plus optional plain text fields
    /// (e.g. `captured_at`). Used by the pin-photo and session-photo upload endpoints — both
    /// return the created/updated JSON object directly, decoded the same way as any other verb.
    func postMultipart<T: Decodable>(
        _ path: String,
        fileParts: [MultipartFilePart],
        textFields: [String: String] = [:]
    ) async throws -> T {
        let request = try buildMultipartRequest(path: path, method: "POST", fileParts: fileParts, textFields: textFields)
        return try await perform(request)
    }

    private func buildMultipartRequest(
        path: String,
        method: String,
        fileParts: [MultipartFilePart],
        textFields: [String: String]
    ) throws -> URLRequest {
        guard let url = URL(string: "\(VerandaAPIConfiguration.baseURL)\(path)") else {
            throw RepairAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method

        let boundary = "RepairBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let lineBreak = "\r\n"
        var body = Data()

        for (key, value) in textFields {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(value)\(lineBreak)".data(using: .utf8)!)
        }

        for part in fileParts {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(part.filename)\"\(lineBreak)"
                    .data(using: .utf8)!
            )
            body.append("Content-Type: \(part.mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append(part.data)
            body.append(lineBreak.data(using: .utf8)!)
        }

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    // MARK: - Request building

    private func buildRequest<Body: Encodable>(
        path: String,
        method: String,
        query: [URLQueryItem]? = nil,
        body: Body?
    ) throws -> URLRequest {
        guard var components = URLComponents(string: "\(VerandaAPIConfiguration.baseURL)\(path)") else {
            throw RepairAPIError.invalidURL
        }
        if let query, !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw RepairAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw RepairAPIError.encodingError(error)
            }
        }
        return request
    }

    // MARK: - Execution

    private func perform<T: Decodable>(_ request: URLRequest, allowEmptyBody: Bool = false) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RepairAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RepairAPIError.unknown(-1)
        }

        try validate(http, data: data)

        if allowEmptyBody, data.isEmpty {
            if let empty = RepairEmptyResponse() as? T {
                return empty
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RepairAPIError.decodingError(error)
        }
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 400:
            throw RepairAPIError.badRequest(message: String(data: data, encoding: .utf8) ?? "Bad request")
        case 404:
            throw RepairAPIError.notFound
        case 500...599:
            throw RepairAPIError.serverError(message: String(data: data, encoding: .utf8) ?? "Server error")
        default:
            throw RepairAPIError.unknown(response.statusCode)
        }
    }
}
