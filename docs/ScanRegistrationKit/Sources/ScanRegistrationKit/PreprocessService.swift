
import Foundation
import simd

public struct PreprocessParams {
    public var minRange: Float = 0.25
    public var maxRange: Float = 5.0
    public var voxelSizes: [Float] = [0.02, 0.01, 0.007]
    public init() {}
}

public final class PreprocessService {
    public init() {}

    public func buildPyramid(raw: [SIMD3<Float>], gravityUp: SIMD3<Float>, params: PreprocessParams = .init()) -> [PointCloud] {
        let filtered = raw.filter { let d = simd_length($0); return d >= params.minRange && d <= params.maxRange }
        var pyr: [PointCloud] = []
        for vx in params.voxelSizes {
            let vox = voxelize(points: filtered, voxel: vx)
            let (normals, bbMin, bbMax) = estimateNormalsAndBounds(points: vox, voxel: vx, up: gravityUp)
            let pc = PointCloud(
                points: vox.map { Point3F(x: $0.x, y: $0.y, z: $0.z) },
                normals: normals.map { Normal3F(nx: $0.x, ny: $0.y, nz: $0.z) },
                voxelSize: vx,
                boundsMin: bbMin.map { Point3F(x: $0.x, y: $0.y, z: $0.z) },
                boundsMax: bbMax.map { Point3F(x: $0.x, y: $0.y, z: $0.z) },
                estimatedUp: Normal3F(nx: gravityUp.x, ny: gravityUp.y, nz: gravityUp.z)
            )
            pyr.append(pc)
        }
        return pyr
    }
}
