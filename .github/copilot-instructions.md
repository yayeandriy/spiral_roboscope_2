# Copilot instructions (roboscope2 iOS)

## Big picture
- SwiftUI app with a Services/Models/ViewModels/Views split under `roboscope2/`.
- Backend is a JSON REST API; networking is centralized in `roboscope2/Services/Network/NetworkManager.swift` + `APIConfiguration.swift` + `APIError.swift`.
- AR features (markers, scanning, laser guide) are RealityKit/ARKit-driven and run on-device.

## Key flows to keep straight
- **Spaces/Sessions list UI** lives under `roboscope2/Views/` and is backed by singleton services like `SpaceService.shared` and `WorkSessionService.shared`.
- **AR session screen**: `roboscope2/Views/ARSessionView.swift` owns AR session lifecycle, loads persisted markers from the backend, and transforms coordinates.
- **Markers have two coordinate systems**:
  - **Backend points** are in *FrameOrigin* coordinates.
  - **RealityKit rendering** uses AR world coordinates.
  - When persisting updates, convert AR world -> FrameOrigin (see `ARSessionViewModel.twoFingerEnd/oneFingerEnd` call sites in `ARSessionView.swift`).

## Project conventions (don’t “generic iOS app” this repo)
- **Services are mostly singletons** (`static let shared`) and are `ObservableObject` with `@Published` state (examples: `SpaceService`, `WorkSessionService`, `MarkerService`, `SyncManager`).
- **Async/await networking** only; `NetworkManager` does not use `convertFromSnakeCase`—models declare explicit `CodingKeys` (example: `roboscope2/Models/Marker.swift`).
- **Optimistic locking**: updates send `version` and the API may return `409 Conflict` (`APIError.conflict`). Marker updates should preserve the versioning story (see `MarkerService.updateMarkerPosition` and `SpatialMarkerService.SpatialMarker.version`).
- **Flexible JSON fields**: `meta`/`customProps` use `AnyCodable`; DTO initializers map `[String: Any]` via `AnyCodable($0)`.

## AR marker implementation notes
- `roboscope2/Services/SpatialMarkerService.swift` is the AR-only marker renderer/state.
- Logic is intentionally split into focused extensions under `roboscope2/Services/Spatial/` (e.g. `+Tracking`, `+Moving`, `+Details`). Prefer adding new marker behavior as a new `SpatialMarkerService+X.swift` extension.
- UI orchestration (timers, gesture side-effects, backend updates) should go through `roboscope2/ViewModels/ARSessionViewModel.swift` rather than bloating views.
- There’s a lightweight DI hook for testing/overrides: `roboscope2/Services/SpatialMarkerService+DI.swift` exposes a static provider (`markerAPIProvider`).

## Laser detection (Swift concurrency gotchas)
- `roboscope2/Services/LaserDetectionService.swift` intentionally uses:
  - `CACurrentMediaTime()` instead of `ARFrame.timestamp` (type/SDK compatibility).
  - `Unmanaged.passRetained(pixelBuffer)` when hopping to a background queue to avoid Swift 6 `Sendable` warnings for `CVPixelBuffer`.
  Keep these patterns if you touch frame processing.

## UI styling/conventions
- Reuse `roboscope2/Views/Common/ARViewContainer.swift` for embedding `ARView`.
- Buttons frequently use the “Liquid Glass” helpers `lgCapsule` / `lgCircle` (defined as `View` extensions in `roboscope2/ContentView.swift`). Use them for consistent look.

## Dev workflows
- Open `roboscope2.xcodeproj` in Xcode; schemes include `roboscope2` and `roboscope2Tests`.
- CLI build/test examples:
  - `xcodebuild -project roboscope2.xcodeproj -scheme roboscope2 -destination 'platform=iOS Simulator,name=iPhone 16' build`
  - `xcodebuild -project roboscope2.xcodeproj -scheme roboscope2Tests -destination 'platform=iOS Simulator,name=iPhone 16' test`
- Unit tests: app startup avoids heavy init when running tests (see `roboscope2/AppDelegate.swift` checking `XCTestConfigurationFilePath`). If you add new startup side-effects, gate them similarly.

## Backend/environment notes
- `APIConfiguration` selects dev/prod in `AppDelegate.swift`. Dev base URL is currently a LAN IP; simulator/device may also require iOS Local Network permission (see `roboscope2/Services/LocalNetworkPermission.swift`).
