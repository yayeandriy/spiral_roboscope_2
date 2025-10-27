Marker Frame Dimensions (Frame Dims)

Goal
- Compute distances from a marker's nodes to the Reference Model (RM) boundary surfaces, expressed in the FrameOrigin coordinate system.
- Provide both per-node distances and aggregated minimal distances per edge/surface.
- Compute marker size metrics (AABB/OBB) in FrameOrigin and for the vertical projection onto the RM surface.

Typical RMs
- Room: walls (left/right/near/far), ceiling (top), floor (bottom).
- Blade-like object: trailing edge (TE), forward/leading edge (FE), root, tip. These can map onto left/right/near/far/top/bottom depending on the chosen FrameOrigin axes.

Coordinate Systems and Conventions
- FrameOrigin (FO): local coordinate system in which distances are reported. Axes: x (left/right), y (up/down), z (near/far). Up is +y.
- Reference Model (RM): a model with known boundary surfaces, represented in FO.
- Marker: a set of points/nodes p_i in FO.

Inputs
- Points: P = {p_i | p_i ∈ R^3} in FO.
- RM boundary planes (in FO): six planes with unit normals n and signed offsets d, given by n·x + d = 0.
    - left:  +x plane, normal n_left = (+1,0,0)
    - right: −x plane, normal n_right = (−1,0,0)
    - near:  +z plane, normal n_near = (+0,0,+1)
    - far:   −z plane, normal n_far  = (+0,0,−1)
    - top:   +y plane, normal n_top  = (+0,+1,0)
    - bottom:−y plane, normal n_bottom=(+0,−1,0)
- Each plane’s scalar d is chosen so that n·x + d = 0 on the surface and n points inward.

Per-node distances to RM surfaces
- For a point p, the signed distance to a plane (n,d) is: dist_signed(p, plane) = n·p + d.
- The unsigned distance is abs(dist_signed). For containment checks, the sign indicates side.
- For this feature, use unsigned distances for reporting proximity; keep sign if you need inside/outside tests.

Outputs
1) Per-edge, per-point distances
{
    left_edge:  { p1: <dist_p1>, p2: <dist_p2>, ... },
    right_edge: { p1: <dist_p1>, p2: <dist_p2>, ... },
    far_edge:   { p1: <dist_p1>, p2: <dist_p2>, ... },
    near_edge:  { p1: <dist_p1>, p2: <dist_p2>, ... },
    top_edge:   { p1: <dist_p1>, p2: <dist_p2>, ... },
    bottom_edge:{ p1: <dist_p1>, p2: <dist_p2>, ... }
}

2) Aggregated minimal distances (marker-to-edge)
{
    left_edge_dist:   min_i(dist(p_i, left_plane)),
    right_edge_dist:  min_i(dist(p_i, right_plane)),
    far_edge_dist:    min_i(dist(p_i, far_plane)),
    near_edge_dist:   min_i(dist(p_i, near_plane)),
    top_edge_dist:    min_i(dist(p_i, top_plane)),
    bottom_edge_dist: min_i(dist(p_i, bottom_plane))
}

3) Size metrics
sizes: {
    aabb_dims:  Axis-Aligned Bounding Box dimensions in FO.
    obb_dims:   Oriented Bounding Box dimensions (principal axes) in FO.
    projected_on_rm_surface_aabb_dims: AABB of vertically projected points onto RM.
    projected_on_rm_surface_obb_dims:  OBB of vertically projected points onto RM.
}

Computations
- AABB in FO
    - min = (min_i p_i.x, min_i p_i.y, min_i p_i.z)
    - max = (max_i p_i.x, max_i p_i.y, max_i p_i.z)
    - aabb_dims = max − min

- OBB in FO (PCA-based)
    - Compute centroid c and covariance Σ of P.
    - Get eigenvectors e1,e2,e3 (principal directions) and eigenvalues λ1≥λ2≥λ3.
    - Project q_i = E^T (p_i − c) into PCA basis E=[e1 e2 e3].
    - Take mins/maxs along each axis: dims = (max(q.x)−min(q.x), ...).
    - obb_dims = dims, with orientation E and center c.

- Vertical projection onto RM surface
    - Define up = (0,1,0). For each p_i, cast a ray r(t) = p_i + t·(−up), t ≥ 0, to intersect RM surface.
    - If intersection exists at point s_i, collect S = {s_i}. Compute AABB/OBB on S as above.
    - If no hit, decide policy: drop, clamp to plane, or mark as missing.

Rooms vs. Blades mapping
- For rooms, the six named planes match walls/ceiling/floor.
- For blades, map TE/FE/Root/Tip to left/right/near/far/top/bottom by choosing FO axes accordingly. Document the mapping in metadata.

Data contract (Swift shapes)
- Edge identifiers: left, right, near, far, top, bottom.
- Per-point distances keyed by stable point IDs.
- Aggregates are floats (meters).

Swift types (sketch)
- See implementation section below for Codable models and utilities.

Edge cases and policies
- Points outside RM bounds: keep distances to infinite planes, and optionally validate containment with all six signed distances ≤ 0 (inside if all ≤ 0 when normals point inward).
- Missing vertical intersections: report null for projected sizes or use fallback to nearest plane along −up.
- Degenerate sets: < 3 points → OBB not well-defined; fall back to AABB or axis heuristics.
- Numeric stability: normalize plane normals; use float tolerances (epsilon ≈ 1e−5).

Validation
- Unit tests should assert:
    - Known cube with synthetic points → exact AABB/OBB.
    - Points centered between two parallel planes → symmetric distances.
    - Projection hits floor on flat room → projected AABB.y ≈ 0 thickness.

References
- See also: docs/api/IOS_SWIFT_INTEGRATION_GUIDE.md and docs/IMPLEMENTATION_SUMMARY.md.

— — —

Implementation options for iOS Swift app (2025)

Option A: Pure simd math (lightweight, testable)
- Use simd_float3/4x4 for points and transforms.
- Inputs: points in FO and plane equations in FO.
- Outputs: per-point distances, aggregates, AABB/OBB.
- Pros: no AR dependency, fast, works with offline models (e.g., room.usdc).
- Cons: for vertical projection you need a surface mesh or analytic planes.

Option B: RealityKit + ARKit (room scanning, raycasting)
- Use ARView/RealityKit with ARMeshAnchors (sceneReconstruction) for real rooms.
- Build RM planes from anchors or from a preloaded USD model.
- Use RaycastQuery(direction: .down) per point to get vertical projection to surfaces.
- Pros: live environment awareness, robust raycasting API.
- Cons: requires camera/AR session and device; mesh quality varies.

Option C: SceneKit or USD parsing for static models
- Load USDC/USDA reference model (e.g., docs/room.usdc) to get bounds/planes.
- Compute planes from node bounding boxes and transforms.
- Pros: deterministic; no AR dependency.
- Cons: need your own ray–mesh intersection or rely on SceneKit hitTests.

Suggested integration in this repo
- Likely locations: roboscope2/Services/
    - ModelRegistrationService: provides FO↔RM transforms.
    - SpatialMarkerService: provides marker points/nodes in FO.
    - New: FrameDimsService: computes distances and sizes.

Proposed Swift API (sketch)
- Data models
    struct EdgeDistances: Codable { let perPoint: [String: Float] }
    struct FrameDimsAggregate: Codable {
        let left, right, near, far, top, bottom: Float
    }
    struct AABB: Codable { let min: SIMD3<Float>; let max: SIMD3<Float> }
    struct OBB: Codable { let center: SIMD3<Float>; let axes: simd_float3x3; let extents: SIMD3<Float> }
    struct FrameDimsResult: Codable {
        let perEdge: [String: EdgeDistances]
        let aggregate: FrameDimsAggregate
        let aabb: AABB
        let obb: OBB
        let projectedAABB: AABB?
        let projectedOBB: OBB?
    }

- Service interface
    protocol FrameDimsComputing {
        func compute(
            pointsFO: [String: SIMD3<Float>],
            planesFO: [String: (normal: SIMD3<Float>, d: Float)],
            verticalRaycast: ((SIMD3<Float>) -> SIMD3<Float>?)?
        ) -> FrameDimsResult
    }

Implementation notes (Swift)
- Distances: dist = abs(dot(n, p) + d) assuming n normalized.
- AABB: reduction over components.
- OBB (PCA):
    - Build covariance 3×3 via centered data; use simd_quatf or Accelerate/vDSP to eigen-decompose.
    - Sort eigenvectors by eigenvalues; build axes matrix E.
    - Project points to E, take min/max for extents.
- Vertical raycast (RealityKit):
    - let origin = p; let dir = SIMD3<Float>(0, -1, 0)
    - use ARView.scene.raycast(origin:direction:length:query:) or RaycastQuery
    - supply a closure to FrameDimsComputing to decouple AR dependency.

Minimal example (pseudo‑Swift)
- Distances per edge:
    for (id, p) in points {
        perEdge["left"][id]  = abs(dot(n_left,  p) + d_left)
        perEdge["right"][id] = abs(dot(n_right, p) + d_right)
        ...
    }
    aggregate.left = perEdge["left"].values.min()!
    ...

Vertical projection using ARView
- Provide a closure verticalRaycast: (SIMD3<Float>) -> SIMD3<Float>? that raycasts downward and returns hit.position.
- If nil for a point, exclude it from projected AABB/OBB.

Testing
- Place unit tests in roboscope2Tests/ with synthetic point clouds and planes.
- Cover degenerate and out-of-bounds cases.

Performance tips
- Batch vector math with simd; avoid per-frame recomputation when inputs unchanged.
- Throttle updates to UI (e.g., at 10–15 Hz) while doing math at full rate if needed.
- Cache PCA basis if the marker geometry is rigid and only translating/rotating.

Assumptions
- FO axes are orthonormal; RM planes are axis-aligned in FO. If RM is rotated, transform planes/points into FO first via ModelRegistrationService.

Glossary
- FO: FrameOrigin, local coordinate system for outputs.
- RM: Reference Model, boundary definition in FO.
- AABB/OBB: bounding boxes axis-aligned vs. oriented by PCA.

## Persistence in Marker.custom_props (DB)

Where it's stored
- Persist all computed frame dimensions and distances under the Marker model's `custom_props` JSON field in the DB.
- Recommended top-level key: `frame_dims` to avoid collisions with other custom props.

Schema goals
- Self-contained, versioned blob that is easy to evolve and safe to ignore by old clients.
- Compact numeric representation for vectors/matrices.
- Stable point identifiers (for markers with 4 corners: `p1`, `p2`, `p3`, `p4`).

Top-level structure
- custom_props.frame_dims is a JSON object with the following shape:

```
frame_dims: {
    version: 1,                        // Schema version for migrations
    units: "m",                        // Distance units (meters)
    fo_axes: { x: "left-right", y: "up-down", z: "near-far" },
    rm_kind: "room" | "blade" | "other", // Optional: reference model flavor
    planes: {                          // Optional: plane offsets d used for distances (in FO)
        left:   { n: [ 1, 0,  0], d: <float> },
        right:  { n: [-1, 0,  0], d: <float> },
        near:   { n: [ 0, 0,  1], d: <float> },
        far:    { n: [ 0, 0, -1], d: <float> },
        top:    { n: [ 0, 1,  0], d: <float> },
        bottom: { n: [ 0,-1,  0], d: <float> }
    },

    // 1) Per-edge, per-point distances (unsigned) in meters
    per_edge: {
        left:   { per_point: { p1: <float>, p2: <float>, p3: <float>, p4: <float> } },
        right:  { per_point: { p1: <float>, p2: <float>, p3: <float>, p4: <float> } },
        near:   { per_point: { p1: <float>, p2: <float>, p3: <float>, p4: <float> } },
        far:    { per_point: { p1: <float>, p2: <float>, p3: <float>, p4: <float> } },
        top:    { per_point: { p1: <float>, p2: <float>, p3: <float>, p4: <float> } },
        bottom: { per_point: { p1: <float>, p2: <float>, p3: <float>, p4: <float> } }
    },

    // 2) Aggregated minimal distances (marker-to-edge)
    aggregate: {
        left:   <float>,
        right:  <float>,
        near:   <float>,
        far:    <float>,
        top:    <float>,
        bottom: <float>
    },

    // 3) Size metrics (FO)
    sizes: {
        aabb: { min: [x,y,z], max: [x,y,z] },
        obb:  { center: [x,y,z], axes: [[ax,ay,az],[bx,by,bz],[cx,cy,cz]], extents: [ex,ey,ez] }
    },

    // 4) Optional: vertical projection onto RM surface
    projected: {
        aabb: { min: [x,y,z], max: [x,y,z] } | null,
        obb:  { center: [x,y,z], axes: [[...],[...],[...]], extents: [ex,ey,ez] } | null
    },

    // Optional metadata for traceability
    meta: {
        computed_at_iso: "2025-01-01T12:34:56Z",
        epsilon: 1e-5,
        notes: "PCA over 4-corner marker; planes from room model"
    }
}
```

Notes
- Vectors and matrices are encoded as arrays for portability: `SIMD3<Float>` → `[x,y,z]`, 3×3 axes → `[[...],[...],[...]]` (column-major or row-major is irrelevant for consumers treating them as opaque axes sets; we recommend columns = principal directions e1,e2,e3).
- Per-point IDs should be stable across sessions. For the current 4-corner marker model, use `p1..p4` aligned with `Marker.p1..p4`.
- If some vertical projections are missing, set `projected` fields to `null` or omit the key, consistent with the policy outlined above.
- Keep `units` as "m" and distances as floats. If you change units, bump `version`.

Example `custom_props` fragment
```
{
    "custom_props": {
        "frame_dims": {
            "version": 1,
            "units": "m",
            "fo_axes": { "x": "left-right", "y": "up-down", "z": "near-far" },
            "rm_kind": "room",
            "aggregate": { "left": 0.42, "right": 3.18, "near": 1.05, "far": 2.61, "top": 1.92, "bottom": 0.15 },
            "per_edge": {
                "left":   { "per_point": { "p1": 0.44, "p2": 0.41, "p3": 0.43, "p4": 0.42 } },
                "right":  { "per_point": { "p1": 3.12, "p2": 3.19, "p3": 3.22, "p4": 3.18 } },
                "near":   { "per_point": { "p1": 1.02, "p2": 1.06, "p3": 1.05, "p4": 1.03 } },
                "far":    { "per_point": { "p1": 2.64, "p2": 2.60, "p3": 2.61, "p4": 2.62 } },
                "top":    { "per_point": { "p1": 1.90, "p2": 1.93, "p3": 1.92, "p4": 1.91 } },
                "bottom": { "per_point": { "p1": 0.14, "p2": 0.15, "p3": 0.16, "p4": 0.15 } }
            },
            "sizes": {
                "aabb": { "min": [ -0.25, 0.10, 1.00 ], "max": [ 0.25, 0.40, 1.30 ] },
                "obb":  {
                    "center": [ 0.00, 0.25, 1.15 ],
                    "axes": [[1,0,0],[0,1,0],[0,0,1]],
                    "extents": [ 0.25, 0.15, 0.15 ]
                }
            },
            "projected": {
                "aabb": { "min": [ -0.25, 0.00, 1.00 ], "max": [ 0.25, 0.00, 1.30 ] },
                "obb": null
            },
            "meta": { "computed_at_iso": "2025-10-27T10:00:00Z", "epsilon": 1e-5 }
        }
    }
}
```

Swift mapping hints
- Use `Marker.customProps["frame_dims"]` as a `[String: AnyCodable]` payload.
- Define a `FrameDimsResult` (see Swift sketch above) and `Codable` wrappers for JSON bridge:
    - Encode vectors as `[Float]` and matrices as `[[Float]]`.
    - Keep key names identical to the JSON sketch (e.g., `per_edge.left.per_point.p1`).
    - Consider adding a `CustomPropsKeys.frameDims = "frame_dims"` constant for consistency.

Validation in storage
- On write: set or replace `custom_props.frame_dims` atomically with the full blob to avoid partial updates.
- On read: treat missing `frame_dims` or unknown `version` as absent feature; compute on demand or prompt recompute.
- Keep blob size modest; for 4 points this structure is small and suitable for mobile sync.


