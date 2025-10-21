
import Foundation
import simd

/// Estimate normals via PCA in a fixed radius neighborhood (grid assisted).
public func estimateNormalsAndBounds(points: [SIMD3<Float>], voxel: Float, up: SIMD3<Float>) -> ([SIMD3<Float>], SIMD3<Float>?, SIMD3<Float>?) {
    if points.isEmpty { return ([], nil, nil) }
    let grid = GridNN(points: points, voxel: voxel)
    var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0,1,0), count: points.count)
    var minP = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
    var maxP = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

    let r2: Float = (3 * voxel) * (3 * voxel)

    for (i,p) in points.enumerated() {
        minP = simd_min(minP, p)
        maxP = simd_max(maxP, p)
        // collect neighbors
        var neigh: [SIMD3<Float>] = []
        // sample a small set; scan nearby buckets
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let kk = VoxelKey(
                        x: Int32(floor(p.x/voxel)) + Int32(dx),
                        y: Int32(floor(p.y/voxel)) + Int32(dy),
                        z: Int32(floor(p.z/voxel)) + Int32(dz)
                    )
                    // simplify: brute neighbors from all points (small perf hit ok for v1)
                }
            }
        }
        // fallback: just find ~32 nearest by scanning all (ok for v1, tune later)
        // Compute covariance
        var mean = SIMD3<Float>(0,0,0)
        var count = 0
        for q in points {
            let d2 = simd_length_squared(q - p)
            if d2 <= r2 {
                mean += q; count += 1
                neigh.append(q)
            }
        }
        if count < 3 {
            normals[i] = up // not enough neighbors; use up
            continue
        }
        mean /= Float(count)
        var C = simd_float3x3(repeating: 0)
        for q in neigh {
            let v = q - mean
            C += simd_float3x3(rows: [
                SIMD3<Float>(v.x*v.x, v.x*v.y, v.x*v.z),
                SIMD3<Float>(v.y*v.x, v.y*v.y, v.y*v.z),
                SIMD3<Float>(v.z*v.x, v.z*v.y, v.z*v.z),
            ])
        }
        // Get eigenvectors by power iteration for smallest eigenvalue (surface normal)
        var n = SIMD3<Float>(1,0,0)
        for _ in 0..<8 {
            n = simd_normalize(C * n)
        }
        // Orient by up (flip to face similar direction)
        if simd_dot(n, up) < 0 { n = -n }
        normals[i] = n
    }

    return (normals, minP, maxP)
}
