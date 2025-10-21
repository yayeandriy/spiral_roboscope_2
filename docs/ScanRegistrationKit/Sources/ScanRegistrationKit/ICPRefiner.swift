
import Foundation
import simd

public struct ICPParams {
    public var maxIterations: Int
    public var maxCorrDist: Float
    public var normalDotMin: Float
    public var trimFraction: Float
    public var huberDelta: Float
    public init(maxIterations: Int, maxCorrDist: Float, normalDotMin: Float, trimFraction: Float, huberDelta: Float) {
        self.maxIterations = maxIterations
        self.maxCorrDist = maxCorrDist
        self.normalDotMin = normalDotMin
        self.trimFraction = trimFraction
        self.huberDelta = huberDelta
    }
}

public final class ICPRefiner {
    public init() {}

    public func refine(modelPyr: [PointCloud],
                       scanPyr: [PointCloud],
                       seeds: [simd_float4x4],
                       paramsPerLevel: [ICPParams]) -> (bestPose: simd_float4x4, metrics: RegistrationMetrics) {

        var bestPose = simd_float4x4.identity
        var bestRMSE: Float = Float.greatestFiniteMagnitude
        var bestInliers: Float = 0
        var totalIters = 0
        let finestVoxel = scanPyr.last?.voxelSize ?? 0.01

        for seed in seeds {
            var T = seed
            var rmse: Float = .infinity
            var inlierFrac: Float = 0
            for (lvl, params) in paramsPerLevel.enumerated() {
                let m = lvl < modelPyr.count ? modelPyr[lvl] : modelPyr.last!
                let s = lvl < scanPyr.count ? scanPyr[lvl] : scanPyr.last!
                let out = icpLevel(model: m, scan: s, seed: T, params: params)
                T = out.pose
                rmse = out.rmse
                inlierFrac = out.inlierFrac
                totalIters += out.iters
            }
            if rmse < bestRMSE {
                bestRMSE = rmse
                bestInliers = inlierFrac
                bestPose = T
            }
        }
        let metrics = RegistrationMetrics(inlierFraction: bestInliers, rmseMeters: bestRMSE, iterations: totalIters, finestVoxel: finestVoxel ?? 0.01, timestamp: Date().timeIntervalSince1970)
        return (bestPose, metrics)
    }

    private func icpLevel(model: PointCloud, scan: PointCloud, seed: simd_float4x4, params: ICPParams) -> (pose: simd_float4x4, rmse: Float, inlierFrac: Float, iters: Int) {
        var T = seed
        let mPts0 = model.toSIMD()
        let sPts = scan.toSIMD()
        let sNrms = scan.normalsSIMD() ?? Array(repeating: SIMD3<Float>(0,1,0), count: sPts.count)
        let grid = GridNN(points: sPts, voxel: scan.voxelSize ?? 0.02)
        var rmse: Float = .infinity
        var inlierFrac: Float = 0
        var iters = 0

        for iter in 0..<params.maxIterations {
            iters = iter + 1
            // 1) Transform model points
            var residuals: [(Float, SIMD3<Float>, SIMD3<Float>)] = [] // (r_i, n_i, p_i_world_center)
            residuals.reserveCapacity(min(mPts0.count, sPts.count))

            var inlierCount = 0
            var sumSq: Float = 0

            for mp in mPts0 {
                // transform
                let mp4 = simd_float4(mp, 1)
                let pw = (T * mp4).xyz
                if let nn = grid.nearest(to: pw) {
                    let j = nn.index
                    let sp = sPts[j]
                    let n = sNrms[j]
                    if simd_dot(n, n) < 1e-6 { continue }
                    let diff = pw - sp
                    let dist = sqrt(max(0, simd_length_squared(diff)))
                    if dist > params.maxCorrDist { continue }
                    // normal compatibility
                    // Approx model normal not available here; we only gate by scan normal angle vs gravity (skip)
                    // residual: point-to-plane
                    let r = simd_dot(n, diff)
                    residuals.append((r, n, pw))
                    sumSq += r*r
                    inlierCount += 1
                }
            }

            if inlierCount == 0 { break }

            // 2) Trim largest residuals
            let keepN = Int(Float(residuals.count) * params.trimFraction)
            let sorted = residuals.sorted { abs($0.0) < abs($1.0) }
            let kept = Array(sorted.prefix(max(1, keepN)))

            // 3) Build normal equations A^T W A xi = A^T W b
            // For point-to-plane, Jacobian J_i = [ n x p , n ]
            var ATA = [[Float]](repeating: [Float](repeating: 0, count: 6), count: 6)
            var ATb = [Float](repeating: 0, count: 6)
            var keptSq: Float = 0

            for (r, n, pw) in kept {
                let Jw = cross(n, pw)        // 3 comps
                let Jv = n                   // 3 comps
                var J = [Jw.x, Jw.y, Jw.z, Jv.x, Jv.y, Jv.z]
                // Huber weight
                let a = abs(r)
                let w: Float = a <= params.huberDelta ? 1.0 : params.huberDelta/a
                // ATA += w * J^T J ; ATb += w * J^T (-r)
                for i in 0..<6 {
                    ATb[i] += w * J[i] * (-r)
                    for j in 0..<6 {
                        ATA[i][j] += w * J[i] * J[j]
                    }
                }
                keptSq += r*r
            }

            // 4) Solve 6x6
            guard let xi = solve6x6(A: ATA, b: ATb) else { break }

            // 5) Update T
            let dT = se3Exp(toSIMD6(xi))
            T = dT * T

            // 6) Convergence
            let newRMSE = sqrt(keptSq / Float(max(1, kept.count)))
            if abs(newRMSE - rmse) < 1e-3 * (scan.voxelSize ?? 0.01) { rmse = newRMSE; break }
            rmse = newRMSE
            inlierFrac = Float(inlierCount) / Float(mPts0.count)
        }

        return (T, rmse, inlierFrac, iters)
    }
}

private func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    return simd_cross(a, b)
}

private func toSIMD6(_ v: [Float]) -> SIMD6<Float> {
    var out = SIMD6<Float>()
    for i in 0..<6 { out[i] = v[i] }
    return out
}

/// Naive Gaussian elimination for 6x6 — sufficient for small problems.
private func solve6x6(A: [[Float]], b: [Float]) -> [Float]? {
    var M = A
    var v = b
    let n = 6
    // Forward elimination
    for i in 0..<n {
        // Pivot
        var maxRow = i
        var maxVal = abs(M[i][i])
        for r in (i+1)..<n {
            if abs(M[r][i]) > maxVal { maxVal = abs(M[r][i]); maxRow = r }
        }
        if maxVal < 1e-9 { return nil }
        if maxRow != i {
            M.swapAt(i, maxRow)
            v.swapAt(i, maxRow)
        }
        // Normalize pivot row
        let piv = M[i][i]
        for c in i..<n { M[i][c] /= piv }
        v[i] /= piv
        // Eliminate
        for r in 0..<n {
            if r == i { continue }
            let factor = M[r][i]
            if abs(factor) < 1e-9 { continue }
            for c in i..<n { M[r][c] -= factor * M[i][c] }
            v[r] -= factor * v[i]
        }
    }
    return v
}
