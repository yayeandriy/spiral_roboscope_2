# iOS Swift Integration Guide - Roboscope 2 API

Complete guide for integrating the Roboscope 2 API into an iOS 26 Swift application with AR support.

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Project Setup](#project-setup)
4. [Network Layer](#network-layer)
5. [Data Models](#data-models)
6. [API Client Implementation](#api-client-implementation)
7. [ARKit Integration](#arkit-integration)
8. [Real-time Features](#real-time-features)
9. [Error Handling](#error-handling)
10. [Best Practices](#best-practices)
11. [Sample Code](#sample-code)

---

## Overview

The Roboscope 2 API provides:
- **Spatial environment management** (Spaces)
- **Work session tracking** with optimistic locking
- **AR marker management** with bulk operations
- **Real-time presence tracking** via Redis
- **Distributed locking** for collaborative sessions
- **Audit trail** for all operations

### API Servers

- **Development**: `http://localhost:8080/api/v1`
- **Production**: `https://spiralroboscope2backend-production.up.railway.app/api/v1`

---

## Prerequisites

### Development Environment
- **Xcode 15.0+** (for iOS 17+)
- **Swift 5.9+**
- **iOS 17.0+ deployment target** (iOS 26 features)
- **CocoaPods or Swift Package Manager**

### Required Frameworks
- `Foundation`
- `ARKit` (for AR marker visualization)
- `RealityKit` (for 3D model rendering)
- `Combine` (for reactive programming)
- `SwiftUI` (for modern UI)

### Recommended Dependencies
```swift
// Package.swift dependencies
dependencies: [
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
    .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.0"),
]
```

---

## Project Setup

### 1. Create New iOS Project

```bash
# Using Xcode
File → New → Project → iOS → App
# Select SwiftUI interface and Swift language
```

### 2. Configure Info.plist

Add required permissions:

```xml
<key>NSCameraUsageDescription</key>
<string>We need camera access for AR marker visualization</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>We need location for spatial tracking</string>
<key>NSLocalNetworkUsageDescription</key>
<string>We need network access to sync with Roboscope API</string>
```

### 3. Add Swift Package Dependencies

In Xcode:
1. File → Add Package Dependencies
2. Add Alamofire for networking
3. Add Starscream for WebSocket (presence tracking)

---

## Network Layer

### APIConfiguration.swift

```swift
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

class APIConfiguration {
    static let shared = APIConfiguration()
    
    var environment: APIEnvironment = .production
    var timeout: TimeInterval = 30.0
    
    var baseURL: String {
        environment.baseURL
    }
    
    private init() {}
}
```

### NetworkManager.swift

```swift
import Foundation
import Alamofire

class NetworkManager {
    static let shared = NetworkManager()
    
    private let session: Session
    private let configuration: APIConfiguration
    
    private init() {
        self.configuration = APIConfiguration.shared
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout
        
        self.session = Session(configuration: config)
    }
    
    // MARK: - Generic Request Method
    
    func request<T: Decodable>(
        endpoint: String,
        method: HTTPMethod = .get,
        parameters: Parameters? = nil,
        encoding: ParameterEncoding = URLEncoding.default,
        headers: HTTPHeaders? = nil
    ) async throws -> T {
        let url = "\(configuration.baseURL)\(endpoint)"
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                url,
                method: method,
                parameters: parameters,
                encoding: encoding,
                headers: headers
            )
            .validate()
            .responseDecodable(of: T.self) { response in
                switch response.result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: self.mapError(error, response: response))
                }
            }
        }
    }
    
    // MARK: - JSON Request Method
    
    func requestJSON<T: Decodable, E: Encodable>(
        endpoint: String,
        method: HTTPMethod = .post,
        body: E
    ) async throws -> T {
        let url = "\(configuration.baseURL)\(endpoint)"
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                url,
                method: method,
                parameters: body,
                encoder: JSONParameterEncoder.default,
                headers: ["Content-Type": "application/json"]
            )
            .validate()
            .responseDecodable(of: T.self) { response in
                switch response.result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: self.mapError(error, response: response))
                }
            }
        }
    }
    
    // MARK: - Error Mapping
    
    private func mapError(_ error: AFError, response: AFDataResponse<some Any>) -> APIError {
        if let statusCode = response.response?.statusCode {
            switch statusCode {
            case 400:
                return .badRequest(message: error.localizedDescription)
            case 404:
                return .notFound
            case 409:
                return .conflict(message: "Version conflict - resource was modified")
            case 500...599:
                return .serverError(message: error.localizedDescription)
            default:
                return .unknown(error)
            }
        }
        
        if error.isSessionTaskError {
            return .networkError(error.underlyingError ?? error)
        }
        
        return .unknown(error)
    }
}

// MARK: - API Errors

enum APIError: Error, LocalizedError {
    case badRequest(message: String)
    case notFound
    case conflict(message: String)
    case serverError(message: String)
    case networkError(Error)
    case decodingError(Error)
    case unknown(Error)
    
    var errorDescription: String? {
        switch self {
        case .badRequest(let message):
            return "Bad Request: \(message)"
        case .notFound:
            return "Resource not found"
        case .conflict(let message):
            return "Conflict: \(message)"
        case .serverError(let message):
            return "Server Error: \(message)"
        case .networkError(let error):
            return "Network Error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding Error: \(error.localizedDescription)"
        case .unknown(let error):
            return "Unknown Error: \(error.localizedDescription)"
        }
    }
}
```

---

## Data Models

### Models/Space.swift

```swift
import Foundation

struct Space: Codable, Identifiable, Hashable {
    let id: UUID
    let key: String
    let name: String
    let description: String?
    let modelGlbUrl: String?
    let modelUsdcUrl: String?
    let previewUrl: String?
    let meta: [String: AnyCodable]
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, key, name, description, meta
        case modelGlbUrl = "model_glb_url"
        case modelUsdcUrl = "model_usdc_url"
        case previewUrl = "preview_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CreateSpace: Codable {
    let key: String
    let name: String
    let description: String?
    let modelGlbUrl: String?
    let modelUsdcUrl: String?
    let previewUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case key, name, description
        case modelGlbUrl = "model_glb_url"
        case modelUsdcUrl = "model_usdc_url"
        case previewUrl = "preview_url"
    }
}

struct UpdateSpace: Codable {
    let key: String?
    let name: String?
    let description: String?
    let modelGlbUrl: String?
    let modelUsdcUrl: String?
    let previewUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case key, name, description
        case modelGlbUrl = "model_glb_url"
        case modelUsdcUrl = "model_usdc_url"
        case previewUrl = "preview_url"
    }
}
```

### Models/WorkSession.swift

```swift
import Foundation

enum WorkSessionStatus: String, Codable {
    case draft
    case active
    case done
    case archived
}

enum WorkSessionType: String, Codable {
    case inspection
    case repair
    case other
}

struct WorkSession: Codable, Identifiable, Hashable {
    let id: UUID
    let spaceId: UUID
    let sessionType: WorkSessionType
    let status: WorkSessionStatus
    let startedAt: Date?
    let completedAt: Date?
    let version: Int64
    let meta: [String: AnyCodable]
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, status, version, meta
        case spaceId = "space_id"
        case sessionType = "session_type"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CreateWorkSession: Codable {
    let spaceId: UUID
    let sessionType: WorkSessionType
    let status: WorkSessionStatus?
    let startedAt: Date?
    let completedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case status
        case spaceId = "space_id"
        case sessionType = "session_type"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct UpdateWorkSession: Codable {
    let spaceId: UUID?
    let sessionType: WorkSessionType?
    let status: WorkSessionStatus?
    let startedAt: Date?
    let completedAt: Date?
    let version: Int64? // For optimistic locking
    
    enum CodingKeys: String, CodingKey {
        case status, version
        case spaceId = "space_id"
        case sessionType = "session_type"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}
```

### Models/Marker.swift

```swift
import Foundation
import simd

struct Marker: Codable, Identifiable, Hashable {
    let id: UUID
    let workSessionId: UUID
    let label: String?
    let p1: [Double]
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    let color: String?
    let version: Int64
    let meta: [String: AnyCodable]
    let createdAt: Date
    let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id, label, p1, p2, p3, p4, color, version, meta
        case workSessionId = "work_session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    // Convenience computed properties for ARKit
    var point1: SIMD3<Float> {
        SIMD3<Float>(Float(p1[0]), Float(p1[1]), Float(p1[2]))
    }
    
    var point2: SIMD3<Float> {
        SIMD3<Float>(Float(p2[0]), Float(p2[1]), Float(p2[2]))
    }
    
    var point3: SIMD3<Float> {
        SIMD3<Float>(Float(p3[0]), Float(p3[1]), Float(p3[2]))
    }
    
    var point4: SIMD3<Float> {
        SIMD3<Float>(Float(p4[0]), Float(p4[1]), Float(p4[2]))
    }
    
    var points: [SIMD3<Float>] {
        [point1, point2, point3, point4]
    }
}

struct CreateMarker: Codable {
    let workSessionId: UUID
    let label: String?
    let p1: [Double]
    let p2: [Double]
    let p3: [Double]
    let p4: [Double]
    let color: String?
    
    enum CodingKeys: String, CodingKey {
        case label, p1, p2, p3, p4, color
        case workSessionId = "work_session_id"
    }
    
    init(workSessionId: UUID, label: String?, points: [SIMD3<Float>], color: String?) {
        self.workSessionId = workSessionId
        self.label = label
        self.p1 = [Double(points[0].x), Double(points[0].y), Double(points[0].z)]
        self.p2 = [Double(points[1].x), Double(points[1].y), Double(points[1].z)]
        self.p3 = [Double(points[2].x), Double(points[2].y), Double(points[2].z)]
        self.p4 = [Double(points[3].x), Double(points[3].y), Double(points[3].z)]
        self.color = color
    }
}

struct BulkCreateMarkers: Codable {
    let markers: [CreateMarker]
}

struct UpdateMarker: Codable {
    let workSessionId: UUID?
    let label: String?
    let p1: [Double]?
    let p2: [Double]?
    let p3: [Double]?
    let p4: [Double]?
    let color: String?
    let version: Int64? // For optimistic locking
    
    enum CodingKeys: String, CodingKey {
        case label, p1, p2, p3, p4, color, version
        case workSessionId = "work_session_id"
    }
}
```

### Utilities/AnyCodable.swift

```swift
import Foundation

struct AnyCodable: Codable, Hashable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
    
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        return String(describing: lhs.value) == String(describing: rhs.value)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}
```

---

## API Client Implementation

### Services/SpaceService.swift

```swift
import Foundation

class SpaceService {
    static let shared = SpaceService()
    private let networkManager = NetworkManager.shared
    
    private init() {}
    
    // MARK: - Space Operations
    
    func listSpaces(key: String? = nil) async throws -> [Space] {
        var endpoint = "/spaces"
        if let key = key {
            endpoint += "?key=\(key)"
        }
        return try await networkManager.request(endpoint: endpoint)
    }
    
    func getSpace(id: UUID) async throws -> Space {
        try await networkManager.request(endpoint: "/spaces/\(id.uuidString)")
    }
    
    func createSpace(_ space: CreateSpace) async throws -> Space {
        try await networkManager.requestJSON(
            endpoint: "/spaces",
            method: .post,
            body: space
        )
    }
    
    func updateSpace(id: UUID, update: UpdateSpace) async throws -> Space {
        try await networkManager.requestJSON(
            endpoint: "/spaces/\(id.uuidString)",
            method: .patch,
            body: update
        )
    }
    
    func deleteSpace(id: UUID) async throws {
        let _: EmptyResponse = try await networkManager.request(
            endpoint: "/spaces/\(id.uuidString)",
            method: .delete
        )
    }
}

// Helper for empty responses
struct EmptyResponse: Codable {}
```

### Services/WorkSessionService.swift

```swift
import Foundation

class WorkSessionService {
    static let shared = WorkSessionService()
    private let networkManager = NetworkManager.shared
    
    private init() {}
    
    // MARK: - Work Session Operations
    
    func listWorkSessions(
        spaceId: UUID? = nil,
        status: WorkSessionStatus? = nil,
        sessionType: WorkSessionType? = nil
    ) async throws -> [WorkSession] {
        var queryItems: [String] = []
        
        if let spaceId = spaceId {
            queryItems.append("space_id=\(spaceId.uuidString)")
        }
        if let status = status {
            queryItems.append("status=\(status.rawValue)")
        }
        if let sessionType = sessionType {
            queryItems.append("session_type=\(sessionType.rawValue)")
        }
        
        let endpoint = "/work-sessions" + (queryItems.isEmpty ? "" : "?\(queryItems.joined(separator: "&"))")
        return try await networkManager.request(endpoint: endpoint)
    }
    
    func getWorkSession(id: UUID) async throws -> WorkSession {
        try await networkManager.request(endpoint: "/work-sessions/\(id.uuidString)")
    }
    
    func createWorkSession(_ session: CreateWorkSession) async throws -> WorkSession {
        try await networkManager.requestJSON(
            endpoint: "/work-sessions",
            method: .post,
            body: session
        )
    }
    
    func updateWorkSession(id: UUID, update: UpdateWorkSession) async throws -> WorkSession {
        try await networkManager.requestJSON(
            endpoint: "/work-sessions/\(id.uuidString)",
            method: .patch,
            body: update
        )
    }
    
    func deleteWorkSession(id: UUID) async throws {
        let _: EmptyResponse = try await networkManager.request(
            endpoint: "/work-sessions/\(id.uuidString)",
            method: .delete
        )
    }
}
```

### Services/MarkerService.swift

```swift
import Foundation

class MarkerService {
    static let shared = MarkerService()
    private let networkManager = NetworkManager.shared
    
    private init() {}
    
    // MARK: - Marker Operations
    
    func listMarkers(workSessionId: UUID? = nil) async throws -> [Marker] {
        var endpoint = "/markers"
        if let workSessionId = workSessionId {
            endpoint += "?work_session_id=\(workSessionId.uuidString)"
        }
        return try await networkManager.request(endpoint: endpoint)
    }
    
    func getMarker(id: UUID) async throws -> Marker {
        try await networkManager.request(endpoint: "/markers/\(id.uuidString)")
    }
    
    func createMarker(_ marker: CreateMarker) async throws -> Marker {
        try await networkManager.requestJSON(
            endpoint: "/markers",
            method: .post,
            body: marker
        )
    }
    
    func bulkCreateMarkers(_ markers: [CreateMarker]) async throws -> [Marker] {
        let bulk = BulkCreateMarkers(markers: markers)
        return try await networkManager.requestJSON(
            endpoint: "/markers/bulk",
            method: .post,
            body: bulk
        )
    }
    
    func updateMarker(id: UUID, update: UpdateMarker) async throws -> Marker {
        try await networkManager.requestJSON(
            endpoint: "/markers/\(id.uuidString)",
            method: .patch,
            body: update
        )
    }
    
    func deleteMarker(id: UUID) async throws {
        let _: EmptyResponse = try await networkManager.request(
            endpoint: "/markers/\(id.uuidString)",
            method: .delete
        )
    }
}
```

---

## Next Steps

Continue reading:
- [ARKit Integration Guide](./IOS_ARKIT_INTEGRATION.md) - AR marker visualization
- [Real-time Features Guide](./IOS_REALTIME_FEATURES.md) - Presence tracking & locking
- [SwiftUI Views Guide](./IOS_SWIFTUI_VIEWS.md) - Pre-built UI components
- [Code Examples](./IOS_CODE_EXAMPLES.md) - Complete working examples

---

## Quick Start Example

```swift
import SwiftUI

@main
struct RoboscopeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var spaces: [Space] = []
    @State private var isLoading = false
    @State private var error: String?
    
    var body: some View {
        NavigationView {
            List(spaces) { space in
                NavigationLink(destination: SpaceDetailView(space: space)) {
                    VStack(alignment: .leading) {
                        Text(space.name)
                            .font(.headline)
                        Text(space.key)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Spaces")
            .task {
                await loadSpaces()
            }
            .refreshable {
                await loadSpaces()
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
    }
    
    func loadSpaces() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            spaces = try await SpaceService.shared.listSpaces()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

