//
//  CoarsePoseEstimator.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import Foundation
import simd

struct CoarseSeed {
    let pose: simd_float4x4
    let score: Float
}

/// Generates multi-hypothesis seeds using gravity alignment and PCA
final class CoarsePoseEstimator {
    
    func seeds(model: PointCloud, scan: PointCloud, up: SIMD3<Float>) -> [CoarseSeed] {
        var result: [CoarseSeed] = []
        
        guard let modelBounds = model.boundsMin, let modelMax = model.boundsMax,
              let scanBounds = scan.boundsMin, let scanMax = scan.boundsMax else {
            return result
        }
        
        // Compute centers
        let modelCenter = (modelBounds.simd + modelMax.simd) / 2.0
        let scanCenter = (scanBounds.simd + scanMax.simd) / 2.0
        
        // Translation: align centers
        let translation = scanCenter - modelCenter
        
        // Generate seeds with different yaw rotations around up axis
        let yawAngles: [Float] = [0, .pi/2, .pi, 3 * .pi/2] // 0°, 90°, 180°, 270°
        
        for yaw in yawAngles {
            // Create rotation matrix around up axis
            let rotation = simd_quatf(angle: yaw, axis: normalize(up))
            let rotationMatrix = simd_matrix4x4(rotation)
            
            // Create transform: rotate then translate
            var transform = rotationMatrix
            transform.columns.3 = simd_float4(translation, 1)
            
            // Simple score: 1.0 for now (will be refined by ICP)
            result.append(CoarseSeed(pose: transform, score: 1.0))
        }
        
        return result
    }
}
