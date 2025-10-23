//
//  StorageUsageExamples.swift
//  roboscope2
//
//  Example usage patterns for Spiral Storage Service
//  NOTE: This file contains examples only - not compiled into the app
//

#if DEBUG_EXAMPLES // Not compiled by default - for reference only

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Example 1: Simple File Upload

struct SimpleFileUploadExample: View {
    @StateObject private var viewModel = StorageUploadViewModel()
    @State private var showFilePicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Upload Progress
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
            
            // Result
            if let url = viewModel.uploadedURL {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Upload Successful!")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    Text(url)
                        .font(.caption)
                        .lineLimit(2)
                    
                    Button("Copy URL") {
                        UIPasteboard.general.string = url
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
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
                    await viewModel.uploadFile(
                        url: url,
                        category: .document
                    )
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Example 2: Upload AR Scan

func uploadARScan(
    captureSession: CaptureSession,
    sessionId: UUID,
    spaceId: UUID,
    onProgress: @escaping (Double, String) -> Void,
    onComplete: @escaping (String?) -> Void
) {
    captureSession.exportAndUploadMeshData(
        sessionId: sessionId,
        spaceId: spaceId,
        progress: { progress, status in
            onProgress(progress, status)
        },
        completion: { localURL, cloudURL in
            onComplete(cloudURL)
        }
    )
}

// MARK: - Example 3: Upload Multiple Files with Queue

struct MultipleFileUploadExample: View {
    @StateObject private var viewModel = StorageUploadViewModel()
    
    var body: some View {
        VStack {
            // Queue List
            List(viewModel.uploadQueue) { task in
                HStack {
                    Text(task.fileURL.lastPathComponent)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(task.status.displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if case .uploading = task.status {
                        ProgressView(value: task.progress)
                            .frame(width: 50)
                    }
                }
            }
            
            // Actions
            HStack {
                Button("Clear Completed") {
                    viewModel.clearCompleted()
                }
                
                Button("Retry Failed") {
                    viewModel.retryFailed()
                }
            }
            .padding()
        }
    }
}

// MARK: - Example 4: Upload with Validation

func uploadWithValidation(fileURL: URL) async throws -> String {
    let storageService = SpiralStorageService.shared
    
    // Validate file
    try storageService.validateFile(
        at: fileURL,
        rules: .scanRules // Use scan rules for 3D files
    )
    
    // Upload with retry
    let cloudURL = try await storageService.uploadFileWithRetry(
        fileURL: fileURL,
        destinationPath: SpiralStorageService.generatePath(
            for: .scan,
            fileName: fileURL.lastPathComponent
        ),
        maxRetries: 3
    ) { progress in
        print("Upload progress: \(Int(progress * 100))%")
    }
    
    return cloudURL
}

// MARK: - Example 5: Direct Service Usage

func directUploadExample() async {
    let storageService = SpiralStorageService.shared
    
    // Create a test file
    let testData = "Hello, Spiral Storage!".data(using: .utf8)!
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("test.txt")
    
    do {
        try testData.write(to: tempURL)
        
        // Upload
        let cloudURL = try await storageService.uploadFile(
            fileURL: tempURL,
            destinationPath: "test/example.txt"
        ) { progress in
            print("Progress: \(Int(progress * 100))%")
        }
        
        print("Uploaded to: \(cloudURL)")
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
        
    } catch {
        print("Upload failed: \(error)")
    }
}

// MARK: - Example 6: Path Generation

func pathGenerationExamples() {
    // Simple path
    let path1 = SpiralStorageService.generatePath(
        for: .image,
        fileName: "photo.jpg"
    )
    // Result: "images/1729446000000_photo.jpg"
    
    // Path with session
    let path2 = SpiralStorageService.generatePath(
        for: .scan,
        fileName: "room_scan.usdc",
        sessionId: UUID()
    )
    // Result: "scans/session-{uuid}/1729446000000_room_scan.obj"
    
    // Path with space and session
    let path3 = SpiralStorageService.generatePath(
        for: .model3D,
        fileName: "model.usdz",
        sessionId: UUID(),
        spaceId: UUID()
    )
    // Result: "models/space-{uuid}/session-{uuid}/1729446000000_model.usdz"
    
    print("Path 1: \(path1)")
    print("Path 2: \(path2)")
    print("Path 3: \(path3)")
}

// MARK: - Example 7: Error Handling

func errorHandlingExample(fileURL: URL) async {
    let storageService = SpiralStorageService.shared
    
    do {
        let cloudURL = try await storageService.uploadFile(
            fileURL: fileURL,
            destinationPath: "uploads/file.obj"
        )
        print("Success: \(cloudURL)")
        
    } catch StorageError.fileTooLarge(let maxSizeMB) {
        print("File exceeds \(maxSizeMB)MB limit")
        
    } catch StorageError.invalidFileType {
        print("File type not allowed")
        
    } catch StorageError.serverError(let code, let message) {
        print("Server error \(code): \(message)")
        
    } catch {
        print("Unexpected error: \(error)")
    }
}

#endif // DEBUG_EXAMPLES
