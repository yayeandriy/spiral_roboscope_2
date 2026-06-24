# What's New

## Version 2.2.7

### LaserGuide Origin Placement — Improved Algorithm & Settings

- **Two-phase detection**: the placement algorithm now separately locks the dot first, then waits for the line — no longer requires both in the same frame, making placement far more reliable
- **Removed proximity gate**: the 150 px screen-centre gate that was blocking valid detections is gone
- **Y-delta check toggle**: Settings → Detection lets you turn off the vertical alignment guard when the laser dot and line are at different heights
- **Segment tolerance slider**: adjust the 3D distance tolerance for segment matching (1–20 cm) directly in Settings
- **Robust raycasting**: added `existingPlaneInfinite` as a third raycast fallback for rooms where ARKit hasn't fully mapped the planes yet; NaN results from degenerate raycasts are now filtered before reaching RealityKit (fixes crash)
- **"by Spiral" on splash screen**: subtle attribution added to the bottom of both splash screen variants
- **Removed Video Mode toggle** from Settings (the feature is still available via the session flow)
- **~50 compiler warnings resolved** across the codebase (deprecated API migrations, unused variables, concurrency annotations)

## Version 2.2.6

### AR Origin Placement — Live Dot Indicator

- When scanning for the origin, a small red cone now appears at the laser dot's 3D position the moment it is detected — giving immediate visual confirmation before the line is found
- The cone is placed through both the per-frame and overlay detection paths, so it works on every placement attempt including replacements
- The cone is removed automatically once the origin snaps into place or the button is released

## Version 2.2.5

### ML Model Download Fix

- Fixed 403 error when downloading ML models from S3 storage
- Model downloads now route through SpiralStorage presigned URL API for authenticated access
- Added `resolveDownloadURL` to SpiralStorageService for transparent S3 key-to-presigned-URL resolution
