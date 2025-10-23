//
//  SpiralStorageService.swift
//  roboscope2
//
//  Spiral Storage API integration with multipart upload support
//

import Foundation

// MARK: - Storage Service

/// Service for uploading files to Spiral Storage (Cloudflare R2) with multipart upload support
class SpiralStorageService {
    
    // MARK: - Configuration
    
    private let baseURL = "https://spiralstorage-production.up.railway.app"
    private let chunkSize = 5 * 1024 * 1024 // 5MB chunks for multipart upload
    
    // Singleton instance
    static let shared = SpiralStorageService()
    
    private init() {}
    
    // MARK: - Models
    
    struct CreateUploadResponse: Codable {
        let uploadId: String
        let partUrls: [PartPresignedUrl]
        
        enum CodingKeys: String, CodingKey {
            case uploadId = "upload_id"
            case partUrls = "part_urls"
        }
    }
    
    struct PartPresignedUrl: Codable {
        let partNumber: Int
        let url: String
        
        enum CodingKeys: String, CodingKey {
            case partNumber = "part_number"
            case url
        }
    }
    
    struct CompletedPart: Codable {
        let partNumber: Int
        let etag: String
        
        enum CodingKeys: String, CodingKey {
            case partNumber = "part_number"
            case etag
        }
    }
    
    struct CompleteUploadResponse: Codable {
        let objectUrl: String
        
        enum CodingKeys: String, CodingKey {
            case objectUrl = "object_url"
        }
    }
    
    // MARK: - Upload Progress
    
    typealias ProgressHandler = (Double) -> Void
    
    // MARK: - Main Upload Method
    
    /// Upload a file to Spiral Storage with multipart upload support and progress tracking
    /// - Parameters:
    ///   - fileURL: Local file URL to upload
    ///   - destinationPath: Destination path in R2 storage (e.g., "models/session-123/scan.usdc")
    ///   - progress: Optional progress callback (0.0 to 1.0)
    /// - Returns: Public URL of the uploaded file
    func uploadFile(
        fileURL: URL,
        destinationPath: String,
        progress: ProgressHandler? = nil
    ) async throws -> String {
        
        // Read file data
        let fileData = try Data(contentsOf: fileURL)
        let totalSize = fileData.count
        
        // Calculate number of parts needed
        let numberOfParts = Int(ceil(Double(totalSize) / Double(chunkSize)))
        
        print("[Storage] Uploading file: \(fileURL.lastPathComponent)")
        print("[Storage] Size: \(formatBytes(totalSize)), Parts: \(numberOfParts)")
        
        // Step 1: Create multipart upload
        let createResponse = try await createMultipartUpload(
            key: destinationPath,
            numberOfParts: numberOfParts
        )
        
        do {
            // Step 2: Upload all parts with progress tracking
            let completedParts = try await uploadParts(
                fileData: fileData,
                parts: createResponse.partUrls,
                progress: progress
            )
            
            // Step 3: Complete the upload
            let objectUrl = try await completeMultipartUpload(
                key: destinationPath,
                uploadId: createResponse.uploadId,
                parts: completedParts
            )
            
            print("[Storage] Upload successful: \(objectUrl)")
            return objectUrl
            
        } catch {
            // If upload fails, abort the multipart upload to clean up
            print("[Storage] Upload failed, aborting multipart upload")
            try? await abortMultipartUpload(
                key: destinationPath,
                uploadId: createResponse.uploadId
            )
            throw error
        }
    }
    
    // MARK: - Upload with Retry Logic
    
    /// Upload a file with automatic retry on failure
    /// - Parameters:
    ///   - fileURL: Local file URL to upload
    ///   - destinationPath: Destination path in R2 storage
    ///   - maxRetries: Maximum number of retry attempts (default: 3)
    ///   - progress: Optional progress callback
    /// - Returns: Public URL of the uploaded file
    func uploadFileWithRetry(
        fileURL: URL,
        destinationPath: String,
        maxRetries: Int = 3,
        progress: ProgressHandler? = nil
    ) async throws -> String {
        
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await uploadFile(
                    fileURL: fileURL,
                    destinationPath: destinationPath,
                    progress: progress
                )
            } catch {
                lastError = error
                
                if attempt < maxRetries - 1 {
                    // Exponential backoff: 1s, 2s, 4s
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    print("[Storage] Retry attempt \(attempt + 1) after \(Int(delay / 1_000_000_000))s")
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        
        throw lastError ?? StorageError.uploadFailed
    }
    
    // MARK: - Private Methods
    
    private func createMultipartUpload(
        key: String,
        numberOfParts: Int
    ) async throws -> CreateUploadResponse {
        
        let url = URL(string: "\(baseURL)/r2/multipart/create")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "key": key,
            "content_type": "model/vnd.usd+zip",
            "parts": numberOfParts
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[Storage] Create multipart failed: \(httpResponse.statusCode) - \(errorMessage)")
            throw StorageError.serverError(httpResponse.statusCode, errorMessage)
        }
        
        // Log the raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            print("[Storage] 📥 Create multipart response: \(responseString)")
        }
        
        return try JSONDecoder().decode(CreateUploadResponse.self, from: data)
    }
    
    private func uploadParts(
        fileData: Data,
        parts: [PartPresignedUrl],
        progress: ProgressHandler?
    ) async throws -> [CompletedPart] {
        
        var completedParts: [CompletedPart] = []
        let totalParts = parts.count
        
        for (index, part) in parts.enumerated() {
            // Calculate chunk range
            let startIndex = index * chunkSize
            let endIndex = min(startIndex + chunkSize, fileData.count)
            let chunkData = fileData.subdata(in: startIndex..<endIndex)
            
            print("[Storage] Uploading part \(index + 1)/\(totalParts) (\(formatBytes(chunkData.count)))")
            
            // Upload chunk
            let etag = try await uploadChunk(
                data: chunkData,
                presignedUrl: part.url
            )
            
            completedParts.append(CompletedPart(
                partNumber: part.partNumber,
                etag: etag
            ))
            
            // Report progress
            let currentProgress = Double(index + 1) / Double(totalParts)
            await MainActor.run {
                progress?(currentProgress)
            }
        }
        
        return completedParts
    }
    
    private func uploadChunk(
        data: Data,
        presignedUrl: String
    ) async throws -> String {
        
        guard let url = URL(string: presignedUrl) else {
            throw StorageError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = 300 // 5 minutes for large chunks
        
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.uploadFailed
        }
        
        guard let etag = httpResponse.value(forHTTPHeaderField: "ETag") else {
            throw StorageError.missingETag
        }
        
        // Remove quotes from ETag
        return etag.replacingOccurrences(of: "\"", with: "")
    }
    
    private func completeMultipartUpload(
        key: String,
        uploadId: String,
        parts: [CompletedPart]
    ) async throws -> String {
        
        let url = URL(string: "\(baseURL)/r2/multipart/complete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
        let body: [String: Any] = [
            "key": key,
            "upload_id": uploadId,
            "parts": parts.map { part in
                [
                    "part_number": part.partNumber,
                    "etag": part.etag
                ]
            }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StorageError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[Storage] Complete multipart failed: \(httpResponse.statusCode) - \(errorMessage)")
            throw StorageError.serverError(httpResponse.statusCode, errorMessage)
        }
        
        let completeResponse = try JSONDecoder().decode(
            CompleteUploadResponse.self,
            from: data
        )
        
        return completeResponse.objectUrl
    }
    
    private func abortMultipartUpload(
        key: String,
        uploadId: String
    ) async throws {
        
        let url = URL(string: "\(baseURL)/r2/multipart/abort")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let body: [String: String] = [
            "key": key,
            "upload_id": uploadId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        _ = try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Utilities
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Path Generation Utilities

extension SpiralStorageService {
    
    /// File category for organized storage
    enum FileCategory: Equatable {
        case image
        case video
        case document
        case model3D
        case audio
        case scan
        case other(String)
        
        var folderName: String {
            switch self {
            case .image: return "images"
            case .video: return "videos"
            case .document: return "documents"
            case .model3D: return "models"
            case .audio: return "audio"
            case .scan: return "scans"
            case .other(let name): return name
            }
        }
    }
    
    /// Generate an organized path for file storage
    /// - Parameters:
    ///   - category: File category
    ///   - fileName: Original file name
    ///   - sessionId: Optional session ID for grouping
    ///   - spaceId: Optional space ID for grouping
    /// - Returns: Organized storage path
    static func generatePath(
        for category: FileCategory,
        fileName: String,
        sessionId: UUID? = nil,
        spaceId: UUID? = nil
    ) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let cleanFileName = fileName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        
        var pathComponents: [String] = [category.folderName]
        
        if let spaceId = spaceId {
            pathComponents.append("space-\(spaceId.uuidString)")
        }
        
        if let sessionId = sessionId {
            pathComponents.append("session-\(sessionId.uuidString)")
        }
        
        pathComponents.append("\(timestamp)_\(cleanFileName)")
        
        return pathComponents.joined(separator: "/")
    }
}

// MARK: - File Validation

extension SpiralStorageService {
    
    /// Validation rules for file uploads
    struct ValidationRules {
        let maxFileSize: Int // in bytes
        let allowedExtensions: [String]
        
        static let defaultRules = ValidationRules(
            maxFileSize: 500 * 1024 * 1024, // 500MB
            allowedExtensions: ["jpg", "jpeg", "png", "pdf", "glb", "gltf", "usdz", "usdc", "obj", "mp4", "mov"]
        )
        
        static let scanRules = ValidationRules(
            maxFileSize: 1024 * 1024 * 1024, // 1GB for 3D scans
            allowedExtensions: ["obj", "glb", "gltf", "usdz", "usdc", "ply", "stl"]
        )
    }
    
    /// Validate file before upload
    /// - Parameters:
    ///   - url: File URL to validate
    ///   - rules: Validation rules to apply
    /// - Throws: StorageError if validation fails
    func validateFile(
        at url: URL,
        rules: ValidationRules = .defaultRules
    ) throws {
        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.fileNotFound
        }
        
        // Check file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw StorageError.invalidFile
        }
        
        if fileSize > rules.maxFileSize {
            let maxSizeMB = rules.maxFileSize / (1024 * 1024)
            throw StorageError.fileTooLarge(maxSizeMB: maxSizeMB)
        }
        
        // Check extension
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty else {
            throw StorageError.invalidFileType
        }
        
        guard rules.allowedExtensions.contains(fileExtension) else {
            throw StorageError.invalidFileType
        }
    }
}

// MARK: - Errors

enum StorageError: LocalizedError {
    case invalidURL
    case invalidResponse
    case uploadFailed
    case fileNotFound
    case invalidFile
    case fileTooLarge(maxSizeMB: Int)
    case invalidFileType
    case missingETag
    case serverError(Int, String)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid storage URL"
        case .invalidResponse:
            return "Invalid server response"
        case .uploadFailed:
            return "Upload failed"
        case .fileNotFound:
            return "File not found"
        case .invalidFile:
            return "Invalid file"
        case .fileTooLarge(let maxSizeMB):
            return "File size exceeds maximum of \(maxSizeMB)MB"
        case .invalidFileType:
            return "File type not allowed"
        case .missingETag:
            return "Upload response missing ETag header"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
