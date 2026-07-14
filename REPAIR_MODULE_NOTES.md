# Repair Module — Notes for the Mac Reviewer

Branch: `repair-module` (off `main`). **All iOS code in this branch is UNTESTED** — it was
authored on Windows with no Xcode/device access. Every new file's header says so. Nothing has
been compiled, run, or verified on a simulator or a physical iPhone. Treat this as a diff to
review and build, not as a finished feature.

This module adds a second, independent AR inspection workflow ("Repair") that auto-detects
small objects via a YOLO CoreML model and drops 3D pins at their raycast world position,
persisted to the deployed Veranda API (`https://api.robovision.spiral.technology/v1`). It does
not touch, import, or depend on the existing Laser Guide flow.

## 1. New files to add to the `roboscope2` Xcode target

`project.pbxproj` was not edited (can't run Xcode here). In Xcode: right-click the appropriate
group → **Add Files to "roboscope2"...** → select these, target membership = `roboscope2`.

**`Models/Repair/`** (create group if missing)
- `RepairModels.swift`
- `RepairSettings.swift`

**`Services/Repair/`** (create group if missing)
- `VerandaAPIConfiguration.swift`
- `RepairHTTP.swift`
- `RepairSessionService.swift`
- `PinService.swift`
- `ModelRegistryService.swift`
- `SpaceProxyService.swift`
- `RepairMLDetectionService.swift`
- `RepairMLDetectionService+Decode.swift`
- `RepairMLDetectionService+CoordinateMapping.swift`
- `RepairDetectionPipeline.swift`
- `RepairDetectionMath.swift`
- `RepairModelDownloadService.swift`
- `RepairModelStore.swift`
- `RepairPinRenderer.swift`
- `RepairAutoPlacer.swift`

**`Views/AR/Repair/`** (create group if missing)
- `RepairARSessionView.swift`
- `RepairARSessionView+Logic.swift`
- `RepairDetectionOverlay.swift`
- `RepairDashboardView.swift`

## 2. Modified existing files (additive only — read the diff)

- **`Views/Sessions/SessionsView.swift`** — three small, clearly-commented blocks (each tagged
  `// Repair module entry — additive, does not affect the Laser Guide flow above`):
  1. `@State private var repairSession: WorkSession?`
  2. `.fullScreenCover(item: $repairSession) { RepairDashboardView(session: $0) }`
  3. A new "Repair" swipe action (wrench icon, orange tint) on the session row, alongside the
     existing Delete/Edit actions.

  No other line in this file changed. Verify with:
  ```
  git diff main...repair-module -- roboscope2/Views/Sessions/SessionsView.swift
  ```

- No other existing file was touched. Verified empty diff against the full "never touch" list
  (Laser Guide views, `AnchorService`, `LaserGuideService`, `Services/Spatial/*`,
  `APIConfiguration.swift`):
  ```
  git diff main...repair-module -- roboscope2/Views/AR/LaserGuide roboscope2/Services/Spatial \
    roboscope2/Services/Network/AnchorService.swift roboscope2/Services/Network/LaserGuideService.swift \
    roboscope2/Services/Network/APIConfiguration.swift
  ```
  (empty output = confirmed clean)

## 3. Dependencies

- **No new SPM packages.** `RepairModelDownloadService.swift` reuses the already-vendored
  ZIPFoundation dependency (same pattern as `MLModelDownloadService.swift`). If ZIPFoundation
  isn't already linked into whatever target/scheme is used to build this branch, add it as a
  target dependency — it should already be present since Laser Guide uses it.

## 4. Info.plist / capabilities / entitlements

- **No new Info.plist keys.** Camera usage, local-network usage, and the ARKit capability are
  already declared for the Laser Guide flow and are reused as-is.
- **No new entitlements.**
- **No ATS changes needed** — the Veranda API is HTTPS.

## 5. Networking

- Repair uses its own `VerandaAPIConfiguration` + `RepairHTTP` client, completely separate from
  the existing `APIConfiguration`/`NetworkManager` (which stay wired to the Roboscope API and
  were not modified).
- Base URL is hardcoded to the **deployed prod** Veranda API from day one — no LAN/dev IP:
  `https://api.robovision.spiral.technology/v1`.
- **Known parallel-track dependency:** the `api.robovision.spiral.technology` DNS record is
  being finished by another agent in parallel. If it isn't live yet when you build this, every
  Repair network call will fail DNS resolution — that's expected and not a code bug here.
- Model zip downloads (`RepairModelDownloadService`) hit `CoremlModel.storageUrl` directly via a
  plain `URLSession` GET (no auth headers, no `SpiralStorageService`), per the contract's "public
  GET-able" assumption. A second parallel-track item (web-side storage/CORS + ACL fix) affects
  this — see §6 below.

## 6. Verification steps for the human (do these on a Mac + physical iPhone; agent must not check these)

- [ ] Branch builds in Xcode with the files above added to the target; confirm no changes on `main`.
- [ ] App launches; existing Laser Guide flow is behaviorally identical (hold-to-place origin,
      dot lock, line match, marker persistence, re-scoping, video mode).
- [ ] Repair entry point (swipe action on a session row) appears without disturbing the existing
      Laser Guide / dashboard entry points.
- [ ] `RepairDashboardView` loads the model list from prod Veranda; the default model is
      pre-selected; switching models works.
- [ ] Once a real model is registered and its `storage_url` is confirmed publicly GET-able
      (`curl -I <storage_url>` → 200, not 403 — this depends on the storage ACL fix landing),
      the model downloads, unzips, compiles, and caches under `MLModels/repair/<file_hash>/`.
- [ ] AR session starts; if the debug overlay is toggled on, detection boxes align to the camera
      feed under device rotation and at different distances (validates the copied transform).
- [ ] Auto-placement: point the camera at a real small object — it should get **exactly one** red
      pin after roughly `repairConfirmThreshold` (default 15) frames of consistent detection.
      No floating pins should appear on a raycast miss. Two objects placed within 5 cm of each
      other should collapse to one pin; objects farther apart should each get their own pin.
- [ ] Placed pins POST to Veranda (bulk-flushed periodically) and are visible in the Robovision
      web app under the session's detail page.
- [ ] Tap-to-delete: tapping an existing pin removes it locally and deletes it server-side.
- [ ] Exiting the AR session flushes any still-buffered pins and closes the session
      (`status` transitions to `"closed"`).
- [ ] Tune the `repair*` constants in `RepairSettings` against real detector behavior on-device
      and record whatever values end up working well (window size, confirm threshold, dedup
      radius, IoU threshold, flush interval).

## 7. Design notes / things a reviewer may want to double-check

- `RepairAutoPlacer` (the core algorithm) is pure Swift + `simd`, with **no ARKit/RealityKit
  import** — it takes raw per-frame detections and a `raycast` closure injected by
  `RepairARSessionView+Logic`. This was deliberate so the state machine (association → temporal
  confirm → ambiguity reset → dedup → place) could in principle be unit-tested without a device,
  though no test target was set up here (out of scope / no Xcode).
- `RepairDashboardView` reads the local `WorkSession`'s `spaceId`/space name (via the existing,
  generic `SpaceService`) rather than round-tripping through the Veranda spaces proxy at
  session-start time. `SpaceProxyService.swift` still exists and works against
  `GET /v1/spaces` / `GET /v1/spaces/{id}` for cases where browsing the Veranda-side space list
  independently is useful later.
- Segmentation/mask/oriented-quad logic from the Laser Guide detection stack was intentionally
  dropped when copying — Repair only needs point/bbox detections for pin placement.
