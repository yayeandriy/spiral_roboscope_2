# Marker `calibrated_data` Field

Minimal description of the `markers.calibrated_data` field: its name, format, and data structure.

## Field

- Table: `markers`
- Column: `calibrated_data` (JSON / JSONB)
- Nullable: yes

## Format

- JSON object with five properties: `p1`, `p2`, `p3`, `p4`, `center`
- Each property is an array of three numbers: `[x, y, z]`
- Coordinate order: XYZ
- Units: meters

## Data Structure

```
{
  "p1": [number, number, number],
  "p2": [number, number, number],
  "p3": [number, number, number],
  "p4": [number, number, number],
  "center": [number, number, number]
}
```

Example:

```
{
  "p1": [1.5, 0.0, -2.3],
  "p2": [2.5, 0.0, -2.3],
  "p3": [2.5, 0.0, -1.3],
  "p4": [1.5, 0.0, -1.3],
  "center": [2.0, 0.0, -1.8]
}
```
