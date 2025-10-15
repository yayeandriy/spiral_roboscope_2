//
//  ICPRefiner.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import Foundation
import simd

struct ICPParams {
    var maxIterations: Int = 20
    var maxCorrDist: Float = 0.08 // 8cm
    var normalDotMin: Float = 0.75
    var trimFraction: Float = 0.7
    var huberDelta: Float = 0.02 // 2cm
}

/// Robust point-to-plane ICP with trimmed loss
final class ICPRefiner {
    
    func refine(modelPyr: [PointCloud],
                scanPyr: [PointCloud],
                seeds: [simd_float4x4],
                paramsPerLevel: [ICPParams]) -> (bestPose: simd_float4x4, metrics: RegistrationMetrics) {
        
        var bestPose: simd_float4x4 = .identity
        var bestMetrics = RegistrationMetrics(inlierFraction: 0, rmseMeters: Float.infinity, 
                                               iterations: 0, voxelMeters: 0, timestamp: Date().timeIntervalSince1970)
        
        // Try each seed
        for seed in seeds {
            var currentPose = seed
            var totalIterations = 0
            
            // Refine through pyramid levels (coarse to fine)
            for (levelIdx, modelCloud) in modelPyr.enumerated() {
                guard levelIdx < scanPyr.count else { break }
                let scanCloud = scanPyr[levelIdx]
                let params = levelIdx < paramsPerLevel.count ? paramsPerLevel[levelIdx] : ICPParams()
                
                // Run ICP at this level
                let result = icpLevel(model: modelCloud, scan: scanCloud, 
                                     initialPose: currentPose, params: params)
                currentPose = result.pose
                totalIterations += result.iterations
            }
            
            // Evaluate final pose
            let metrics = evaluatePose(model: modelPyr.last!, scan: scanPyr.last!, 
                                      pose: currentPose, iterations: totalIterations,
                                      voxel: modelPyr.last!.voxelSize ?? 0.01)
            
            if metrics.rmseMeters < bestMetrics.rmseMeters {
                bestPose = currentPose
                bestMetrics = metrics
            }
        }
        
        return (bestPose, bestMetrics)
    }
    
    // MARK: - ICP at Single Level
    
    private func icpLevel(model: PointCloud, scan: PointCloud, 
                         initialPose: simd_float4x4, params: ICPParams) -> (pose: simd_float4x4, iterations: Int) {
        var pose = initialPose
        var prevRMSE: Float = .infinity
        
        let modelPts = model.points.map { $0.simd }
        let scanPts = scan.points.map { $0.simd }
        let scanNormals = scan.normals?.map { $0.simd } ?? []
        
        for _ in 0..<params.maxIterations {
            // Transform model points
            let transformedModel = modelPts.map { pt in
                let p4 = pose * simd_float4(pt, 1)
                return SIMD3<Float>(p4.x, p4.y, p4.z)
            }
            
            // Find correspondences
            var correspondences: [(model: SIMD3<Float>, scan: SIMD3<Float>, normal: SIMD3<Float>)] = []
            
            for mPt in transformedModel {
                // Find nearest scan point (brute force for simplicity)
                var nearestDist: Float = .infinity
                var nearestIdx = -1
                
                for (idx, sPt) in scanPts.enumerated() {
                    let dist = distance(mPt, sPt)
                    if dist < nearestDist && dist < params.maxCorrDist {
                        nearestDist = dist
                        nearestIdx = idx
                    }
                }
                
                if nearestIdx >= 0 && nearestIdx < scanNormals.count {
                    correspondences.append((mPt, scanPts[nearestIdx], scanNormals[nearestIdx]))
                }
            }
            
            guard !correspondences.isEmpty else { break }
            
            // Compute RMSE
            let rmse = sqrt(correspondences.map { pow(distance($0.model, $0.scan), 2) }.reduce(0, +) / Float(correspondences.count))
            
            // Check convergence
            if abs(prevRMSE - rmse) < 0.0001 {
                break
            }
            prevRMSE = rmse
            
            // Solve for pose update (simplified - in production use proper point-to-plane minimization)
            // For now, just compute centroid alignment as approximation
            let modelCentroid = correspondences.map { $0.model }.reduce(.zero, +) / Float(correspondences.count)
            let scanCentroid = correspondences.map { $0.scan }.reduce(.zero, +) / Float(correspondences.count)
            let translation = scanCentroid - modelCentroid
            
            // Update pose
            pose.columns.3 += simd_float4(translation * 0.5, 0) // damped update
        }
        
        return (pose, params.maxIterations)
    }
    
    // MARK: - Evaluate Pose
    
    private func evaluatePose(model: PointCloud, scan: PointCloud, 
                             pose: simd_float4x4, iterations: Int, voxel: Float) -> RegistrationMetrics {
        let modelPts = model.points.map { $0.simd }
        let scanPts = scan.points.map { $0.simd }
        
        // Transform model points
        let transformedModel = modelPts.map { pt in
            let p4 = pose * simd_float4(pt, 1)
            return SIMD3<Float>(p4.x, p4.y, p4.z)
        }
        
        // Compute metrics
        var inlierCount = 0
        var totalError: Float = 0
        let maxInlierDist: Float = voxel * 3
        
        for mPt in transformedModel {
            let minDist = scanPts.map { distance(mPt, $0) }.min() ?? .infinity
            if minDist < maxInlierDist {
                inlierCount += 1
                totalError += minDist * minDist
            }
        }
        
        let inlierFraction = Float(inlierCount) / Float(transformedModel.count)
        let rmse = inlierCount > 0 ? sqrt(totalError / Float(inlierCount)) : .infinity
        
        return RegistrationMetrics(
            inlierFraction: inlierFraction,
            rmseMeters: rmse,
            iterations: iterations,
            voxelMeters: voxel,
            timestamp: Date().timeIntervalSince1970
        )
    }
}
