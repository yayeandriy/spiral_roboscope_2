# Roboscope 2 iOS — Sprint 2 Functionality (Comprehensive)

## Overview
This document captures what shipped in Sprint 2 for the Roboscope 2 iOS app: the user-facing capabilities, technical implementation, updated architecture, and verification guidance. It links to the deeper API and feature docs already maintained in this repository.

Development period: Oct 27 – Nov 3, 2025  
Repository: spiral_roboscope_2  
Scope: Registration pipeline stabilization, space/session scanning flows, marker system v2, settings expansion, storage hardening, and modularization via ScanRegistrationKit.

---

## What shipped in Sprint 2

- End-to-end Session Scan Registration flow, including transform correctness and alignment refinements
- Frame dimensions detection and alignment aids (gizmos, axes, grid) for accurate placement
- Model Registration pipeline hardening (Umeyama + Manhattan variants) and transform fix
- Space AR scanning stabilization and USDC asset flow improvements
- Storage integration hardening for scans and models
- Local network permission UX and lifecycle handling
- Settings system expanded with scan/registration presets
- Spatial Markers v2: stability, consistency, and clearer visual references
- Extracted registration and utilities into a Swift package: ScanRegistrationKit

See also:
- Features: `docs/features/`
	- [Alignment Feature](../features/ALIGNMENT_FEATURE.md)
	- [Registration Transform Fix](../features/REGISTRATION_TRANSFORM_FIX.md)
	- [Frame Dims Algorithms](../features/FRAME_DIMS_ALGORITHMS.md)
	- [Frame Dims Implementation](../features/FRAME_DIMS_IMPLEMENTATION.md)
	- [Session Scan Registration](../features/SESSION_SCAN_REGISTRATION.md)
	- [Space AR Scanning](../features/SPACE_AR_SCANNING.md)
	- [Storage Integration](../features/STORAGE_INTEGRATION.md)
	- [Settings System](../features/SETTINGS_SYSTEM.md)
	- [Local Network Permission](../features/LOCAL_NETWORK_PERMISSION.md)
	- [Marker Frame Dims](../features/MARKER_FRAME_DIMS.md)
	- [Mesh Algorithm](../features/MESH_ALGO.md)
	- [Model Registration](../features/MODEL_REGISTRATION.md)
	- [Design Principles](../features/DESIGN_PRINCIPLES.md)
- API docs: `docs/api/`
	- [ARKit Integration](../api/IOS_ARKIT_INTEGRATION.md)
	- [Swift Integration Guide](../api/IOS_SWIFT_INTEGRATION_GUIDE.md)
	- [SwiftUI Views](../api/IOS_SWIFTUI_VIEWS.md)
	- [Realtime Features](../api/IOS_REALTIME_FEATURES.md)
	- [Documentation Summary](../api/IOS_DOCUMENTATION_SUMMARY.md)
	- [Quickstart](../api/IOS_QUICKSTART.md)

---

## User flows (UAT-ready)

### 1) Space scanning and model export (USDC)
Goal: Capture a room scan and persist/export a USDC model for later alignment.
1. Open the Space AR view.
2. Scan your environment following the on-screen guidance; keep a steady pace and adequate lighting.
3. Save the scan. The app exports a USDC asset and persists metadata via Storage API.
4. Verify the USDC shows in the space card and is viewable in the 3D viewer.

References: [Space AR Scanning](../features/SPACE_AR_SCANNING.md), [Storage Integration](../features/STORAGE_INTEGRATION.md)

### 2) Session scan and registration to reference
Goal: Align a live session scan to a previously captured reference model.
1. Create/select a Work Session.
2. Start a session scan; place the registration gizmo in the approximate reference pose.
3. Choose alignment algorithm (Umeyama or Manhattan) in Settings if applicable.
4. Apply registration. The model transforms to align with the reference USDC.
5. Validate placement via grid/axes overlays; tweak if needed.

References: [Session Scan Registration](../features/SESSION_SCAN_REGISTRATION.md), [Alignment Feature](../features/ALIGNMENT_FEATURE.md)

### 3) Spatial markers workflow
Goal: Place, move, save, and remove markers with consistent frame dimensions.
1. Enter marker mode from the session.
2. Tap to place markers; drag to reposition; use edge/whole-move modes as needed.
3. Save markers; confirm persistence and correct count display.
4. Delete markers; validate state and visuals refresh.

References: [Marker Frame Dims](../features/MARKER_FRAME_DIMS.md), [Marker Visual Reference](../features/MARKER_BADGE_VISUAL_REFERENCE.md)

### 4) Model placement and visualization
Goal: View and place USDC models accurately within the scene.
1. Load USDC model into the scene (OBJ support intentionally not enabled; USDC is the supported path).
2. Use overlays (grid, axes) to verify orientation and scale.
3. Adjust placement with gizmo aids.

References: [Model Registration](../features/MODEL_REGISTRATION.md), [Mesh Algorithm](../features/MESH_ALGO.md)

### 5) Settings and presets
Goal: Configure scanning and registration behavior.
1. Open Settings.
2. Adjust scan density, registration thresholds, alignment strategy, and display presets.
3. Re-run registration with new presets to validate effect.

Reference: [Settings System](../features/SETTINGS_SYSTEM.md)

### 6) Permissions (Local Network)
Goal: Ensure local networking features can function where required.
1. Trigger the Local Network permission prompt via onboarding or feature entry.
2. Verify positive/negative paths and re-entry UX if denied.

Reference: [Local Network Permission](../features/LOCAL_NETWORK_PERMISSION.md)

---

## Technical implementation

### Core models
Located in `roboscope2/Models/`
- `Space.swift` — metadata for scanned spaces and associated assets
- `WorkSession.swift` — sessions and their scanning/registration state
- `Marker.swift` — spatial marker data and edit modes
- `AppSettings.swift` — persisted app-level settings and presets
- `PresenceModels.swift` — structures supporting presence/collab (if enabled)
- Assets: `room.usdc` and datasets for local dev/demo

### Services (selected)
Located in `roboscope2/Services/`
- `CaptureSession.swift` — AR capture pipeline (frames, point clouds, meshes)
- `ModelRegistrationService.swift` — registration strategies (Umeyama, Manhattan), transform computation, and application
- `SpatialMarkerService.swift` (+ `SpatialMarkerService+DI.swift`) — marker lifecycle, DI wiring
- `SpaceService.swift` — space CRUD, scan persistence, asset binding
- `WorkSessionService.swift` — session lifecycle and orchestration
- `Storage` and `Network/` — persistence and backend integration
- `SyncManager.swift`, `LockService.swift` — concurrency/coordination (when realtime features are enabled)
- `LocalNetworkPermission.swift` — permission prompting and state

References: [iOS Swift Integration Guide](../api/IOS_SWIFT_INTEGRATION_GUIDE.md), [iOS SwiftUI Views](../api/IOS_SWIFTUI_VIEWS.md)

### ScanRegistrationKit (Swift Package)
Location: `docs/ScanRegistrationKit/` (package documentation), package source under `docs/ScanRegistrationKit/Sources/`
- Purpose: Isolate registration algorithms and helpers for reuse and testability
- Contents: alignment utilities, transforms/math primitives, algorithm adapters
- Benefit: Clearer boundaries, easier unit testing, and future reuse across apps

Reference: `docs/ScanRegistrationKit/README.md`

### Algorithms
- Umeyama alignment — robust point-set alignment baseline
- Manhattan alignment — axis-constrained alignment leveraging scene orthogonality
- Frame dims detection — heuristics/analysis for frame extents and origin fixes

References: [Alignment Feature](../features/ALIGNMENT_FEATURE.md), [Frame Dims Algorithms](../features/FRAME_DIMS_ALGORITHMS.md)

### Transform correctness
Sprint 2 focused on ensuring transforms are consistent across:
- Scene origin vs. model origin (and predictable offsetting)
- Consistent axes definitions between ARKit and RealityKit
- Applying transforms to models and markers without drift or double-applying

Reference: [Registration Transform Fix](../features/REGISTRATION_TRANSFORM_FIX.md)

---

## API and integration
The app uses a Storage and REST layer for persisting spaces, sessions, markers, and assets. See:
- [iOS API Index](../api/IOS_INDEX.md)
- [Storage Integration](../features/STORAGE_INTEGRATION.md)
- [Documentation Summary](../api/IOS_DOCUMENTATION_SUMMARY.md)

Key integration points:
- Upload and retrieval of USDC assets for scanned spaces
- Session CRUD and state transitions
- Marker persistence tied to sessions/spaces

Note: Exact endpoints and payloads are defined in the API docs under `docs/api/`.

---

## Configuration and settings
Settings expanded in Sprint 2 to make scanning and registration predictable and tunable:
- Scan density and mesh quality
- Alignment algorithm selection (Umeyama vs. Manhattan)
- Registration thresholds and inlier ratios (where supported)
- Display presets (grid/axes overlays, marker visuals)

Reference: [Settings System](../features/SETTINGS_SYSTEM.md)

---

## Verification and QA

Smoke/UAT checklist:
- Space scanning saves a USDC asset and displays it in the space card
- Session scan runs, registration applies, and the model aligns to reference with correct origin
- Markers can be added, moved (edge/whole), saved, and deleted; counts update reliably
- Settings changes affect registration behavior as expected
- Local network permission flows are handled gracefully (allow/deny/re-prompt UX)

Visual/interaction references:
- [Marker Badge Visual Reference](../features/MARKER_BADGE_VISUAL_REFERENCE.md)
- [Collision Debug Checklist](../features/COLLISION_DEBUG_CHECKLIST.md)

Automation and modular testing:
- Registration math and utilities are placed in ScanRegistrationKit for isolated tests
- Consider unit tests around transform application and tolerance thresholds

---

## Known limitations (as of Nov 3, 2025)
- OBJ model placement is not supported; USDC is the primary format
- Registration may require adequate scene features and lighting; edge cases exist in low-feature areas
- Realtime presence/sync is scoped; large sessions may need pagination or throttling

---

## Developer notes

Entry points:
- App: `roboscope2/AppDelegate.swift`, `roboscope2/ContentView.swift`
- Views: see `roboscope2/Views/` and `docs/api/IOS_SWIFTUI_VIEWS.md`
- Services: `roboscope2/Services/`
- Models and sample assets: `roboscope2/Models/`

Handy docs:
- [iOS Quickstart](../api/IOS_QUICKSTART.md)
- [iOS Visual Guide](../api/IOS_VISUAL_GUIDE.md)
- [ARKit Application Guide](../features/ARKIT_APPLICATION_GUIDE.md)

---

## Next steps (targeted for Sprint 3)
- Deeper unit/integration coverage for ScanRegistrationKit
- Calibration UI polish and guided alignment workflow
- Presence and multi-user sync hardening (if in scope)
- Performance profiling on older devices; mesh density auto-tuning
- Export/share flows for sessions and spaces

---

## Appendix: File map (selected)
- Models: `roboscope2/Models/Space.swift`, `WorkSession.swift`, `Marker.swift`, `AppSettings.swift`, `PresenceModels.swift`, `room.usdc`
- Services: `CaptureSession.swift`, `LocalNetworkPermission.swift`, `LockService.swift`, `MarkerService.swift`, `ModelRegistrationService.swift`, `PresenceService.swift`, `SpaceService.swift`, `SpatialMarkerService.swift`, `SpatialMarkerService+DI.swift`, `SyncManager.swift`, `WorkSessionService.swift`, `Services/Network/*`, `Services/Protocols/*`
- Package: `docs/ScanRegistrationKit/Package.swift`, `docs/ScanRegistrationKit/README.md`, `docs/ScanRegistrationKit/Sources/*`, `docs/ScanRegistrationKit/Tests/*`

If any link above is broken, search the corresponding folder for the exact filename; some docs may evolve but the concepts and flows remain consistent.

