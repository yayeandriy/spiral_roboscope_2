# App Store - What's New
# (4000 character limit for What's New section)

## Version 2.2.7

LaserGuide Placement Improvements & Stability

• Origin placement now works in two phases — dot is locked first, then the line is found — no longer requires both in the same frame, making placement much more reliable
• Removed screen-centre proximity gate that was blocking valid detections
• New Settings › Detection section: toggle Y-delta alignment check and adjust segment tolerance (1–20 cm)
• More robust raycasting with an additional infinite-plane fallback; NaN crash from degenerate raycast results is fixed
• "by Spiral" attribution added to the splash screen
• Resolved ~50 compiler warnings; general stability improvements

## Version 2.2.6

AR Origin Placement — Live Dot Indicator

• A small red cone now appears at the laser dot's 3D position the moment it is detected — immediate visual confirmation before the line is found

## Version 2.2.5

ML Model Download Fix

• Fixed 403 error when downloading ML models — now uses authenticated presigned URLs via SpiralStorage
