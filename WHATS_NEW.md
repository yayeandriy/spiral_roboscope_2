# What's New

## Version 2.2.3

### Hold-to-Place Origin in LaserGuide AR

**New Placement Button**
- Replaced the origin placement badge with a large hold-to-place button at the bottom-right corner
- Button styled like the record button with two states: idle (green-ringed circle with scale.3d icon) and held (filled green square)
- Placement starts only while the button is held; releasing stops detection immediately

**Smarter Origin Lifecycle**
- If a previous origin was placed, it's preserved until a new one is successfully set
- During placement, previous origin and anchor are hidden; restored if placement fails
- Markers and plus button are hidden during active placement for a cleaner view

**Onboarding & Info**
- Instruction block at bottom-left guides first-time users: "Hold the button to start origin placement"
- Space Info overlay (checkmark menu) shows: Space name, ML model filename, input size, classes, update dates, and collapsible Laser Grid table
- Laser Grid table lists all segments with X, Z, and length values

**Menu Cleanup**
- "Restart Placing" removed from checkmark menu (replaced by hold-to-place flow)
- "Manual Two Points" added to checkmark menu for quick access
