# iOS Swift Integration - Complete Documentation

Comprehensive guides for integrating the Roboscope 2 API into iOS 17+ apps with Swift and ARKit support.

## 📱 Overview

The Roboscope 2 API provides a complete backend for AR-enabled spatial work session management. These guides help you build a production-ready iOS app with:

- ✅ Spatial environment management (Spaces)
- ✅ Work session tracking with versioning
- ✅ AR marker visualization with ARKit/RealityKit
- ✅ Real-time presence tracking
- ✅ Distributed locking for collaboration
- ✅ Offline-first architecture
- ✅ SwiftUI & Combine integration

## 🚀 Quick Start

**New to the project?** Start here:

### [iOS Quick Start Guide →](./IOS_QUICKSTART.md)
5-minute setup guide with essential code snippets and common patterns.

**Includes:**
- Package dependencies
- API configuration
- Quick test connection
- Essential code snippets
- Common issues & solutions

## 📚 Complete Documentation

### 1. [iOS Swift Integration Guide](./IOS_SWIFT_INTEGRATION_GUIDE.md)
**Main integration guide** covering:
- Project setup and configuration
- Network layer implementation
- Data models (Space, WorkSession, Marker)
- API services (SpaceService, WorkSessionService, MarkerService)
- Error handling
- Best practices

**Who needs this:** All iOS developers integrating the API

### 2. [ARKit Integration Guide](./IOS_ARKIT_INTEGRATION.md)
**AR marker visualization** with ARKit/RealityKit:
- ARKit session setup
- 3D marker visualization
- Gesture interactions (tap to place, long press to select)
- 3D model loading (GLB/USDC)
- Coordinate system mapping
- Performance optimization
- Spatial anchor persistence

**Who needs this:** Developers implementing AR features

### 3. [Real-time Features Guide](./IOS_REALTIME_FEATURES.md)
**Presence tracking & collaborative locking:**
- Real-time presence tracking with heartbeats
- Distributed locking for safe editing
- Optimistic concurrency control
- Conflict resolution strategies
- Auto-sync implementation
- Background updates

**Who needs this:** Apps with multi-user collaboration

### 4. [SwiftUI Views Guide](./IOS_SWIFTUI_VIEWS.md)
**Pre-built UI components:**
- Space management views (list, create, detail)
- Work session views (list, create, edit)
- Marker management views
- View models with Combine
- Reusable components
- Loading & error states

**Who needs this:** SwiftUI developers

### 5. [Complete Code Examples](./IOS_CODE_EXAMPLES.md)
**Full working implementations:**
- Complete app structure
- Space management workflow
- AR marker session (complete)
- Collaborative editing with locking
- Offline support with CoreData
- Background sync

**Who needs this:** Everyone (reference implementations)

## 🎯 Implementation Roadmap

### Phase 1: Basic Integration (1-2 days)
1. ✅ Setup project dependencies
2. ✅ Implement network layer
3. ✅ Add data models
4. ✅ Create API services
5. ✅ Build basic Space list view
6. ✅ Test CRUD operations

**Guide:** [iOS Swift Integration Guide](./IOS_SWIFT_INTEGRATION_GUIDE.md)

### Phase 2: AR Features (2-3 days)
1. ✅ Setup ARKit session
2. ✅ Implement marker visualization
3. ✅ Add tap gesture for placement
4. ✅ Load 3D space models
5. ✅ Test marker sync

**Guide:** [ARKit Integration Guide](./IOS_ARKIT_INTEGRATION.md)

### Phase 3: Collaboration (1-2 days)
1. ✅ Add presence tracking
2. ✅ Implement distributed locking
3. ✅ Handle version conflicts
4. ✅ Add auto-sync
5. ✅ Test multi-user scenarios

**Guide:** [Real-time Features Guide](./IOS_REALTIME_FEATURES.md)

### Phase 4: Polish (1-2 days)
1. ✅ Build complete UI
2. ✅ Add offline support
3. ✅ Implement error handling
4. ✅ Performance optimization
5. ✅ User testing

**Guides:** [SwiftUI Views](./IOS_SWIFTUI_VIEWS.md) + [Code Examples](./IOS_CODE_EXAMPLES.md)

## 📋 Requirements

### Development Environment
- **Xcode**: 15.0+ (for iOS 17+ support)
- **Swift**: 5.9+
- **iOS Deployment Target**: 17.0+ (iOS 26 ready)
- **macOS**: Sonoma 14.0+ (for Xcode 15)

### Frameworks
- `Foundation` - Core Swift functionality
- `SwiftUI` - Modern declarative UI
- `Combine` - Reactive programming
- `ARKit` - Augmented reality
- `RealityKit` - 3D rendering
- `CoreData` - Local persistence (optional)

### Dependencies
- **Alamofire** 5.8+ - HTTP networking
- **Starscream** 4.0+ - WebSocket (optional, for future real-time updates)

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────┐
│           SwiftUI Views                  │
│  (SpaceList, ARSession, etc.)           │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│          View Models                     │
│  (@Published properties, Combine)       │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│           Services Layer                 │
│  SpaceService, MarkerService, etc.      │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│        Network Manager                   │
│  (Alamofire, generic request methods)   │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│         Roboscope 2 API                  │
│  (Rust + Axum + PostgreSQL + Redis)     │
└─────────────────────────────────────────┘
```

## 🔗 API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/spaces` | GET, POST | List/create spaces |
| `/spaces/{id}` | GET, PATCH, DELETE | Space operations |
| `/work-sessions` | GET, POST | List/create sessions |
| `/work-sessions/{id}` | GET, PATCH, DELETE | Session operations |
| `/markers` | GET, POST | List/create markers |
| `/markers/{id}` | GET, PATCH, DELETE | Marker operations |
| `/markers/bulk` | POST | Bulk create markers |
| `/presence/{session_id}` | GET, POST, DELETE | Presence tracking |
| `/locks/{session_id}` | GET, POST, DELETE | Lock management |
| `/events` | GET | Audit trail |

**Full API documentation:** [OpenAPI Spec](../static/openapi.json)

## 🌐 Server Environments

### Development
```
http://localhost:8080/api/v1
```
Run local server: `cargo run` in API project

### Production
```
https://spiralroboscope2backend-production.up.railway.app/api/v1
```
Auto-deployed from main branch

## 💡 Key Concepts

### 1. Spaces
Physical or virtual environments where work happens. Each space can have:
- 3D models (GLB/USDC formats)
- Multiple work sessions
- Custom metadata

### 2. Work Sessions
Instances of work within a space. Features:
- Status tracking (draft → active → done → archived)
- Type classification (inspection, repair, other)
- Optimistic locking with version numbers
- Associated markers

### 3. Markers
AR annotations in 3D space. Each marker:
- Has 4 points defining a rectangular region
- Belongs to one work session
- Can have labels and colors
- Supports bulk creation

### 4. Presence Tracking
Know who's viewing/editing:
- Heartbeat-based (10s intervals)
- Auto-cleanup on disconnect
- Real-time user list

### 5. Distributed Locks
Safe collaborative editing:
- TTL-based expiry
- Auto-extension
- Token-based release

## 🧪 Testing Your Integration

### 1. Health Check
```swift
let health = try await NetworkManager.shared.request(
    endpoint: "/health"
)
print(health) // Should show "healthy"
```

### 2. Create Test Space
```swift
let space = try await SpaceService.shared.createSpace(
    CreateSpace(
        key: "test-space",
        name: "Test Space",
        description: "iOS integration test",
        modelGlbUrl: nil,
        modelUsdcUrl: nil,
        previewUrl: nil
    )
)
```

### 3. Create Work Session
```swift
let session = try await WorkSessionService.shared.createWorkSession(
    CreateWorkSession(
        spaceId: space.id,
        sessionType: .inspection,
        status: .active,
        startedAt: Date(),
        completedAt: nil
    )
)
```

### 4. Test AR Marker
```swift
let marker = try await MarkerService.shared.createMarker(
    CreateMarker(
        workSessionId: session.id,
        label: "Test Marker",
        points: [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(0.1, 0, 0),
            SIMD3<Float>(0.1, 0, 0.1),
            SIMD3<Float>(0, 0, 0.1)
        ],
        color: "#FF0000"
    )
)
```

## 📖 Additional Resources

### Backend Documentation
- [Main README](../README.md) - Backend overview
- [API Constitution](./constitution/API.md) - API design principles
- [Database Schema](./constitution/Database.md) - PostgreSQL schema
- [Redis Features](./REDIS_FEATURES.md) - Caching & real-time features

### Related Guides
- [Next.js Integration](./NEXTJS_INTEGRATION_GUIDE.md) - Web client integration
- [Railway Deployment](./features/RAILWAY_DEPLOYMENT.md) - Deploy the backend
- [Local Development](./LOCAL_DEV_SETUP.md) - Run backend locally

## 🐛 Troubleshooting

### Common Issues

**Problem:** Can't connect to API
```swift
// Check environment
print(APIConfiguration.shared.baseURL)

// Test network
curl https://spiralroboscope2backend-production.up.railway.app/api/v1/health
```

**Problem:** 409 Conflict on update
```swift
// Always include version
let update = UpdateWorkSession(
    status: .done,
    version: currentSession.version // ← Don't forget!
)
```

**Problem:** Markers not appearing in AR
```swift
// Check coordinate scale (ARKit uses meters)
print(marker.p1) // Should be reasonable values like [0.1, 0, 0.5]
```

**Problem:** Lock keeps expiring
```swift
// Use longer TTL or rely on auto-extension
let acquired = try await LockService.shared.acquireLock(
    sessionId: sessionId,
    ttl: 120 // 2 minutes instead of default 30s
)
```

## 💬 Support

- **GitHub Issues:** [spiral_roboscope_2_backend](https://github.com/yayeandriy/spiral_roboscope_2_backend/issues)
- **API Health:** `GET /health`
- **API Docs:** Visit root URL in browser for OpenAPI UI

## 📄 License

This documentation and associated code examples are provided as-is for integration with the Roboscope 2 API.

---

**Ready to start?** 👉 [Quick Start Guide](./IOS_QUICKSTART.md)

**Need help?** Open an issue or check the troubleshooting section above.

