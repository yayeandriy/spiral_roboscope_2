
import Foundation
import simd

public struct Pose: Codable {
    public var matrix: simd_float4x4
    public init(matrix: simd_float4x4) { self.matrix = matrix }
}

public struct RegistrationMetrics: Codable {
    public var inlierFraction: Float
    public var rmseMeters: Float
    public var iterations: Int
    public var finestVoxel: Float
    public var timestamp: Double
    public init(inlierFraction: Float, rmseMeters: Float, iterations: Int, finestVoxel: Float, timestamp: Double) {
        self.inlierFraction = inlierFraction
        self.rmseMeters = rmseMeters
        self.iterations = iterations
        self.finestVoxel = finestVoxel
        self.timestamp = timestamp
    }
}

public struct Point3F: Codable { public var x, y, z: Float
    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
    public var simd: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
public struct Normal3F: Codable { public var nx, ny, nz: Float
    public init(nx: Float, ny: Float, nz: Float) { self.nx = nx; self.ny = ny; self.nz = nz }
    public var simd: SIMD3<Float> { SIMD3<Float>(nx, ny, nz) }
}

public struct PointCloud: Codable {
    public var points: [Point3F]
    public var normals: [Normal3F]?
    public var voxelSize: Float?
    public var boundsMin: Point3F?
    public var boundsMax: Point3F?
    public var estimatedUp: Normal3F?

    public init(points: [Point3F], normals: [Normal3F]? = nil, voxelSize: Float? = nil, boundsMin: Point3F? = nil, boundsMax: Point3F? = nil, estimatedUp: Normal3F? = nil) {
        self.points = points
        self.normals = normals
        self.voxelSize = voxelSize
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.estimatedUp = estimatedUp
    }

    public static func fromSIMD(points: [SIMD3<Float>]) -> PointCloud {
        PointCloud(points: points.map { Point3F(x: $0.x, y: $0.y, z: $0.z) })
    }

    public func toSIMD() -> [SIMD3<Float>] { points.map { $0.simd } }
    public func normalsSIMD() -> [SIMD3<Float>]? { normals?.map { $0.simd } }
}
