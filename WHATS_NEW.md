# What's New

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
