//
//  Space.swift
//  roboscope2
//
//  Data models for Space management
//

import Foundation

// MARK: - Space Models

/// Core Space model representing a 3D environment
struct Space: Codable, Identifiable, Hashable {
    let id: UUID
    let key: String
    let name: String
    let description: String?
    let modelGlbUrl: String?
    let modelUsdcUrl: String?
    let previewUrl: String?
    let meta: [String: AnyCodable]?
    let createdAt: Date?
    let updatedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id, key, name, description, meta
        case modelGlbUrl = "model_glb_url"
        case modelUsdcUrl = "model_usdc_url"
        case previewUrl = "preview_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
    
    /// Returns the primary model URL, preferring USDC over GLB
    var primaryModelUrl: String? {
        return modelUsdcUrl ?? modelGlbUrl
    }
    
    /// Check if the space has any 3D model
    var hasModel: Bool {
        return modelGlbUrl != nil || modelUsdcUrl != nil
    }
}

// MARK: - Space DTOs

/// DTO for creating a new Space
struct CreateSpace: Codable {
    let key: String
    let name: String
    let description: String?
    let modelGlbUrl: String?
    let modelUsdcUrl: String?
    let previewUrl: String?
    let meta: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case key, name, description, meta
        case modelGlbUrl = "model_glb_url"
        case modelUsdcUrl = "model_usdc_url"
        case previewUrl = "preview_url"
    }
    
    init(
        key: String,
        name: String,
        description: String? = nil,
        modelGlbUrl: String? = nil,
        modelUsdcUrl: String? = nil,
        previewUrl: String? = nil,
        meta: [String: Any]? = nil
    ) {
        self.key = key
        self.name = name
        self.description = description
        self.modelGlbUrl = modelGlbUrl
        self.modelUsdcUrl = modelUsdcUrl
        self.previewUrl = previewUrl
        self.meta = meta?.mapValues { AnyCodable($0) }
    }
}

/// DTO for updating an existing Space
struct UpdateSpace: Codable {
    let key: String?
    let name: String?
    let description: String?
    let modelGlbUrl: String?
    let modelUsdcUrl: String?
    let previewUrl: String?
    let meta: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case key, name, description, meta
        case modelGlbUrl = "model_glb_url"
        case modelUsdcUrl = "model_usdc_url"
        case previewUrl = "preview_url"
    }
    
    init(
        key: String? = nil,
        name: String? = nil,
        description: String? = nil,
        modelGlbUrl: String? = nil,
        modelUsdcUrl: String? = nil,
        previewUrl: String? = nil,
        meta: [String: Any]? = nil
    ) {
        self.key = key
        self.name = name
        self.description = description
        self.modelGlbUrl = modelGlbUrl
        self.modelUsdcUrl = modelUsdcUrl
        self.previewUrl = previewUrl
        self.meta = meta?.mapValues { AnyCodable($0) }
    }
}