
import Foundation
import simd

public struct RegistrationRequest {
    public var scan: PointCloud
    public var model: PointCloud
    public var gravityUp: SIMD3<Float>
    public var voxelPyramid: [Float]
    public var seedYawDegrees: [Float]
    public var trimFraction: Float

    public init(scan: PointCloud, model: PointCloud, gravityUp: SIMD3<Float>, voxelPyramid: [Float], seedYawDegrees: [Float], trimFraction: Float) {
        self.scan = scan
        self.model = model
        self.gravityUp = gravityUp
        self.voxelPyramid = voxelPyramid
        self.seedYawDegrees = seedYawDegrees
        self.trimFraction = trimFraction
    }
}

public enum RegistrationError: Error {
    case insufficientPoints
    case icpFailed
}

public struct RegistrationOutput: Codable {
    public var poseModelInWorld: Pose
    public var metrics: RegistrationMetrics
}

public final class RegistrationPipeline {
    let pre = PreprocessService()
    let coarse = CoarsePoseEstimator()
    let icp = ICPRefiner()

    public init() {}

    public static func defaultPipeline() -> RegistrationPipeline { RegistrationPipeline() }

    public func register(request: RegistrationRequest) -> Result<RegistrationOutput, Error> {
        let scanPyr = pre.buildPyramid(raw: request.scan.toSIMD(), gravityUp: request.gravityUp, params: .init())
        // build model pyramid by re-voxelizing model at same levels
        var modelPyr: [PointCloud] = []
        for vx in request.voxelPyramid {
            let mVox = voxelize(points: request.model.toSIMD(), voxel: vx)
            let (norms, bbMin, bbMax) = estimateNormalsAndBounds(points: mVox, voxel: vx, up: request.gravityUp)
            modelPyr.append(PointCloud(
                points: mVox.map{ Point3F(x: $0.x, y: $0.y, z: $0.z) },
                normals: norms.map{ Normal3F(nx: $0.x, ny: $0.y, nz: $0.z) },
                voxelSize: vx,
                boundsMin: bbMin.map{ Point3F(x: $0.x, y: $0.y, z: $0.z) },
                boundsMax: bbMax.map{ Point3F(x: $0.x, y: $0.y, z: $0.z) },
                estimatedUp: Normal3F(nx: request.gravityUp.x, ny: request.gravityUp.y, nz: request.gravityUp.z)
            ))
        }

        guard let coarseScan = scanPyr.first, let coarseModel = modelPyr.first else {
            return .failure(RegistrationError.insufficientPoints)
        }
        let seeds = coarse.seeds(model: coarseModel, scan: coarseScan, up: request.gravityUp, yawDegrees: request.seedYawDegrees)
        if seeds.isEmpty { return .failure(RegistrationError.icpFailed) }

        let paramsPerLevel: [ICPParams] = zip(request.voxelPyramid.indices, request.voxelPyramid).map { (i,vx) in
            let maxCorr = 4.0 * vx
            let huber = 2.0 * vx
            let dotMin: Float = i == 0 ? 0.75 : (i == 1 ? 0.8 : 0.85)
            let iters = i == 0 ? 20 : (i == 1 ? 15 : 12)
            return ICPParams(maxIterations: iters, maxCorrDist: maxCorr, normalDotMin: dotMin, trimFraction: request.trimFraction, huberDelta: huber)
        }

        let (T, metrics) = icp.refine(modelPyr: modelPyr, scanPyr: scanPyr, seeds: seeds.map{$0.pose}, paramsPerLevel: paramsPerLevel)
        let out = RegistrationOutput(poseModelInWorld: Pose(matrix: T), metrics: metrics)
        return .success(out)
    }
}
