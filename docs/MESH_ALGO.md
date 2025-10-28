Mesh-based frame distances: corrected algorithm

Summary
- We do NOT raycast horizontally.
- From each marker node, we trace the surface laterally in X/Z by stepping in small increments, raycasting vertically (along +Y or -Y) at each step to “drop” to the surface and accumulate the path length until the surface ends (edge reached).

Assumptions
- Surface is not self-sealing (topologically open at the edges we measure to).
- FrameOrigin axes: X = left/right, Y = up/down, Z = near/far.
- Model bounds are available (AABB from the mesh) to derive a safe vertical start height and step sizes.

Notation
- HP0: the first hit point on the surface obtained by a vertical ray from the marker node.
- TP0: the elevated “top tracing point” directly above HP0 used to start lateral sweeping.
- Δx, Δz: lateral step sizes along X and Z.

Step-by-step
1) Project to the surface (find HP0)
	- Cast a vertical ray DOWN from the marker node. If it hits, HP0 = hit.
	- If DOWN misses, cast UP. If it hits, HP0 = hit.
	- If both miss, skip this node.

2) Create the starting tracing point TP0
	- Let H be the model’s height from its mesh AABB (maxY - minY).
	- TP0 = (HP0.x, HP0.y + H + margin, HP0.z), where margin = 1.0 m (safe vertical clearance above any geometry).

3) Lateral surface tracing by vertical re-projection
	For each cardinal edge, sweep laterally in the corresponding axis while keeping the other axis fixed:
	- LEFT: x ← x - Δx, with z fixed (same as TP0.z)
	- RIGHT: x ← x + Δx, with z fixed
	- NEAR: z ← z - Δz, with x fixed (same as TP0.x)
	- FAR:  z ← z + Δz, with x fixed

	At each lateral step:
	- Construct Elevated = (x, TP0.y, z).
	- Raycast DOWN from Elevated. If it hits, append the hit point to a trace polyline.
	- If it misses, the surface ended in that direction → stop sweeping for this edge.

4) Distance accumulation
	- Compute the sum of Euclidean distances between successive hit points in the trace polyline.
	- That sum is the surface-following distance from the original node to the corresponding edge.

Recommended parameters
- Δx = 0.01 · modelExtentX, Δz = 0.01 · modelExtentZ (clamp to [1 cm, 5 cm] for performance/stability).
- margin = 1.0 m above the model’s top (AABB.maxY + 1.0).
- Max steps safety cap to avoid infinite loops (e.g., 3000).

Pseudo-code
```
for each markerNode P:
	 HP0 = raycastY(P, downThenUp)
	 if HP0 == nil: continue
	 TP0 = (HP0.x, HP0.y + modelHeight + 1.0, HP0.z)

	 for dir in [left(-Δx,0), right(+Δx,0), near(0,-Δz), far(0,+Δz)]:
		  traced = []
		  C = TP0
		  while steps < maxSteps:
				C.x += dir.dx; C.z += dir.dz
				hit = raycastDown(C)
				if hit == nil: break
				append(traced, hit)
		  distance = sum( distance(traced[i], traced[i+1]) )
```

Notes
- This approach is robust for curved, vertical surfaces (e.g., a half-cylinder). It measures the true surface path length to the open edge by re-projecting vertically at each lateral step.
- For predominantly horizontal surfaces, this method is not appropriate (you would trace in X/Z with horizontal re-projection instead).

