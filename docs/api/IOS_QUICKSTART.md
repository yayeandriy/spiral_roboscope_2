# iOS Integration - Quick Start Guide

Quick reference guide for integrating the Roboscope 2 API into your iOS app.

## Overview

This is a condensed guide for experienced iOS developers. For detailed explanations, see the comprehensive guides.

## Quick Setup (5 Minutes)

### 1. Add Dependencies

**Package.swift** or **Xcode → Add Package Dependencies**:
```
https://github.com/Alamofire/Alamofire.git (5.8.0+)
```

### 2. Copy Base Files

Create these files in your project:

```
YourApp/
├── Network/
│   ├── APIConfiguration.swift
│   ├── NetworkManager.swift
│   └── APIError.swift
├── Models/
│   ├── Space.swift
│   ├── WorkSession.swift
│   ├── Marker.swift
│   └── AnyCodable.swift
├── Services/
│   ├── SpaceService.swift
│   ├── WorkSessionService.swift
│   ├── MarkerService.swift
│   ├── PresenceService.swift
│   └── LockService.swift
└── Views/
    ├── SpaceListView.swift
    ├── WorkSessionDetailView.swift
    └── ARSessionView.swift
```

### 3. Configure API

```swift
// In your App.swift or SceneDelegate
APIConfiguration.shared.environment = .production
// or .development for localhost
```

### 4. Test Connection

```swift
Task {
    let spaces = try await SpaceService.shared.listSpaces()
    print("✅ Connected! Found \(spaces.count) spaces")
}
```

## Essential Code Snippets

### Fetch All Spaces

```swift
let spaces = try await SpaceService.shared.listSpaces()
```

### Create a Work Session

```swift
let session = try await WorkSessionService.shared.createWorkSession(
    CreateWorkSession(
        spaceId: spaceId,
        sessionType: .inspection,
        status: .active,
        startedAt: Date(),
        completedAt: nil
    )
)
```

### Create AR Marker

```swift
let marker = try await MarkerService.shared.createMarker(
    CreateMarker(
        workSessionId: sessionId,
        label: "Issue Here",
        points: [point1, point2, point3, point4], // SIMD3<Float>
        color: "#FF0000"
    )
)
```

### Join Presence

```swift
try await PresenceService.shared.joinSession(sessionId)
// Auto heartbeat every 10s
// Don't forget to call leaveSession() on cleanup
```

### Acquire Lock for Editing

```swift
let acquired = try await LockService.shared.acquireLock(
    sessionId: sessionId,
    ttl: 60 // seconds
)
if acquired {
    // You can now edit safely
}
```

## Common Patterns

### SwiftUI List View

```swift
struct SpacesView: View {
    @State private var spaces: [Space] = []
    
    var body: some View {
        List(spaces) { space in
            Text(space.name)
        }
        .task {
            spaces = try await SpaceService.shared.listSpaces()
        }
    }
}
```

### Error Handling

```swift
do {
    let result = try await someAPICall()
} catch let error as APIError {
    switch error {
    case .conflict:
        // Handle version conflict
    case .notFound:
        // Handle not found
    default:
        // Show generic error
    }
}
```

### Optimistic Updates

```swift
let update = UpdateWorkSession(
    status: .done,
    version: currentSession.version // Include version!
)
try await WorkSessionService.shared.updateWorkSession(
    id: sessionId,
    update: update
)
```

## API Endpoints Reference

| Resource | GET | POST | PATCH | DELETE |
|----------|-----|------|-------|--------|
| `/spaces` | List all | Create | - | - |
| `/spaces/{id}` | Get one | - | Update | Delete |
| `/work-sessions` | List all | Create | - | - |
| `/work-sessions/{id}` | Get one | - | Update | Delete |
| `/markers` | List all | Create | - | - |
| `/markers/{id}` | Get one | - | Update | Delete |
| `/markers/bulk` | - | Bulk create | - | - |
| `/presence/{session_id}` | List users | Heartbeat | - | Leave |
| `/locks/{session_id}` | Check status | Acquire | - | Release |

## Environment URLs

```swift
Development:  http://localhost:8080/api/v1
Production:   https://spiralroboscope2backend-production.up.railway.app/api/v1
```

## ARKit Integration

```swift
import ARKit
import RealityKit

// Visualize marker in AR
func visualizeMarker(_ marker: Marker) {
    let points = marker.points // [SIMD3<Float>]
    let mesh = createQuadMesh(from: points)
    let entity = ModelEntity(mesh: mesh)
    arView.scene.addAnchor(AnchorEntity(world: points[0]))
}
```

## Real-time Features

### Presence Tracking

```swift
// Join session (auto-heartbeat every 10s)
try await PresenceService.shared.joinSession(sessionId)

// Get active users
let users = presenceService.activeUsers // Published property
```

### Distributed Locking

```swift
// Acquire lock (auto-extend before expiry)
let acquired = try await LockService.shared.acquireLock(
    sessionId: sessionId,
    ttl: 60
)

// Release when done
try await LockService.shared.releaseLock(sessionId: sessionId)
```

## Common Issues

### Issue: "Connection refused"
**Solution**: Check `APIConfiguration.shared.environment` is correct

### Issue: "409 Conflict" on update
**Solution**: Include `version` field in update request

### Issue: Markers not appearing in AR
**Solution**: Ensure coordinate systems match (ARKit uses meters)

### Issue: Lock acquired but can't edit
**Solution**: Lock expires after TTL - extend or re-acquire

## Performance Tips

1. **Batch marker operations**: Use `/markers/bulk` for multiple markers
2. **Cache locally**: Store spaces/sessions in UserDefaults or CoreData
3. **Debounce presence**: Don't update too frequently (use built-in 10s heartbeat)
4. **Limit AR markers**: Only render markers within 10m of camera

## Sample Project Structure

```swift
@main
struct RoboscopeApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                SpaceListView()
                    .tabItem { Label("Spaces", systemImage: "cube") }
                
                WorkSessionListView()
                    .tabItem { Label("Sessions", systemImage: "list.bullet") }
            }
        }
    }
}
```

## Testing

```swift
// Test in Xcode Previews
struct SpaceListView_Previews: PreviewProvider {
    static var previews: some View {
        SpaceListView()
    }
}

// Test API calls
func testSpaceService() async throws {
    let spaces = try await SpaceService.shared.listSpaces()
    XCTAssertFalse(spaces.isEmpty)
}
```

## Full Documentation

For complete implementation details:

1. **[Main Integration Guide](./IOS_SWIFT_INTEGRATION_GUIDE.md)** - Network layer, models, services
2. **[ARKit Integration](./IOS_ARKIT_INTEGRATION.md)** - AR marker visualization
3. **[Real-time Features](./IOS_REALTIME_FEATURES.md)** - Presence & locking
4. **[SwiftUI Views](./IOS_SWIFTUI_VIEWS.md)** - Pre-built UI components
5. **[Code Examples](./IOS_CODE_EXAMPLES.md)** - Complete working examples

## API Documentation

- **OpenAPI Spec**: `/static/openapi.json`
- **Interactive Docs**: Open `https://your-api-url/` in browser
- **Health Check**: `GET /health`

## Support

- GitHub Issues: https://github.com/yayeandriy/spiral_roboscope_2_backend/issues
- API Status: `GET /health`

---

**Quick Links:**
- [Backend README](../README.md)
- [API Architecture](./constitution/API.md)
- [Database Schema](./constitution/Database.md)
- [Redis Features](./REDIS_FEATURES.md)

