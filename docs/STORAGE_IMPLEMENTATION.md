# Spiral Storage Integration - Implementation Summary

## Overview

Comprehensive Spiral Storage API integration for the roboscope2 iOS app, enabling multipart uploads of AR scans, 3D models, and media files to Cloudflare R2 storage.

**Storage API Endpoint:** `https://spiralstorage-production.up.railway.app`

---

## Files Created

### 1. `Services/Storage/SpiralStorageService.swift`

Core storage service implementing the Spiral Storage API client.

**Features:**
- ✅ Multipart upload support for large files (5MB chunks)
- ✅ Progress tracking with callback handlers
- ✅ Automatic retry with exponential backoff
- ✅ File validation (size, type)
- ✅ Organized path generation by category
- ✅ Comprehensive error handling

**Key Methods:**
```swift
// Simple upload with progress
func uploadFile(
    fileURL: URL,
    destinationPath: String,
    progress: ProgressHandler? = nil
) async throws -> String

// Upload with retry logic
func uploadFileWithRetry(
    fileURL: URL,
    destinationPath: String,
    maxRetries: Int = 3,
    progress: ProgressHandler? = nil
) async throws -> String

// Validate file before upload
func validateFile(
    at url: URL,
    rules: ValidationRules = .defaultRules
) throws
```

**File Categories:**
- `.image` → `images/`
- `.video` → `videos/`
- `.document` → `documents/`
- `.model3D` → `models/`
- `.audio` → `audio/`
- `.scan` → `scans/`
- `.other(String)` → custom folder

**Path Generation:**
```swift
SpiralStorageService.generatePath(
    for: .scan,
    fileName: "spatial_scan.obj",
    sessionId: UUID(),
    spaceId: UUID()
)
// Result: "scans/space-{uuid}/session-{uuid}/1729446000000_spatial_scan.obj"
```

---

### 2. `Services/Storage/StorageUploadViewModel.swift`

SwiftUI view model for managing uploads with UI integration.

**Features:**
- ✅ Single file upload with progress
- ✅ Upload queue management
- ✅ Task status tracking (pending, uploading, completed, failed)
- ✅ Retry failed uploads
- ✅ Clear completed tasks

**Usage Example:**
```swift
@StateObject private var uploadVM = StorageUploadViewModel()

// Upload single file
await uploadVM.uploadFile(
    url: fileURL,
    category: .scan,
    sessionId: session.id,
    spaceId: space.id,
    withRetry: true
)

// Add to queue
uploadVM.addToQueue(
    fileURL: fileURL,
    category: .model3D,
    sessionId: session.id
)
```

---

### 3. `Services/CaptureSession.swift` (Extended)

Added storage upload integration to existing AR capture session.

**New Method:**
```swift
func exportAndUploadMeshData(
    sessionId: UUID?,
    spaceId: UUID?,
    progress: @escaping (Double, String) -> Void,
    completion: @escaping (URL?, String?) -> Void
)
```

**Workflow:**
1. Export AR mesh to local OBJ file (0-80% progress)
2. Upload to Spiral Storage (80-100% progress)
3. Return both local URL and cloud URL

**Usage:**
```swift
captureSession.exportAndUploadMeshData(
    sessionId: workSession.id,
    spaceId: space.id
) { progress, status in
    // Update UI
    self.exportProgress = progress
    self.exportStatus = status
} completion: { localURL, cloudURL in
    if let cloudURL = cloudURL {
        print("Uploaded to: \(cloudURL)")
    }
}
```

---

## Storage API Flow

### Multipart Upload Process

```
1. Create Multipart Upload
   POST /r2/multipart/create
   ↓
   Response: { upload_id, key, parts: [{ part_number, url }] }

2. Upload Each Part
   PUT <presigned_url>
   ↓
   Response: ETag header

3. Complete Upload
   POST /r2/multipart/complete
   { upload_id, key, parts: [{ part_number, etag }] }
   ↓
   Response: { object_url }

4. File Available
   https://storage.spiral-technology.org/<key>
```

---

## Error Handling

### StorageError Types

```swift
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
}
```

### Automatic Retry

- Max retries: 3 (configurable)
- Backoff: Exponential (1s, 2s, 4s)
- Retries on: Network errors, server errors
- No retry on: Invalid file, file not found

---

## Validation Rules

### Default Rules
```swift
ValidationRules.defaultRules
- Max size: 500MB
- Extensions: jpg, jpeg, png, pdf, glb, gltf, usdz, usdc, obj, mp4, mov
```

### Scan Rules
```swift
ValidationRules.scanRules
- Max size: 1GB
- Extensions: obj, glb, gltf, usdz, usdc, ply, stl
```

---

## Integration Points

### 1. AR Scan Export (ContentView)

Update the existing export flow to include cloud upload:

```swift
captureSession.exportAndUploadMeshData(
    sessionId: currentSession?.id,
    spaceId: currentSpace?.id,
    progress: { progress, status in
        self.exportProgress = progress
        self.exportStatus = status
    },
    completion: { localURL, cloudURL in
        self.isExporting = false
        if let cloudURL = cloudURL {
            // Save cloud URL to session
            // Show share sheet with both URLs
            self.exportURL = localURL
            self.showShareSheet = true
        }
    }
)
```

### 2. Session Marker Service

Add upload for marker screenshots:

```swift
let storageService = SpiralStorageService.shared

// Upload marker snapshot
let snapshotURL = try await storageService.uploadFile(
    fileURL: localSnapshotURL,
    destinationPath: SpiralStorageService.generatePath(
        for: .image,
        fileName: "marker-\(marker.id).jpg",
        sessionId: session.id
    )
)

// Update marker with cloud URL
marker.snapshotUrl = snapshotURL
```

### 3. Space Model Upload

Add upload for space models:

```swift
let modelURL = try await storageService.uploadFileWithRetry(
    fileURL: localModelURL,
    destinationPath: SpiralStorageService.generatePath(
        for: .model3D,
        fileName: "space-model.usdz",
        spaceId: space.id
    )
)

// Update space with model URL
space.modelUsdcUrl = modelURL
```

---

## Testing

### Manual Testing Checklist

- [ ] Upload small file (< 5MB)
- [ ] Upload large file (> 5MB, triggers multipart)
- [ ] Upload with progress tracking
- [ ] Upload with retry on network failure
- [ ] Validate file size limit
- [ ] Validate file type restrictions
- [ ] Export and upload AR scan
- [ ] Queue multiple uploads

### Test Files

```swift
// Small file test
let testData = "Test content".data(using: .utf8)!
let testURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("test.txt")
try testData.write(to: testURL)

let url = try await SpiralStorageService.shared.uploadFile(
    fileURL: testURL,
    destinationPath: "test/test.txt"
)
print("Uploaded: \(url)")
```

---

## Best Practices

### 1. Security-Scoped Resources

Always properly access and release security-scoped resources:

```swift
let shouldStopAccessing = fileURL.startAccessingSecurityScopedResource()
defer {
    if shouldStopAccessing {
        fileURL.stopAccessingSecurityScopedResource()
    }
}
```

### 2. Progress Reporting

Update UI on main actor:

```swift
await MainActor.run {
    self.uploadProgress = progress
}
```

### 3. Error Handling

Always handle errors gracefully:

```swift
do {
    let url = try await storageService.uploadFile(...)
    // Success
} catch let error as StorageError {
    // Handle specific storage errors
    print("Storage error: \(error.errorDescription ?? "")")
} catch {
    // Handle other errors
    print("Unexpected error: \(error)")
}
```

### 4. Cleanup

Remove temporary files after upload:

```swift
try? FileManager.default.removeItem(at: tempURL)
```

---

## Future Enhancements

### 1. Background Upload Support

```swift
class BackgroundUploadService {
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.roboscope.background-upload"
        )
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
}
```

### 2. Download Support

```swift
extension SpiralStorageService {
    func downloadFile(
        from urlString: String,
        progress: ProgressHandler? = nil
    ) async throws -> Data
}
```

### 3. Thumbnail Generation

```swift
extension UIImage {
    func generateThumbnail(maxSize: CGFloat = 200) -> UIImage?
}
```

### 4. Upload Resume

Support resuming interrupted uploads using the multipart upload ID.

---

## API Reference

### Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/r2/multipart/create` | POST | Create multipart upload |
| `/r2/multipart/complete` | POST | Complete multipart upload |
| `/r2/multipart/abort` | POST | Abort multipart upload |

### Headers

- `Content-Type: application/json` (for JSON requests)
- `ETag` (returned in upload responses)

---

## Resources

- **Integration Guide:** `docs/STORAGE_API_INTEGRATION.md`
- **API Endpoint:** https://spiralstorage-production.up.railway.app
- **CDN Endpoint:** https://storage.spiral-technology.org
- **Repository:** feature-storage-api branch

---

## Summary

✅ **Implemented:**
- Core storage service with multipart upload
- Progress tracking and retry logic
- File validation and path organization
- View model for UI integration
- AR scan export and upload integration

✅ **Tested:**
- Service compiles without errors
- Follows best practices from integration guide
- Ready for integration into existing workflows

✅ **Next Steps:**
1. Update ContentView to use `exportAndUploadMeshData`
2. Add cloud URL fields to Marker and Space models
3. Update UI to show upload progress
4. Test with real AR scans
5. Add background upload support (optional)

---

**Implementation completed successfully! 🚀**
