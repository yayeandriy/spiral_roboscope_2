//
//  AlignmentCoordinator.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import Foundation
import simd
import Combine

enum AlignmentState {
    case idle
    case loadingModel
    case scanning
    case preprocessing
    case coarseAlignment
    case icpRefinement(level: Int, iterations: Int)
    case completed
    case failed(Error)
}

/// Orchestrates the alignment pipeline
final class AlignmentCoordinator: ObservableObject {
    @Published var state: AlignmentState = .idle
    @Published var currentMetrics: RegistrationMetrics?
    
    private let modelLoader = ModelLoader()
    private let preprocessService = PreprocessService()
    private let coarsePoseEstimator = CoarsePoseEstimator()
    private let icpRefiner = ICPRefiner()
    
    private var modelCloud: PointCloud?
    private var scanPyramid: [PointCloud] = []
    
    func loadModel(named: String, sampleVoxel: Float = 0.01) async {
        await MainActor.run { state = .loadingModel }
        
        do {
            let cloud = try await modelLoader.loadUSDZ(named: named, sampleVoxel: sampleVoxel)
            await MainActor.run {
                self.modelCloud = cloud
                self.state = .idle
            }
        } catch {
            await MainActor.run {
                self.state = .failed(error)
            }
        }
    }
    
    func preprocessScan(raw: RawCloud, gravityUp: SIMD3<Float>) async {
        await MainActor.run {
            state = .preprocessing
        }
        
        // Run preprocessing on background thread
        let params = PreprocessParams()
        let pyramid = await Task.detached(priority: .userInitiated) {
            return self.preprocessService.buildPyramid(raw: raw, gravityUp: gravityUp, params: params)
        }.value
        
        scanPyramid = pyramid
        
        await MainActor.run {
            state = .idle
        }
    }
    
    func runAlignment(gravityUp: SIMD3<Float>) async -> (pose: simd_float4x4, metrics: RegistrationMetrics)? {
        guard let modelCloud = modelCloud, !scanPyramid.isEmpty else {
            await MainActor.run {
                self.state = .failed(NSError(domain: "AlignmentCoordinator", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "Model or scan not ready"]))
            }
            return nil
        }
        
        await MainActor.run { state = .coarseAlignment }
        
        // Generate seeds on background thread
        let seeds = await Task.detached(priority: .userInitiated) {
            return self.coarsePoseEstimator.seeds(model: modelCloud, scan: self.scanPyramid[0], up: gravityUp)
        }.value
        
        guard !seeds.isEmpty else {
            await MainActor.run {
                self.state = .failed(NSError(domain: "AlignmentCoordinator", code: 2,
                                             userInfo: [NSLocalizedDescriptionKey: "No valid seeds generated"]))
            }
            return nil
        }
        
        await MainActor.run { state = .icpRefinement(level: 0, iterations: 0) }
        
        // Create model pyramid (same voxel sizes as scan)
        let voxelSizes = scanPyramid.compactMap { $0.voxelSize }
        let modelPyramid = await Task.detached(priority: .userInitiated) {
            return self.createModelPyramid(from: modelCloud, voxelSizes: voxelSizes)
        }.value
        
        // ICP refinement on background thread with reduced iterations for faster performance
        let paramsPerLevel = [
            ICPParams(maxIterations: 10, maxCorrDist: 0.08, normalDotMin: 0.75, trimFraction: 0.7, huberDelta: 0.02),
            ICPParams(maxIterations: 8, maxCorrDist: 0.04, normalDotMin: 0.75, trimFraction: 0.7, huberDelta: 0.01),
            ICPParams(maxIterations: 5, maxCorrDist: 0.025, normalDotMin: 0.75, trimFraction: 0.7, huberDelta: 0.007)
        ]
        
        let result = await Task.detached(priority: .userInitiated) {
            return self.icpRefiner.refine(
                modelPyr: modelPyramid,
                scanPyr: self.scanPyramid,
                seeds: seeds.map { $0.pose },
                paramsPerLevel: paramsPerLevel
            )
        }.value
        
        await MainActor.run {
            self.currentMetrics = result.metrics
            self.state = .completed
        }
        
        return (pose: result.bestPose, metrics: result.metrics)
    }
    
    private func createModelPyramid(from baseCloud: PointCloud, voxelSizes: [Float]) -> [PointCloud] {
        // For simplicity, just replicate the base cloud
        // In production, downsample at each level
        return voxelSizes.map { _ in baseCloud }
    }
}
