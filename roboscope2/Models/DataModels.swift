//
//  DataModels.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import Foundation
import simd

// MARK: - Pose

struct Pose: Codable {
    var matrix: simd_float4x4
    
    init(_ matrix: simd_float4x4 = .identity) {
        self.matrix = matrix
    }
    
    // Manual Codable implementation
    enum CodingKeys: String, CodingKey {
        case matrixData
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try container.decode([Float].self, forKey: .matrixData)
        self.matrix = simd_float4x4(codableColumns: data)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(matrix.codableColumns, forKey: .matrixData)
    }
}

// MARK: - Registration Metrics

struct RegistrationMetrics: Codable {
    var inlierFraction: Float
    var rmseMeters: Float
    var iterations: Int
    var voxelMeters: Float
    var timestamp: Double
}

// MARK: - Point and Normal

struct Point3F: Codable, Hashable {
    var x, y, z: Float
    
    init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = x; self.y = y; self.z = z
    }
    
    init(_ v: SIMD3<Float>) {
        self.x = v.x; self.y = v.y; self.z = v.z
    }
    
    var simd: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

struct Normal3F: Codable {
    var nx, ny, nz: Float
    
    init(_ nx: Float, _ ny: Float, _ nz: Float) {
        self.nx = nx; self.ny = ny; self.nz = nz
    }
    
    init(_ v: SIMD3<Float>) {
        self.nx = v.x; self.ny = v.y; self.nz = v.z
    }
    
    var simd: SIMD3<Float> {
        SIMD3<Float>(nx, ny, nz)
    }
}

// MARK: - Point Cloud

struct PointCloud: Codable {
    var points: [Point3F]
    var normals: [Normal3F]?
    var voxelSize: Float?
    var boundsMin: Point3F?
    var boundsMax: Point3F?
    var estimatedUp: Normal3F?
    
    init(points: [Point3F] = [],
         normals: [Normal3F]? = nil,
         voxelSize: Float? = nil,
         boundsMin: Point3F? = nil,
         boundsMax: Point3F? = nil,
         estimatedUp: Normal3F? = nil) {
        self.points = points
        self.normals = normals
        self.voxelSize = voxelSize
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.estimatedUp = estimatedUp
    }
}

// MARK: - Scan Snapshot

struct ScanSnapshot: Codable {
    var cloud: PointCloud
    var worldOrigin: Pose
    var device: String
    var arWorldMapData: Data?
}

// MARK: - Model Descriptor

struct ModelDescriptor: Codable {
    var name: String
    var nominalScale: Float
    var canonicalFrameHint: String
    var sampleVoxel: Float
}

// MARK: - Alignment Result

struct AlignmentResult: Codable {
    var poseModelInWorld: Pose
    var metrics: RegistrationMetrics
    var model: ModelDescriptor
}

// MARK: - Raw Cloud (non-Codable, runtime only)

struct RawCloud {
    var points: [SIMD3<Float>]
    var confidences: [UInt8]
}

// MARK: - Helper: Identity matrix

extension simd_float4x4 {
    static var identity: simd_float4x4 {
        matrix_identity_float4x4
    }
}

// MARK: - simd_float4x4 Codable Support

// Note: simd_float4x4 requires manual Codable conformance
// We store it as 16 Float values (column-major order)
extension simd_float4x4 {
    init(codableColumns: [Float]) {
        precondition(codableColumns.count == 16, "Expected 16 floats for matrix")
        self.init(
            SIMD4<Float>(codableColumns[0], codableColumns[1], codableColumns[2], codableColumns[3]),
            SIMD4<Float>(codableColumns[4], codableColumns[5], codableColumns[6], codableColumns[7]),
            SIMD4<Float>(codableColumns[8], codableColumns[9], codableColumns[10], codableColumns[11]),
            SIMD4<Float>(codableColumns[12], codableColumns[13], codableColumns[14], codableColumns[15])
        )
    }
    
    var codableColumns: [Float] {
        let c0 = columns.0
        let c1 = columns.1
        let c2 = columns.2
        let c3 = columns.3
        return [c0.x, c0.y, c0.z, c0.w,
                c1.x, c1.y, c1.z, c1.w,
                c2.x, c2.y, c2.z, c2.w,
                c3.x, c3.y, c3.z, c3.w]
    }
}
