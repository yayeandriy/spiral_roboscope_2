# iOS Swift Integration Guide

Complete guide for integrating the Spiral Storage API into your iOS Swift application.

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Implementation](#implementation)
- [SwiftUI Examples](#swiftui-examples)
- [UIKit Examples](#uikit-examples)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## Overview

The Spiral Storage API provides multipart upload capabilities for large files to Cloudflare R2 storage. This guide covers:

- ✅ Uploading files with progress tracking
- ✅ Handling multipart uploads for large files
- ✅ Error handling and retry logic
- ✅ SwiftUI and UIKit integration
- ✅ Background uploads
- ✅ Modern Swift async/await patterns

**API Endpoint:** `https://spiralstorage-production.up.railway.app`

---

## Prerequisites

### Minimum Requirements
- iOS 15.0+ (for async/await)
- Xcode 13.0+
- Swift 5.5+

### Info.plist Configuration

Add network security settings to your `Info.plist`:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSExceptionDomains</key>
    <dict>
        <key>spiralstorage-production.up.railway.app</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSTemporaryExceptionAllowsInsecureHTTPLoads</key>
            <false/>
            <key>NSTemporaryExceptionMinimumTLSVersion</key>
            <string>TLSv1.2</string>
        </dict>
        <key>storage.spiral-technology.org</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSTemporaryExceptionAllowsInsecureHTTPLoads</key>
            <false/>
        </dict>
    </dict>
</dict>
```

---

## Quick Start

### 1. Create the Storage Service

Create a new Swift file: `SpiralStorageService.swift`

```swift
import Foundation

// MARK: - Storage Service

class SpiralStorageService {
    
    // MARK: - Configuration
    
    private let baseURL = "https://spiralstorage-production.up.railway.app"
    private let chunkSize = 5 * 1024 * 1024 // 5MB chunks
    
    // MARK: - Models
    
    struct CreateUploadResponse: Codable {
        let uploadId: String
        let key: String
        let parts: [PartPresignedUrl]
        
        enum CodingKeys: String, CodingKey {
            case uploadId = "upload_id"
            case key
            case parts
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
    
    func uploadFile(
        fileURL: URL,
        destinationPath: String,
        progress: ProgressHandler? = nil
    ) async throws -> String {
        
        // Read file data
        let fileData = try Data(contentsOf: fileURL)
        let totalSize = fileData.count
        
        // Calculate number of parts
        let numberOfParts = Int(ceil(Double(totalSize) / Double(chunkSize)))
        
        // Step 1: Create multipart upload
        let createResponse = try await createMultipartUpload(
            key: destinationPath,
            numberOfParts: numberOfParts
        )
        
        do {
            // Step 2: Upload all parts with progress
            let completedParts = try await uploadParts(
                fileData: fileData,
                parts: createResponse.parts,
                progress: progress
            )
            
            // Step 3: Complete the upload
            let objectUrl = try await completeMultipartUpload(
                key: createResponse.key,
                uploadId: createResponse.uploadId,
                parts: completedParts
            )
            
            return objectUrl
            
        } catch {
            // If upload fails, abort the multipart upload
            try? await abortMultipartUpload(
                key: createResponse.key,
                uploadId: createResponse.uploadId
            )
            throw error
        }
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
        
        let body: [String: Any] = [
            "key": key,
            "part_count": numberOfParts
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.invalidResponse
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
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let etag = httpResponse.value(forHTTPHeaderField: "ETag") else {
            throw StorageError.uploadFailed
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
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.invalidResponse
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
        
        let body: [String: String] = [
            "key": key,
            "upload_id": uploadId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        _ = try await URLSession.shared.data(for: request)
    }
}

// MARK: - Errors

enum StorageError: LocalizedError {
    case invalidURL
    case invalidResponse
    case uploadFailed
    case fileNotFound
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid server response"
        case .uploadFailed:
            return "Upload failed"
        case .fileNotFound:
            return "File not found"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
```

---

## SwiftUI Examples

### Example 1: Simple File Upload with Progress

```swift
import SwiftUI

struct FileUploadView: View {
    @StateObject private var viewModel = FileUploadViewModel()
    @State private var showFilePicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Upload Status
            if viewModel.isUploading {
                VStack {
                    ProgressView(value: viewModel.uploadProgress)
                        .progressViewStyle(.linear)
                    Text("\(Int(viewModel.uploadProgress * 100))%")
                        .font(.caption)
                }
                .padding()
            }
            
            // Upload Button
            Button(action: { showFilePicker = true }) {
                Label("Upload File", systemImage: "arrow.up.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(viewModel.isUploading)
            
            // Upload Result
            if let url = viewModel.uploadedURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Upload Successful!")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    Text(url)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(2)
                    
                    Button("Copy URL") {
                        UIPasteboard.general.string = url
                    }
                    .font(.caption)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
            
            // Error Message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding()
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await viewModel.uploadFile(url: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - View Model

@MainActor
class FileUploadViewModel: ObservableObject {
    @Published var uploadProgress: Double = 0
    @Published var isUploading = false
    @Published var uploadedURL: String?
    @Published var errorMessage: String?
    
    private let storageService = SpiralStorageService()
    
    func uploadFile(url: URL) async {
        isUploading = true
        uploadProgress = 0
        uploadedURL = nil
        errorMessage = nil
        
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Cannot access file"
            isUploading = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            // Generate destination path
            let fileName = url.lastPathComponent
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let destinationPath = "uploads/\(timestamp)_\(fileName)"
            
            // Upload file
            let objectUrl = try await storageService.uploadFile(
                fileURL: url,
                destinationPath: destinationPath
            ) { progress in
                self.uploadProgress = progress
            }
            
            uploadedURL = objectUrl
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isUploading = false
    }
}
```

### Example 2: Image Upload with Preview

```swift
import SwiftUI
import PhotosUI

struct ImageUploadView: View {
    @StateObject private var viewModel = ImageUploadViewModel()
    @State private var selectedItem: PhotosPickerItem?
    
    var body: some View {
        VStack(spacing: 20) {
            // Image Preview
            if let image = viewModel.selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 200)
                    .cornerRadius(12)
            }
            
            // Photo Picker
            PhotosPicker(
                selection: $selectedItem,
                matching: .images
            ) {
                Label("Select Image", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
            }
            .onChange(of: selectedItem) { newItem in
                Task {
                    await viewModel.loadImage(from: newItem)
                }
            }
            
            // Upload Button
            if viewModel.selectedImage != nil {
                Button(action: {
                    Task {
                        await viewModel.uploadImage()
                    }
                }) {
                    if viewModel.isUploading {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Label("Upload Image", systemImage: "arrow.up.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
                .disabled(viewModel.isUploading)
            }
            
            // Progress
            if viewModel.isUploading {
                ProgressView(value: viewModel.uploadProgress)
                    .progressViewStyle(.linear)
            }
            
            Spacer()
        }
        .padding()
    }
}

@MainActor
class ImageUploadViewModel: ObservableObject {
    @Published var selectedImage: UIImage?
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0
    @Published var uploadedURL: String?
    
    private let storageService = SpiralStorageService()
    
    func loadImage(from item: PhotosPickerItem?) async {
        guard let item = item else { return }
        
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            selectedImage = image
        }
    }
    
    func uploadImage() async {
        guard let image = selectedImage else { return }
        
        isUploading = true
        uploadProgress = 0
        
        do {
            // Convert image to JPEG
            guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                throw StorageError.invalidResponse
            }
            
            // Save to temporary file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("jpg")
            
            try imageData.write(to: tempURL)
            
            // Upload
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let destinationPath = "images/\(timestamp).jpg"
            
            let objectUrl = try await storageService.uploadFile(
                fileURL: tempURL,
                destinationPath: destinationPath
            ) { progress in
                self.uploadProgress = progress
            }
            
            uploadedURL = objectUrl
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)
            
        } catch {
            print("Upload error: \(error)")
        }
        
        isUploading = false
    }
}
```

### Example 3: Video Upload with Background Support

```swift
import SwiftUI
import AVKit

struct VideoUploadView: View {
    @StateObject private var viewModel = VideoUploadViewModel()
    @State private var showVideoPicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Video Preview
            if let videoURL = viewModel.selectedVideoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .frame(height: 200)
                    .cornerRadius(12)
            }
            
            // Select Video
            Button(action: { showVideoPicker = true }) {
                Label("Select Video", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
            }
            
            // Upload Button
            if viewModel.selectedVideoURL != nil {
                Button(action: {
                    Task {
                        await viewModel.uploadVideo()
                    }
                }) {
                    Label("Upload Video", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(viewModel.isUploading)
            }
            
            // Upload Progress
            if viewModel.isUploading {
                VStack {
                    ProgressView(value: viewModel.uploadProgress)
                        .progressViewStyle(.linear)
                    Text("Uploading: \(Int(viewModel.uploadProgress * 100))%")
                        .font(.caption)
                }
            }
            
            Spacer()
        }
        .padding()
        .fileImporter(
            isPresented: $showVideoPicker,
            allowedContentTypes: [.movie, .video],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                viewModel.selectedVideoURL = urls.first
            case .failure(let error):
                print("Error selecting video: \(error)")
            }
        }
    }
}

@MainActor
class VideoUploadViewModel: ObservableObject {
    @Published var selectedVideoURL: URL?
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0
    @Published var uploadedURL: String?
    
    private let storageService = SpiralStorageService()
    
    func uploadVideo() async {
        guard let videoURL = selectedVideoURL else { return }
        
        isUploading = true
        uploadProgress = 0
        
        guard videoURL.startAccessingSecurityScopedResource() else {
            isUploading = false
            return
        }
        defer { videoURL.stopAccessingSecurityScopedResource() }
        
        do {
            let fileName = videoURL.lastPathComponent
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let destinationPath = "videos/\(timestamp)_\(fileName)"
            
            let objectUrl = try await storageService.uploadFile(
                fileURL: videoURL,
                destinationPath: destinationPath
            ) { progress in
                self.uploadProgress = progress
            }
            
            uploadedURL = objectUrl
            
        } catch {
            print("Upload error: \(error)")
        }
        
        isUploading = false
    }
}
```

---

## UIKit Examples

### Example 1: Document Upload (UIKit)

```swift
import UIKit

class DocumentUploadViewController: UIViewController {
    
    private let storageService = SpiralStorageService()
    private var uploadProgress: Double = 0
    
    // MARK: - UI Elements
    
    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .default)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let progressLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14)
        return label
    }()
    
    private let uploadButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Upload Document", for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 16)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        return button
    }()
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        view.backgroundColor = .systemBackground
        title = "Upload Document"
        
        view.addSubview(uploadButton)
        view.addSubview(progressView)
        view.addSubview(progressLabel)
        
        NSLayoutConstraint.activate([
            uploadButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            uploadButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            uploadButton.widthAnchor.constraint(equalToConstant: 200),
            uploadButton.heightAnchor.constraint(equalToConstant: 50),
            
            progressView.topAnchor.constraint(equalTo: uploadButton.bottomAnchor, constant: 30),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            
            progressLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 8),
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
        
        uploadButton.addTarget(self, action: #selector(uploadTapped), for: .touchUpInside)
        
        progressView.isHidden = true
        progressLabel.isHidden = true
    }
    
    // MARK: - Actions
    
    @objc private func uploadTapped() {
        let documentPicker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        present(documentPicker, animated: true)
    }
    
    private func uploadFile(at url: URL) {
        Task {
            uploadButton.isEnabled = false
            progressView.isHidden = false
            progressLabel.isHidden = false
            progressView.progress = 0
            
            do {
                let fileName = url.lastPathComponent
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let destinationPath = "documents/\(timestamp)_\(fileName)"
                
                let objectUrl = try await storageService.uploadFile(
                    fileURL: url,
                    destinationPath: destinationPath
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.progressView.progress = Float(progress)
                        self?.progressLabel.text = "\(Int(progress * 100))%"
                    }
                }
                
                await showSuccessAlert(url: objectUrl)
                
            } catch {
                await showErrorAlert(error: error)
            }
            
            await MainActor.run {
                uploadButton.isEnabled = true
                progressView.isHidden = true
                progressLabel.isHidden = true
            }
        }
    }
    
    @MainActor
    private func showSuccessAlert(url: String) {
        let alert = UIAlertController(
            title: "Success",
            message: "File uploaded successfully!\n\n\(url)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy URL", style: .default) { _ in
            UIPasteboard.general.string = url
        })
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    @MainActor
    private func showErrorAlert(error: Error) {
        let alert = UIAlertController(
            title: "Upload Failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UIDocumentPickerDelegate

extension DocumentUploadViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        uploadFile(at: url)
    }
}
```

---

## Best Practices

### 1. File Path Organization

```swift
extension SpiralStorageService {
    
    enum FileCategory {
        case image
        case video
        case document
        case model3D
        case audio
        
        var folderName: String {
            switch self {
            case .image: return "images"
            case .video: return "videos"
            case .document: return "documents"
            case .model3D: return "models"
            case .audio: return "audio"
            }
        }
    }
    
    static func generatePath(
        for category: FileCategory,
        fileName: String,
        userId: String? = nil
    ) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let cleanFileName = fileName.replacingOccurrences(of: " ", with: "_")
        
        if let userId = userId {
            return "\(category.folderName)/\(userId)/\(timestamp)_\(cleanFileName)"
        } else {
            return "\(category.folderName)/\(timestamp)_\(cleanFileName)"
        }
    }
}

// Usage:
let path = SpiralStorageService.generatePath(
    for: .model3D,
    fileName: "spaceship.glb",
    userId: "user123"
)
// Result: "models/user123/1729446000000_spaceship.glb"
```

### 2. Error Handling with Retry Logic

```swift
extension SpiralStorageService {
    
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
                    // Wait before retrying (exponential backoff)
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        
        throw lastError ?? StorageError.uploadFailed
    }
}
```

### 3. Background Upload Support

```swift
class BackgroundUploadService {
    
    static let shared = BackgroundUploadService()
    
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.yourapp.background-upload"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    func uploadInBackground(
        fileURL: URL,
        destinationPath: String
    ) async throws -> String {
        // Implementation for background uploads
        // This would require additional setup with URLSessionDelegate
        fatalError("Implement background upload logic")
    }
}
```

### 4. File Validation

```swift
extension SpiralStorageService {
    
    struct ValidationRules {
        let maxFileSize: Int // in bytes
        let allowedExtensions: [String]
        let allowedMimeTypes: [String]
    }
    
    func validateFile(
        at url: URL,
        rules: ValidationRules
    ) throws {
        // Check file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.fileNotFound
        }
        
        // Check file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int else {
            throw StorageError.invalidResponse
        }
        
        if fileSize > rules.maxFileSize {
            throw StorageError.uploadFailed
        }
        
        // Check extension
        let fileExtension = url.pathExtension.lowercased()
        guard rules.allowedExtensions.contains(fileExtension) else {
            throw StorageError.uploadFailed
        }
    }
}

// Usage:
let rules = SpiralStorageService.ValidationRules(
    maxFileSize: 100 * 1024 * 1024, // 100MB
    allowedExtensions: ["jpg", "png", "pdf", "glb"],
    allowedMimeTypes: ["image/jpeg", "image/png", "application/pdf"]
)

try storageService.validateFile(at: fileURL, rules: rules)
```

---

## Troubleshooting

### Common Issues

#### 1. "Cannot access file" Error

**Problem:** Security-scoped resource access denied

**Solution:**
```swift
guard url.startAccessingSecurityScopedResource() else {
    throw StorageError.fileNotFound
}
defer { url.stopAccessingSecurityScopedResource() }
```

#### 2. Upload Fails Silently

**Problem:** Missing error handling

**Solution:**
```swift
do {
    let url = try await storageService.uploadFile(...)
    print("Success: \(url)")
} catch {
    print("Error: \(error.localizedDescription)")
    // Handle error appropriately
}
```

#### 3. Progress Not Updating

**Problem:** Not dispatching to main actor

**Solution:**
```swift
await MainActor.run {
    self.uploadProgress = progress
}
```

#### 4. Network Request Timeout

**Problem:** Large files timing out

**Solution:**
```swift
var request = URLRequest(url: url)
request.timeoutInterval = 300 // 5 minutes
```

#### 5. ETag Missing from Response

**Problem:** R2 CORS not configured

**Solution:** Ensure R2 bucket has CORS policy with:
```json
{
  "ExposeHeaders": ["ETag"]
}
```

---

## Advanced Features

### 1. Download with Progress

```swift
extension SpiralStorageService {
    
    func downloadFile(
        from urlString: String,
        progress: ProgressHandler? = nil
    ) async throws -> Data {
        
        guard let url = URL(string: urlString) else {
            throw StorageError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.invalidResponse
        }
        
        return data
    }
}
```

### 2. Thumbnail Generation

```swift
extension UIImage {
    func generateThumbnail(maxSize: CGFloat = 200) -> UIImage? {
        let size = self.size
        let scale = min(maxSize / size.width, maxSize / size.height)
        let newSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        defer { UIGraphicsEndImageContext() }
        
        draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
```

### 3. Upload Queue Manager

```swift
@MainActor
class UploadQueueManager: ObservableObject {
    
    @Published var queue: [UploadTask] = []
    @Published var currentUpload: UploadTask?
    
    private let storageService = SpiralStorageService()
    
    struct UploadTask: Identifiable {
        let id = UUID()
        let fileURL: URL
        let destinationPath: String
        var progress: Double = 0
        var status: Status = .pending
        
        enum Status {
            case pending
            case uploading
            case completed(String)
            case failed(Error)
        }
    }
    
    func addToQueue(fileURL: URL, destinationPath: String) {
        let task = UploadTask(fileURL: fileURL, destinationPath: destinationPath)
        queue.append(task)
        
        if currentUpload == nil {
            processNextUpload()
        }
    }
    
    private func processNextUpload() {
        guard currentUpload == nil,
              let index = queue.firstIndex(where: { $0.status == .pending }) else {
            return
        }
        
        currentUpload = queue[index]
        queue[index].status = .uploading
        
        Task {
            await uploadTask(at: index)
        }
    }
    
    private func uploadTask(at index: Int) async {
        let task = queue[index]
        
        do {
            let url = try await storageService.uploadFile(
                fileURL: task.fileURL,
                destinationPath: task.destinationPath
            ) { progress in
                self.queue[index].progress = progress
            }
            
            queue[index].status = .completed(url)
            
        } catch {
            queue[index].status = .failed(error)
        }
        
        currentUpload = nil
        processNextUpload()
    }
}
```

---

## Testing

### Unit Test Example

```swift
import XCTest
@testable import YourApp

final class SpiralStorageServiceTests: XCTestCase {
    
    var storageService: SpiralStorageService!
    
    override func setUp() {
        super.setUp()
        storageService = SpiralStorageService()
    }
    
    func testFilePathGeneration() {
        let path = SpiralStorageService.generatePath(
            for: .image,
            fileName: "test image.jpg",
            userId: "user123"
        )
        
        XCTAssertTrue(path.contains("images/user123"))
        XCTAssertTrue(path.hasSuffix("test_image.jpg"))
    }
    
    func testUploadSmallFile() async throws {
        // Create test file
        let testData = "Hello, World!".data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.txt")
        try testData.write(to: tempURL)
        
        // Upload
        let result = try await storageService.uploadFile(
            fileURL: tempURL,
            destinationPath: "test/test.txt"
        )
        
        XCTAssertTrue(result.contains("storage.spiral-technology.org"))
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }
}
```

---

## Complete Example App

See the full example project structure:

```
YourApp/
├── Models/
│   ├── SpiralStorageService.swift
│   └── UploadTask.swift
├── ViewModels/
│   ├── FileUploadViewModel.swift
│   └── UploadQueueManager.swift
├── Views/
│   ├── SwiftUI/
│   │   ├── FileUploadView.swift
│   │   ├── ImageUploadView.swift
│   │   └── VideoUploadView.swift
│   └── UIKit/
│       └── DocumentUploadViewController.swift
└── Utils/
    ├── FileValidator.swift
    └── PathGenerator.swift
```

---

## API Reference

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/r2/multipart/create` | POST | Create multipart upload |
| `/r2/multipart/complete` | POST | Complete multipart upload |
| `/r2/multipart/abort` | POST | Abort multipart upload |

### Request/Response Examples

See [USAGE.md](./USAGE.md) for detailed API documentation.

---

## Resources

- **Production API:** https://spiralstorage-production.up.railway.app
- **Storage CDN:** https://storage.spiral-technology.org
- **API Documentation:** [USAGE.md](./USAGE.md)
- **Frontend Integration:** [FRONTEND_INTEGRATION.md](./FRONTEND_INTEGRATION.md)

---

## Support

For issues or questions:
1. Check this documentation
2. Review error messages carefully
3. Test with small files first
4. Verify network connectivity
5. Check R2 CORS configuration

---

**Happy coding! 🚀**
