
import Foundation
import simd

public struct VoxelKey: Hashable {
    public let x: Int32; public let y: Int32; public let z: Int32
}

public func voxelize(points: [SIMD3<Float>], voxel: Float) -> [SIMD3<Float>] {
    if points.isEmpty { return [] }
    var sum: [VoxelKey: SIMD3<Float>] = [:]
    var cnt: [VoxelKey: Int] = [:]
    sum.reserveCapacity(points.count/4)
    cnt.reserveCapacity(points.count/4)
    for p in points {
        let k = VoxelKey(
            x: Int32(floor(p.x/voxel)),
            y: Int32(floor(p.y/voxel)),
            z: Int32(floor(p.z/voxel))
        )
        sum[k, default: .zero] &+= p
        cnt[k, default: 0] &+= 1
    }
    return sum.map { (kv) in kv.value / Float(cnt[kv.key] ?? 1) }
}

/// A simple grid bucket NN for correspondences at a given voxel resolution.
public final class GridNN {
    let voxel: Float
    private var buckets: [VoxelKey: [Int]] = [:]
    private var pts: [SIMD3<Float>] = []

    public init(points: [SIMD3<Float>], voxel: Float) {
        self.voxel = voxel
        self.pts = points
        buckets.reserveCapacity(points.count/2)
        for (i,p) in points.enumerated() {
            let k = key(for: p)
            buckets[k, default: []].append(i)
        }
    }

    private func key(for p: SIMD3<Float>) -> VoxelKey {
        VoxelKey(
            x: Int32(floor(p.x/voxel)),
            y: Int32(floor(p.y/voxel)),
            z: Int32(floor(p.z/voxel))
        )
    }

    public func nearest(to q: SIMD3<Float>) -> (index: Int, dist2: Float)? {
        let k = key(for: q)
        var best: (Int, Float)?
        // search 3x3x3 neighborhood
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let kk = VoxelKey(x: k.x+Int32(dx), y: k.y+Int32(dy), z: k.z+Int32(dz))
                    guard let idxs = buckets[kk] else { continue }
                    for i in idxs {
                        let d2 = simd_length_squared(pts[i] - q)
                        if best == nil || d2 < best!.1 { best = (i, d2) }
                    }
                }
            }
        }
        return best
    }
}
