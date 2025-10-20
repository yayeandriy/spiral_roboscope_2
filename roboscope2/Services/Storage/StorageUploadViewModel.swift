//
//  StorageUploadViewModel.swift
//  roboscope2
//
//  View model for managing file uploads to Spiral Storage
//

import Foundation
import SwiftUI
import Combine

/// View model for managing file uploads with progress tracking and queue management
@MainActor
class StorageUploadViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var uploadProgress: Double = 0
    @Published var isUploading = false
    @Published var uploadedURL: String?
    @Published var errorMessage: String?
    @Published var uploadQueue: [UploadTask] = []
    
    // MARK: - Private Properties
    
    private let storageService = SpiralStorageService.shared
    
    // MARK: - Upload Task
    
    struct UploadTask: Identifiable {
        let id = UUID()
        let fileURL: URL
        let destinationPath: String
        var progress: Double = 0
        var status: Status = .pending
        
        enum Status: Equatable {
            case pending
            case uploading
            case completed(String)
            case failed(Error)
            
            // Custom Equatable implementation since Error doesn't conform
            static func == (lhs: Status, rhs: Status) -> Bool {
                switch (lhs, rhs) {
                case (.pending, .pending): return true
                case (.uploading, .uploading): return true
                case (.completed(let lUrl), .completed(let rUrl)): return lUrl == rUrl
                case (.failed, .failed): return true
                default: return false
                }
            }
            
            var displayText: String {
                switch self {
                case .pending: return "Pending"
                case .uploading: return "Uploading..."
                case .completed: return "Completed"
                case .failed: return "Failed"
                }
            }
        }
    }
    
    // MARK: - Single File Upload
    
    /// Upload a single file with progress tracking
    /// - Parameters:
    ///   - url: Local file URL
    ///   - category: File category for organized storage
    ///   - sessionId: Optional session ID for grouping
    ///   - spaceId: Optional space ID for grouping
    ///   - withRetry: Enable automatic retry on failure
    func uploadFile(
        url: URL,
        category: SpiralStorageService.FileCategory,
        sessionId: UUID? = nil,
        spaceId: UUID? = nil,
        withRetry: Bool = true
    ) async {
        isUploading = true
        uploadProgress = 0
        uploadedURL = nil
        errorMessage = nil
        
        // Start accessing security-scoped resource for files from document picker
        let shouldStopAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            // Validate file
            try storageService.validateFile(
                at: url,
                rules: category == .scan ? .scanRules : .defaultRules
            )
            
            // Generate destination path
            let fileName = url.lastPathComponent
            let destinationPath = SpiralStorageService.generatePath(
                for: category,
                fileName: fileName,
                sessionId: sessionId,
                spaceId: spaceId
            )
            
            print("[Upload] Starting upload: \(fileName) -> \(destinationPath)")
            
            // Upload file
            let objectUrl: String
            if withRetry {
                objectUrl = try await storageService.uploadFileWithRetry(
                    fileURL: url,
                    destinationPath: destinationPath
                ) { progress in
                    self.uploadProgress = progress
                }
            } else {
                objectUrl = try await storageService.uploadFile(
                    fileURL: url,
                    destinationPath: destinationPath
                ) { progress in
                    self.uploadProgress = progress
                }
            }
            
            uploadedURL = objectUrl
            print("[Upload] Success: \(objectUrl)")
            
        } catch {
            errorMessage = error.localizedDescription
            print("[Upload] Failed: \(error)")
        }
        
        isUploading = false
    }
    
    // MARK: - Queue Management
    
    /// Add file to upload queue
    func addToQueue(
        fileURL: URL,
        category: SpiralStorageService.FileCategory,
        sessionId: UUID? = nil,
        spaceId: UUID? = nil
    ) {
        let fileName = fileURL.lastPathComponent
        let destinationPath = SpiralStorageService.generatePath(
            for: category,
            fileName: fileName,
            sessionId: sessionId,
            spaceId: spaceId
        )
        
        let task = UploadTask(fileURL: fileURL, destinationPath: destinationPath)
        uploadQueue.append(task)
        
        // Start processing if not already uploading
        if !isUploading {
            Task {
                await processQueue()
            }
        }
    }
    
    /// Process upload queue sequentially
    private func processQueue() async {
        guard !uploadQueue.isEmpty else { return }
        
        // Find next pending task
        guard let index = uploadQueue.firstIndex(where: { $0.status == .pending }) else {
            return
        }
        
        isUploading = true
        uploadQueue[index].status = .uploading
        
        let task = uploadQueue[index]
        
        // Start accessing security-scoped resource
        let shouldStopAccessing = task.fileURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                task.fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            let objectUrl = try await storageService.uploadFileWithRetry(
                fileURL: task.fileURL,
                destinationPath: task.destinationPath
            ) { progress in
                self.uploadQueue[index].progress = progress
            }
            
            uploadQueue[index].status = .completed(objectUrl)
            
        } catch {
            uploadQueue[index].status = .failed(error)
        }
        
        isUploading = false
        
        // Continue with next task
        await processQueue()
    }
    
    /// Clear completed tasks from queue
    func clearCompleted() {
        uploadQueue.removeAll { task in
            if case .completed = task.status {
                return true
            }
            return false
        }
    }
    
    /// Retry failed tasks
    func retryFailed() {
        for index in uploadQueue.indices {
            if case .failed = uploadQueue[index].status {
                uploadQueue[index].status = .pending
            }
        }
        
        Task {
            await processQueue()
        }
    }
}
