
import Foundation
import simd

public struct CoarseSeed { public let pose: simd_float4x4; public let score: Float }

public final class CoarsePoseEstimator {
    public init() {}

    public func seeds(model: PointCloud, scan: PointCloud, up: SIMD3<Float>, yawDegrees: [Float]) -> [CoarseSeed] {
        let mPts = model.toSIMD()
        let sPts = scan.toSIMD()
        guard !mPts.isEmpty && !sPts.isEmpty else { return [] }

        // Compute BB centers
        func bbCenter(_ pts: [SIMD3<Float>]) -> SIMD3<Float> {
            var minP = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
            var maxP = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
            for p in pts { minP = simd_min(minP, p); maxP = simd_max(maxP, p) }
            return (minP + maxP) * 0.5
        }
        let cm = bbCenter(mPts)
        let cs = bbCenter(sPts)
        let baseT = simd_float4x4(rotation: simd_float3x3(1), translation: cs - cm)

        // Generate yaw variants around up
        var out: [CoarseSeed] = []
        for yaw in yawDegrees {
            let rad = yaw * (.pi/180)
            let R = rotationAround(axis: up, angle: rad)
            let T = simd_float4x4(rotation: R * simd_float3x3(1), translation: .zero) * baseT
            let score: Float = 0 // can add quick score later
            out.append(CoarseSeed(pose: T, score: score))
        }
        return out
    }
}

func rotationAround(axis: SIMD3<Float>, angle: Float) -> simd_float3x3 {
    let a = simd_normalize(axis)
    let c = cos(angle), s = sin(angle)
    let x=a.x, y=a.y, z=a.z
    let R = simd_float3x3(rows: [
        SIMD3<Float>(c + x*x*(1-c),     x*y*(1-c) - z*s, x*z*(1-c) + y*s),
        SIMD3<Float>(y*x*(1-c) + z*s,   c + y*y*(1-c),   y*z*(1-c) - x*s),
        SIMD3<Float>(z*x*(1-c) - y*s,   z*y*(1-c) + x*s, c + z*z*(1-c))
    ])
    return R
}
