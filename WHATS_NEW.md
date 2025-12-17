# What's New

## Version [Current Version]

### Enhanced Marker Display & Accuracy

**Improved Marker Badge**
- Added collapsible nodes section showing precise p1-p4 coordinates with color-coded x, y, z values
- Marker ID now displayed at the bottom for easy reference
- Calibrated center only shown when it differs from raw measurements, reducing visual clutter

**Fixed Coordinate System**
- Corrected marker coordinate calculations to use Frame Origin reference system
- Raw center and node coordinates now accurately reflect stored server values
- Fixed width/length calculations to properly align with X and Z axes

**Real-Time Calibration Updates**
- Calibrated data automatically refreshes when markers are moved or resized
- Improved synchronization between local display and server-calculated metrics
- Faster updates with optimized single-network-call approach

**Technical Improvements**
- Width measurements now correctly represent X-axis extent (cross direction)
- Length measurements now correctly represent Z-axis extent (longitudinal direction)
- Frame-origin coordinates preserved during all marker transformations
- Enhanced data integrity with proper coordinate system handling

This update ensures your spatial measurements are accurate and clearly presented, making it easier to work with precision marker data in AR space.
