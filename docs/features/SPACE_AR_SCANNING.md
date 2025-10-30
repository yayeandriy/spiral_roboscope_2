# Space AR Scanning Implementation

## Overview

Added comprehensive spatial scanning functionality to SpaceARView, allowing users to scan their environment and save the scan data to the Space via the Spiral Storage API.

---

## Changes Made

### 1. Updated Space Model

**File:** `Models/Space.swift`

Added `scanUrl` field to store the URL of uploaded spatial scans:

```swift
struct Space: Codable, Identifiable, Hashable {
    // ... existing fields ...
    let scanUrl: String?  // ← Added
    
    enum CodingKeys: String, CodingKey {
        // ... existing cases ...
        case scanUrl = "scan_url"  // ← Added
    }
}
```

**UpdateSpace DTO:**
```swift
struct UpdateSpace: Codable {
    // ... existing fields ...
    let scanUrl: String?  // ← Added
    
    init(
        // ... existing params ...
        scanUrl: String? = nil  // ← Added
    )
}
```

---

### 2. Enhanced SpaceARView

**File:** `Views/SpaceARView.swift`

#### New State Variables

```swift
// Scanning state
@State private var isScanning = false
@State private var hasScanData = false
@State private var isExporting = false
@State private var exportProgress: Double = 0.0
@State private var exportStatus: String = ""
@State private var showSuccessMessage = false
```

#### UI Components

1. **Start Scan Button** (Initial state)
   - Blue button at bottom
   - Starts AR mesh scanning
   - Uses existing `CaptureSession.startScanning()`

2. **Stop Scan Button** (During scanning)
   - Red button at bottom
   - Stops AR mesh scanning
   - Marks scan data as available

3. **Action Buttons** (After scan complete)
   - **Start Again** (Orange): Discard scan and restart
   - **Save to Space** (Green): Export, upload, and update Space

4. **Export Progress Overlay**
   - Shows progress bar (0-100%)
   - Displays status messages
   - Appears during export/upload

5. **Success Message**
   - Green checkmark animation
   - Auto-dismisses after 2 seconds
   - Shows after successful save

---

## Workflow

### 1. Start Scanning

```
User taps "Start Scan"
    ↓
captureSession.startScanning()
    ↓
AR mesh reconstruction begins
    ↓
Button changes to "Stop Scan" (red)
```

### 2. Stop Scanning

```
User taps "Stop Scan"
    ↓
captureSession.stopScanning()
    ↓
Scan data captured
    ↓
Show "Start Again" and "Save to Space" buttons
```

### 3. Save to Space

```
User taps "Save to Space"
    ↓
Show export progress overlay
    ↓
captureSession.exportAndUploadMeshData()
    ├─ 0-80%: Export mesh to local USDC file
    └─ 80-100%: Upload to Spiral Storage
        ↓
    Receive cloud URL
        ↓
    updateSpaceWithScanUrl(cloudURL)
        ↓
    spaceService.updateSpace(scanUrl: cloudURL)
        ↓
    API PATCH /spaces/{id}
        ↓
    Show success message
        ↓
    Auto-dismiss after 2s
```

---

## API Integration

### Storage Upload

Uses the existing `CaptureSession.exportAndUploadMeshData()` method:

```swift
captureSession.exportAndUploadMeshData(
    sessionId: nil,           // No session context
    spaceId: space.id,        // Associate with space
    progress: { progress, status in
        // Update UI with progress (0.0 - 1.0)
    },
    completion: { localURL, cloudURL in
        // Handle upload completion
    }
)
```

**File Path:**
```
scans/space-{uuid}/{timestamp}_{filename}.usdc
```

Example:
```
scans/space-123e4567-e89b-12d3-a456-426614174000/1729446000000_spatial_scan.usdc
```

---

### Space Update

Uses the existing `SpaceService.updateSpace()` method:

```swift
let update = UpdateSpace(scanUrl: cloudURL)
let updatedSpace = try await spaceService.updateSpace(
    id: space.id, 
    update: update
)
```

**API Call:**
```
PATCH http://192.168.0.115:8080/api/v1/spaces/{id}
Content-Type: application/json

{
  "scan_url": "https://storage.spiral-technology.org/scans/space-{uuid}/..."
}
```

**Response:**
```json
{
  "id": "uuid",
  "key": "warehouse-b",
  "name": "Warehouse - Section B",
  "scan_url": "https://storage.spiral-technology.org/scans/...",
  ...
}
```

---

## UI States

### State 1: Initial (No Scan)
```
┌─────────────────────────────┐
│                   [Done]    │
│                             │
│       AR View               │
│                             │
│                             │
│  ┌───────────────────────┐  │
│  │ 📷 Start Scan [Glass]│  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

### State 2: Scanning
```
┌─────────────────────────────┐
│                   [Done]    │
│                             │
│   AR View (mesh overlay)    │
│                             │
│                             │
│  ┌───────────────────────┐  │
│  │ ⏹ Stop Scan [Red]    │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

### State 3: Scan Complete
```
┌─────────────────────────────┐
│                   [Done]    │
│                             │
│       AR View               │
│                             │
│                             │
│  ┌──────────┐ ┌───────────┐ │
│  │🔄 Start  │ │💾 Save to │ │
│  │ [Orange] │ │ [Green]   │ │
│  └──────────┘ └───────────┘ │
└─────────────────────────────┘
```

**Note:** All buttons use iOS 18+ Liquid Glass effect (`.lgCapsule()`) with fallback for earlier iOS versions.

### State 4: Exporting
```
┌─────────────────────────────┐
│  [X Close]                  │
│                             │
│    ┌─────────────────┐      │
│    │ ▓▓▓▓▓▓░░░░ 65%  │      │
│    │ Uploading...    │      │
│    └─────────────────┘      │
│                             │
│                             │
└─────────────────────────────┘
```

### State 5: Success
```
┌─────────────────────────────┐
│  [X Close]                  │
│                             │
│    ┌─────────────────┐      │
│    │   ✓             │      │
│    │ Scan Saved!     │      │
│    │ Space updated   │      │
│    └─────────────────┘      │
│                             │
│                             │
└─────────────────────────────┘
```

---

## Error Handling

### Upload Failure
```swift
guard let cloudURL = cloudURL else {
    print("[SpaceAR] Upload failed - no cloud URL")
    exportStatus = "Upload failed"
    return
}
```

### Space Update Failure
```swift
catch {
    print("[SpaceAR] Failed to update space: \(error)")
    exportStatus = "Failed to update space"
}
```

---

## Testing Checklist

- [ ] Start scan button starts mesh reconstruction
- [ ] Stop scan button stops reconstruction
- [ ] Start again resets state
- [ ] Save to Space exports USDC file
- [ ] Upload progress shows 0-100%
- [ ] Cloud URL returned from storage
- [ ] Space updated with scan_url
- [ ] Success message appears
- [ ] Success message auto-dismisses
- [ ] Error handling for failed uploads
- [ ] Error handling for failed space updates

---

## Integration Points

### CaptureSession
- `startScanning()` - Starts AR mesh reconstruction
- `stopScanning()` - Stops mesh reconstruction
- `exportAndUploadMeshData()` - Exports and uploads scan

### SpiralStorageService
- Multipart upload for large USDC files
- Progress tracking (0-80% export, 80-100% upload)
- Returns cloud URL for uploaded file

### SpaceService
- `updateSpace(id:update:)` - Updates space with scan URL
- Automatically refreshes local space list

---

## Files Modified

1. ✅ `Models/Space.swift`
   - Added `scanUrl: String?` field
   - Updated `CodingKeys` enum
   - Updated `UpdateSpace` DTO

2. ✅ `Views/SpaceARView.swift`
   - Added scanning state management
   - Added bottom control buttons
   - Added export progress overlay
   - Added success message overlay
   - Implemented scanning workflow
   - Integrated storage upload
   - Integrated space update

---

## API Reference

### Backend API

**Endpoint:** `PATCH /spaces/{id}`

**Request:**
```json
{
  "scan_url": "https://storage.spiral-technology.org/scans/..."
}
```

**Response:** Updated Space object with new scan_url

**Documentation:** http://192.168.0.115:8080/#patch-/spaces/-id-

---

## Notes

- Scan data is stored separately from the space model (USDC/GLB)
- Each space can have one scan URL (overwrites on new scan)
- Scan files are organized by space ID in storage
- Export progress: 0-80% local, 80-100% upload
- Success message auto-dismisses to avoid blocking UI
- User can scan multiple times (Start Again)

---

## Future Enhancements

1. **Scan Preview**
   - Show mesh wireframe during scanning
   - Display polygon count

2. **Scan Quality**
   - Add decimation factor control
   - Show estimated file size

3. **Multiple Scans**
   - Support scan versioning
   - List previous scans
   - Compare scans

4. **Background Upload**
   - Upload in background after export
   - Continue if app backgrounded

5. **Scan Metadata**
   - Store scan date, device info
   - Add scan notes/description

---

**Status: ✅ Implementation Complete**

All files compile without errors. Ready for testing with real AR scans.
