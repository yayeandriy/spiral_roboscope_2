# iOS Integration - Visual Guide

Visual reference for the iOS integration documentation structure and implementation flow.

## 📚 Documentation Structure

```
docs/
│
├── 📖 IOS_INDEX.md ⭐ START HERE
│   └── Main hub with roadmap, requirements, and quick links
│
├── ⚡ IOS_QUICKSTART.md
│   └── 5-minute setup • Essential snippets • Quick reference
│
├── 🔧 IOS_SWIFT_INTEGRATION_GUIDE.md
│   ├── Network Layer (APIConfiguration, NetworkManager)
│   ├── Data Models (Space, WorkSession, Marker)
│   ├── API Services (SpaceService, WorkSessionService, MarkerService)
│   └── Error Handling & Utilities
│
├── 🎯 IOS_ARKIT_INTEGRATION.md
│   ├── ARKit Session Setup
│   ├── Marker Visualization
│   ├── 3D Model Loading
│   ├── Gesture Interactions
│   └── Performance Optimization
│
├── 🔄 IOS_REALTIME_FEATURES.md
│   ├── Presence Tracking
│   ├── Distributed Locking
│   ├── Conflict Resolution
│   ├── Auto-Sync Manager
│   └── Background Updates
│
├── 🎨 IOS_SWIFTUI_VIEWS.md
│   ├── Space Management Views
│   ├── Work Session Views
│   ├── Marker Views
│   ├── View Models
│   └── Reusable Components
│
└── 💡 IOS_CODE_EXAMPLES.md
    ├── Complete App Structure
    ├── Space Workflow
    ├── AR Session
    ├── Collaborative Editing
    └── Offline Support
```

## 🏗️ iOS App Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     iOS Application                      │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
        ┌───────────────────────────────────────┐
        │          SwiftUI Views                 │
        │  • SpaceListView                      │
        │  • WorkSessionDetailView              │
        │  • ARSessionView                      │
        │  • CollaborativeEditorView            │
        └───────────────┬───────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────────────┐
        │         View Models                    │
        │  • @Published properties              │
        │  • Combine publishers                 │
        │  • Business logic                     │
        └───────────────┬───────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────────────┐
        │      Services Layer                    │
        │  • SpaceService                       │
        │  • WorkSessionService                 │
        │  • MarkerService                      │
        │  • PresenceService                    │
        │  • LockService                        │
        │  • SyncManager                        │
        └───────────────┬───────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────────────┐
        │      Network Manager                   │
        │  • Alamofire wrapper                  │
        │  • Generic request methods            │
        │  • Error mapping                      │
        └───────────────┬───────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────────────┐
        │      Roboscope 2 API                   │
        │  • REST endpoints                     │
        │  • PostgreSQL data                    │
        │  • Redis cache & locks                │
        └───────────────────────────────────────┘
```

## 🔄 Implementation Flow

```
Phase 1: Basic Integration (1-2 days)
    ↓
    Setup Project
    ├── Add Alamofire dependency
    ├── Configure Info.plist
    └── Set API environment
    ↓
    Network Layer
    ├── APIConfiguration.swift
    ├── NetworkManager.swift
    └── APIError.swift
    ↓
    Data Models
    ├── Space.swift
    ├── WorkSession.swift
    ├── Marker.swift
    └── AnyCodable.swift
    ↓
    API Services
    ├── SpaceService.swift
    ├── WorkSessionService.swift
    └── MarkerService.swift
    ↓
    Basic UI
    ├── SpaceListView
    └── Test CRUD operations
    ↓
✅ MILESTONE 1: Can list and manage spaces

Phase 2: AR Features (2-3 days)
    ↓
    ARKit Setup
    ├── ARViewController
    ├── ARView configuration
    └── Session management
    ↓
    Marker Visualization
    ├── Create meshes from 4 points
    ├── Apply materials/colors
    └── Add to AR scene
    ↓
    Interactions
    ├── Tap to place markers
    ├── Long press to select
    └── Gesture handling
    ↓
    3D Models
    ├── Load GLB/USDC files
    ├── Position in space
    └── Performance optimization
    ↓
✅ MILESTONE 2: AR markers working

Phase 3: Collaboration (1-2 days)
    ↓
    Presence Tracking
    ├── PresenceService
    ├── Auto-heartbeat timer
    └── Active users list
    ↓
    Distributed Locking
    ├── LockService
    ├── Acquire/release locks
    └── Auto-extension
    ↓
    Conflict Resolution
    ├── Optimistic concurrency
    ├── Version checking
    └── Retry logic
    ↓
    Auto-Sync
    ├── SyncManager
    ├── Periodic refresh
    └── Notification handling
    ↓
✅ MILESTONE 3: Multi-user collaboration working

Phase 4: Polish (1-2 days)
    ↓
    Complete UI
    ├── All CRUD views
    ├── Error states
    └── Loading indicators
    ↓
    Offline Support
    ├── CoreData caching
    ├── Offline queue
    └── Background sync
    ↓
    Testing
    ├── Unit tests
    ├── Integration tests
    └── User testing
    ↓
✅ MILESTONE 4: Production ready!
```

## 🎯 Feature Map

```
┌──────────────────────────────────────────────────────┐
│                  Roboscope 2 API                      │
├──────────────────────────────────────────────────────┤
│                                                       │
│  📦 Spaces                    🔧 Work Sessions       │
│  ├─ List spaces              ├─ Create sessions     │
│  ├─ Create space             ├─ Update status       │
│  ├─ Update space             ├─ Track timing        │
│  ├─ Delete space             └─ Version control     │
│  └─ Load 3D models                                  │
│                                                       │
│  🎯 Markers                   👥 Presence            │
│  ├─ Create marker            ├─ Join session        │
│  ├─ Bulk create              ├─ Auto-heartbeat      │
│  ├─ Update marker            ├─ List active users   │
│  ├─ Delete marker            └─ Leave session       │
│  └─ AR visualization                                │
│                                                       │
│  🔒 Locks                     📊 Events              │
│  ├─ Acquire lock             ├─ Audit trail         │
│  ├─ Auto-extend              ├─ Filter by entity    │
│  ├─ Release lock             └─ Query events        │
│  └─ Check status                                    │
│                                                       │
└──────────────────────────────────────────────────────┘
```

## 📱 iOS Project Structure

```
YourApp/
│
├── 🎯 App/
│   ├── YourApp.swift                    # App entry point
│   ├── AppState.swift                   # Global app state
│   └── ContentView.swift                # Root view with TabView
│
├── 🌐 Network/
│   ├── APIConfiguration.swift           # Environment config
│   ├── NetworkManager.swift             # Alamofire wrapper
│   └── APIError.swift                   # Error types
│
├── 📦 Models/
│   ├── Space.swift                      # Space model + CRUD types
│   ├── WorkSession.swift                # Session model + enums
│   ├── Marker.swift                     # Marker model + helpers
│   ├── Presence.swift                   # Presence types
│   ├── Lock.swift                       # Lock types
│   └── AnyCodable.swift                 # JSON utility
│
├── 🔧 Services/
│   ├── SpaceService.swift               # Space API calls
│   ├── WorkSessionService.swift         # Session API calls
│   ├── MarkerService.swift              # Marker API calls
│   ├── PresenceService.swift            # Presence tracking
│   ├── LockService.swift                # Distributed locks
│   └── SyncManager.swift                # Auto-sync
│
├── 🎨 Views/
│   ├── Spaces/
│   │   ├── SpaceListView.swift
│   │   ├── SpaceDetailView.swift
│   │   └── CreateSpaceView.swift
│   │
│   ├── WorkSessions/
│   │   ├── WorkSessionListView.swift
│   │   ├── WorkSessionDetailView.swift
│   │   └── CreateWorkSessionView.swift
│   │
│   ├── AR/
│   │   ├── ARSessionView.swift
│   │   ├── ARViewController.swift
│   │   └── ARViewContainer.swift
│   │
│   └── Components/
│       ├── PresenceIndicator.swift
│       ├── SyncIndicatorView.swift
│       ├── MarkerRowView.swift
│       └── FilterChip.swift
│
├── 🎭 ViewModels/
│   ├── SpaceListViewModel.swift
│   ├── WorkSessionDetailViewModel.swift
│   ├── ARMarkerSessionViewModel.swift
│   └── CollaborativeEditorViewModel.swift
│
├── 🛠️ Utilities/
│   ├── CoordinateMapper.swift           # AR coordinate conversion
│   ├── OptimisticConcurrencyHandler.swift
│   └── Extensions/
│       ├── Color+Hex.swift
│       └── Date+Formatting.swift
│
└── 💾 Persistence/ (Optional)
    ├── CoreDataStack.swift
    ├── OfflineMarkerManager.swift
    └── RoboscopeModel.xcdatamodeld
```

## 🔄 Data Flow Example

### Creating and Visualizing a Marker

```
User Action: Tap in AR View
    ↓
ARViewController.handleTap()
    ↓
Get 3D position from raycast
    ↓
Create CreateMarker object with 4 points
    ↓
Call MarkerService.shared.createMarker()
    ↓
NetworkManager sends POST request
    ↓
Roboscope API creates marker in PostgreSQL
    ↓
API returns Marker with UUID and version
    ↓
Update local markers array
    ↓
ARViewController.visualizeMarker()
    ↓
Create mesh from 4 points
    ↓
Apply material with color
    ↓
Add ModelEntity to AR scene
    ↓
✅ User sees marker in AR!
```

## 🤝 Collaborative Editing Flow

```
User A: Opens Work Session
    ↓
Join presence (PresenceService)
    ├─ Send heartbeat
    └─ Start auto-refresh (10s)
    ↓
Check lock status
    ↓
Lock available? 
    ├─ Yes → Acquire lock (60s TTL)
    │   ├─ Start auto-extension (30s)
    │   └─ Enable editing UI
    └─ No → Show "locked by user" message

User B: Opens Same Session (30s later)
    ↓
Join presence
    ├─ See User A in active users
    └─ Auto-refresh shows 2 users
    ↓
Check lock status
    ↓
Locked by User A
    └─ Disable editing UI
    
User A: Makes Changes
    ↓
Update status to "done"
    ↓
Send PATCH with version number
    ↓
API validates version
    ├─ Match → Update successful ✅
    └─ Mismatch → 409 Conflict ❌
    
User A: Saves and Leaves
    ↓
Release lock
    ↓
Leave presence
    ↓
Stop heartbeat
    
User B: Lock Now Available
    ↓
Auto-refresh detects lock released
    ↓
Can now acquire lock
    └─ Enable editing UI
```

## 🎨 UI Component Hierarchy

```
TabView
│
├─ 📦 Spaces Tab
│   └─ SpaceListView
│       ├─ SpaceRowView (for each space)
│       ├─ EmptyStateView (if no spaces)
│       └─ Sheet: CreateSpaceView
│           └─ Form with text fields
│
├─ 📋 Sessions Tab
│   └─ WorkSessionListView
│       ├─ FilterChips (horizontal scroll)
│       ├─ WorkSessionRowView (for each)
│       │   ├─ Status badge
│       │   ├─ Type label
│       │   └─ Timestamp
│       └─ Sheet: CreateWorkSessionView
│
└─ ⚙️ Settings Tab
    └─ SettingsView
        ├─ API environment picker
        ├─ Cache controls
        └─ About section

From WorkSessionDetailView:
    ↓
Full Screen Cover: ARSessionView
│
├─ ARViewContainer (UIViewControllerRepresentable)
│   └─ ARViewController (UIKit)
│       ├─ ARView (RealityKit)
│       │   ├─ Marker entities
│       │   └─ 3D space model
│       └─ Gesture recognizers
│
└─ Overlay UI (SwiftUI)
    ├─ Top Bar
    │   ├─ Close button
    │   ├─ PresenceIndicator
    │   └─ SyncIndicatorView
    │
    └─ Bottom Controls
        ├─ Marker count
        └─ Action buttons
            ├─ Place marker
            ├─ List markers
            └─ Sync now
```

## 📊 API Call Flow

```
App Launch
    ↓
APIConfiguration.shared.environment = .production
    ↓
SpaceListView appears
    ↓
Task { await loadSpaces() }
    ↓
SpaceService.shared.listSpaces()
    ↓
NetworkManager.request(endpoint: "/spaces")
    ↓
Alamofire.request(url, method: .get)
    ↓
HTTP GET https://api.../api/v1/spaces
    ↓
Response: [Space]
    ↓
JSON → Codable → [Space] objects
    ↓
Update @Published var spaces
    ↓
SwiftUI automatically refreshes List
    ↓
✅ UI shows spaces!
```

## 🎯 Quick Reference

### Where to Find What

| Need | File | Section |
|------|------|---------|
| API setup | `IOS_SWIFT_INTEGRATION_GUIDE.md` | Network Layer |
| Data models | `IOS_SWIFT_INTEGRATION_GUIDE.md` | Data Models |
| AR visualization | `IOS_ARKIT_INTEGRATION.md` | Marker Visualization |
| Presence tracking | `IOS_REALTIME_FEATURES.md` | Presence Tracking |
| Locking | `IOS_REALTIME_FEATURES.md` | Distributed Locking |
| UI examples | `IOS_SWIFTUI_VIEWS.md` | All sections |
| Complete apps | `IOS_CODE_EXAMPLES.md` | All sections |
| Quick snippets | `IOS_QUICKSTART.md` | Essential Code |

### Common Tasks

| Task | Guide | Time |
|------|-------|------|
| Setup network layer | Integration Guide | 30 min |
| Create first view | SwiftUI Views | 20 min |
| Add AR support | ARKit Integration | 2 hours |
| Enable presence | Real-time Features | 30 min |
| Add locking | Real-time Features | 45 min |
| Build complete UI | SwiftUI Views + Examples | 4 hours |
| Add offline mode | Code Examples | 3 hours |

---

**Visual Guide Updated:** October 19, 2025  
**iOS Version:** 17.0+ (iOS 26 compatible)  
**Swift Version:** 5.9+

