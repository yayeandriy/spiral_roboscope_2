# Storage API Integration Checklist

## ✅ Implementation Complete

### Core Service
- [x] `SpiralStorageService.swift` - Main storage service
  - [x] Multipart upload support (5MB chunks)
  - [x] Progress tracking with callbacks
  - [x] Automatic retry with exponential backoff (1s, 2s, 4s)
  - [x] File validation (size, type)
  - [x] Path generation utilities
  - [x] Comprehensive error handling
  
### View Model
- [x] `StorageUploadViewModel.swift` - SwiftUI integration
  - [x] Single file upload
  - [x] Upload queue management
  - [x] Task status tracking
  - [x] Retry failed uploads
  - [x] Clear completed tasks

### Integration Points
- [x] `CaptureSession.swift` - AR scan export
  - [x] `exportAndUploadMeshData` method
  - [x] Combined local export + cloud upload
  - [x] Progress tracking (0-80% export, 80-100% upload)

### Documentation
- [x] `STORAGE_IMPLEMENTATION.md` - Implementation guide
- [x] `StorageUsageExamples.swift` - Code examples
- [x] Integration checklist (this file)

### Testing
- [x] All files compile without errors
- [x] Service follows best practices from API guide
- [x] Error handling implemented

---

## 🔧 Next Steps for Integration

### 1. Update ContentView for AR Scan Upload

**File:** `roboscope2/ContentView.swift`

Replace the existing `exportMeshData` call with `exportAndUploadMeshData`:

```swift
// OLD:
captureSession.exportMeshData(
    progress: { progress, status in
        // ...
    },
    completion: { url in
        // ...
    }
)

// NEW:
captureSession.exportAndUploadMeshData(
    sessionId: currentWorkSession?.id,
    spaceId: currentSpace?.id,
    progress: { progress, status in
        DispatchQueue.main.async {
            self.exportProgress = progress
            self.exportStatus = status
        }
    },
    completion: { localURL, cloudURL in
        DispatchQueue.main.async {
            self.isExporting = false
            if let cloudURL = cloudURL {
                print("Uploaded to cloud: \(cloudURL)")
                // TODO: Save cloudURL to session or marker
            }
            if let localURL = localURL {
                self.exportURL = localURL
                self.showShareSheet = true
            }
        }
    }
)
```

**Estimated time:** 10 minutes

---

### 2. Add Cloud URL to Models

**File:** `roboscope2/Models/Marker.swift`

Add optional cloud URL field:

```swift
struct Marker: Codable, Identifiable, Hashable {
    // ... existing fields ...
    let cloudUrl: String? // Add this
    
    enum CodingKeys: String, CodingKey {
        // ... existing cases ...
        case cloudUrl = "cloud_url"
    }
}
```

**File:** `roboscope2/Models/Space.swift`

Already has `modelGlbUrl` and `modelUsdcUrl` - no changes needed.

**Estimated time:** 5 minutes

---

### 3. Update MarkerService for Screenshot Upload

**File:** `roboscope2/Services/MarkerService.swift`

Add method to upload marker screenshots:

```swift
func uploadMarkerSnapshot(
    _ image: UIImage,
    markerId: UUID,
    sessionId: UUID
) async throws -> String {
    // Convert to JPEG
    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
        throw NSError(domain: "MarkerService", code: -1)
    }
    
    // Save to temp file
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(markerId).jpg")
    try imageData.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    
    // Upload
    let storageService = SpiralStorageService.shared
    return try await storageService.uploadFile(
        fileURL: tempURL,
        destinationPath: SpiralStorageService.generatePath(
            for: .image,
            fileName: "marker-\(markerId).jpg",
            sessionId: sessionId
        )
    )
}
```

**Estimated time:** 15 minutes

---

### 4. Add Upload Progress UI

**Option A:** Simple progress indicator in ContentView

```swift
if isExporting {
    VStack {
        ProgressView(value: exportProgress)
            .progressViewStyle(.linear)
        Text(exportStatus)
            .font(.caption)
        Text("\(Int(exportProgress * 100))%")
            .font(.caption2)
    }
    .padding()
    .background(.ultraThinMaterial)
    .cornerRadius(12)
}
```

**Option B:** Dedicated upload queue view

Create `UploadQueueView.swift` using `StorageUploadViewModel` for batch uploads.

**Estimated time:** 20-30 minutes

---

### 5. Test with Real Files

**Test Cases:**

- [ ] Small file upload (< 5MB)
  - Create test text file
  - Upload and verify URL
  
- [ ] Large file upload (> 5MB)
  - Use real AR scan export
  - Verify multipart upload works
  - Check progress updates
  
- [ ] Network error handling
  - Turn off WiFi during upload
  - Verify retry logic works
  
- [ ] File validation
  - Try uploading invalid file type
  - Try uploading oversized file
  
- [ ] Path organization
  - Verify files organized by category
  - Check session/space folder structure

**Estimated time:** 30 minutes

---

### 6. Optional Enhancements

#### Background Upload Support
```swift
class BackgroundUploadService {
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.roboscope.background-upload"
        )
        return URLSession(configuration: config)
    }()
}
```

#### Download Support
```swift
extension SpiralStorageService {
    func downloadFile(from url: String) async throws -> Data
}
```

#### Thumbnail Generation
```swift
extension UIImage {
    func generateThumbnail(maxSize: CGFloat = 200) -> UIImage?
}
```

**Estimated time:** 2-4 hours

---

## 📝 Configuration Required

### Info.plist

Ensure network security settings allow connections to storage API:

```xml
<key>NSAppTransportSecurity</key>
<dict>
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
        </dict>
    </dict>
</dict>
```

**Status:** Check `AppInfo.plist` or `Info.plist`

---

## 🧪 Testing Strategy

### Unit Tests
```swift
final class SpiralStorageServiceTests: XCTestCase {
    func testPathGeneration() { }
    func testFileValidation() { }
    func testSmallFileUpload() async throws { }
}
```

### Integration Tests
- AR scan export + upload
- Multiple file queue
- Error recovery
- Progress tracking

### Manual QA
- Upload various file types
- Test with poor network
- Verify cloud URLs accessible
- Check file organization

---

## 📊 Success Criteria

- [x] Core service implemented and compiling
- [x] View model for UI integration ready
- [x] AR scan upload integrated
- [ ] ContentView updated to use cloud upload
- [ ] Models updated with cloud URL fields
- [ ] UI shows upload progress
- [ ] All test cases passing
- [ ] Files accessible via CDN URLs

---

## 🚀 Deployment Notes

### Environment Variables
- `NEXT_PUBLIC_STORAGE_URL=https://spiralstorage-production.up.railway.app`

### CDN URL Pattern
- `https://storage.spiral-technology.org/{key}`

### File Organization
```
scans/
  └── space-{uuid}/
      └── session-{uuid}/
          └── {timestamp}_{filename}

models/
  └── space-{uuid}/
      └── {timestamp}_{filename}

images/
  └── session-{uuid}/
      └── {timestamp}_{filename}
```

---

## 📚 Resources

- **API Guide:** `docs/STORAGE_API_INTEGRATION.md`
- **Implementation:** `docs/STORAGE_IMPLEMENTATION.md`
- **Examples:** `Services/Storage/StorageUsageExamples.swift`
- **Service:** `Services/Storage/SpiralStorageService.swift`
- **View Model:** `Services/Storage/StorageUploadViewModel.swift`

---

## ✨ Summary

**Completed:**
- ✅ Comprehensive storage service with multipart upload
- ✅ Progress tracking and retry logic
- ✅ File validation and path organization
- ✅ SwiftUI view model for UI integration
- ✅ AR scan export and upload integration
- ✅ Complete documentation and examples

**Ready for:**
- Integration into existing views (ContentView, etc.)
- Testing with real AR scans
- Production deployment

**Estimated integration time:** 1-2 hours
**Estimated testing time:** 30 minutes

---

**Status: Ready for Integration** ✅
