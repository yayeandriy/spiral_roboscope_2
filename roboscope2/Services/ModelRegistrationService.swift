//
//  ModelRegistrationService.swift
//  roboscope2
//
//  Service for registering USDC model to scan using ICP algorithm
//

import Foundation
import SceneKit
import simd

/// Service to align a USDC model with a scan model using point cloud registration
class ModelRegistrationService {
    
    struct RegistrationResult {
        let transformMatrix: simd_float4x4
        let rmse: Float
        let inlierFraction: Float
        let iterations: Int
    }
    
    /// Extract point cloud from SCNNode
    static func extractPointCloud(from node: SCNNode, sampleCount: Int = 10000) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        var childCount = 0
        
        node.enumerateChildNodes { child, _ in
            childCount += 1
            guard let geometry = child.geometry else { return }
            
            // Get vertices from geometry sources
            if let vertexSource = geometry.sources(for: .vertex).first {
                let stride = vertexSource.dataStride
                let offset = vertexSource.dataOffset
                let componentsPerVertex = vertexSource.componentsPerVector
                let data = vertexSource.data
                
                let vertexCount = vertexSource.vectorCount
                
                for i in 0..<vertexCount {
                    let vertexOffset = offset + (i * stride)
                    let x = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Float in
                        ptr.load(fromByteOffset: vertexOffset, as: Float.self)
                    }
                    let y = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Float in
                        ptr.load(fromByteOffset: vertexOffset + 4, as: Float.self)
                    }
                    let z = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Float in
                        ptr.load(fromByteOffset: vertexOffset + 8, as: Float.self)
                    }
                    
                    // Transform to world space so both models are in same coordinate system
                    let localPoint = SCNVector3(x, y, z)
                    let worldPoint = child.convertPosition(localPoint, to: nil)
                    points.append(SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z))
                }
            }
        }
        
        // Compute bounding box for debugging
        if !points.isEmpty {
            var minPoint = points[0]
            var maxPoint = points[0]
            for p in points {
                minPoint.x = min(minPoint.x, p.x)
                minPoint.y = min(minPoint.y, p.y)
                minPoint.z = min(minPoint.z, p.z)
                maxPoint.x = max(maxPoint.x, p.x)
                maxPoint.y = max(maxPoint.y, p.y)
                maxPoint.z = max(maxPoint.z, p.z)
            }
            print("[Registration] Point cloud bounds: min=\(minPoint), max=\(maxPoint)")
            let size = maxPoint - minPoint
            print("[Registration] Point cloud size: (\(size.x), \(size.y), \(size.z))")
        }
        
        // Downsample if too many points
        if points.count > sampleCount {
            let step = points.count / sampleCount
            points = stride(from: 0, to: points.count, by: step).map { points[$0] }
        }
        
        print("[Registration] Extracted \(points.count) points from \(childCount) child nodes")
        return points
    }
    
    /// Simple ICP registration (Iterative Closest Point)
    static func registerModels(
        modelPoints: [SIMD3<Float>],
        scanPoints: [SIMD3<Float>],
        maxIterations: Int = 50,
        convergenceThreshold: Float = 0.0001,
        progressHandler: @escaping (String) -> Void
    ) async -> RegistrationResult? {
        
        guard !modelPoints.isEmpty && !scanPoints.isEmpty else {
            print("[Registration] Error: Empty point clouds")
            return nil
        }
        
        print("[Registration] Starting ICP with \(modelPoints.count) model points and \(scanPoints.count) scan points")
        
        // Compute initial centroids for alignment
        var modelCentroid = SIMD3<Float>(0, 0, 0)
        var scanCentroid = SIMD3<Float>(0, 0, 0)
        for p in modelPoints { modelCentroid += p }
        for p in scanPoints { scanCentroid += p }
        modelCentroid /= Float(modelPoints.count)
        scanCentroid /= Float(scanPoints.count)
        
        print("[Registration] Model centroid: \(modelCentroid)")
        print("[Registration] Scan centroid: \(scanCentroid)")
        
        // Perform coarse yaw search to find initial alignment
        let initialYaw = findBestInitialYaw(
            modelPoints: modelPoints,
            scanPoints: scanPoints,
            modelCentroid: modelCentroid,
            scanCentroid: scanCentroid
        )
        print("[Registration] Initial yaw search result: \(initialYaw * 180 / .pi)°")
        
        // Initialize transform with centroid alignment and initial yaw
        let c = cosf(initialYaw)
        let s = sinf(initialYaw)
        var rotY = simd_float3x3(1)
        rotY[0,0] = c;  rotY[0,1] = 0; rotY[0,2] = s
        rotY[1,0] = 0;  rotY[1,1] = 1; rotY[1,2] = 0
        rotY[2,0] = -s; rotY[2,1] = 0; rotY[2,2] = c
        
        let initialTranslation = scanCentroid - rotY * modelCentroid
        var currentTransform = simd_float4x4(1.0)
        currentTransform.columns.0 = SIMD4<Float>(rotY[0,0], rotY[0,1], rotY[0,2], 0)
        currentTransform.columns.1 = SIMD4<Float>(rotY[1,0], rotY[1,1], rotY[1,2], 0)
        currentTransform.columns.2 = SIMD4<Float>(rotY[2,0], rotY[2,1], rotY[2,2], 0)
        currentTransform.columns.3 = SIMD4<Float>(initialTranslation.x, initialTranslation.y, initialTranslation.z, 1.0)
        
        print("[Registration] Initial translation: \(initialTranslation)")
        print("[Registration] Initial transform matrix:")
        print("[Registration]   [\(currentTransform.columns.0)]")
        print("[Registration]   [\(currentTransform.columns.1)]")
        print("[Registration]   [\(currentTransform.columns.2)]")
        print("[Registration]   [\(currentTransform.columns.3)]")
        
        var previousError: Float = .infinity
        var iterations = 0
        
        // Build KD-tree or spatial hash for scan points (simplified: use brute force for now)
        let scanPointsArray = scanPoints
        
        for iteration in 0..<maxIterations {
            iterations = iteration + 1
            
            await MainActor.run {
                progressHandler("Iteration \(iteration + 1)/\(maxIterations)")
            }
            
            // Transform model points
            var transformedPoints: [SIMD3<Float>] = []
            for point in modelPoints {
                let p4 = SIMD4<Float>(point.x, point.y, point.z, 1.0)
                let transformed = currentTransform * p4
                transformedPoints.append(SIMD3<Float>(transformed.x, transformed.y, transformed.z))
            }
            
            // Find closest points and compute correspondences
            var correspondences: [(model: SIMD3<Float>, scan: SIMD3<Float>)] = []
            var totalError: Float = 0
            
            for modelPoint in transformedPoints {
                // Find nearest scan point (brute force)
                var minDist: Float = .infinity
                var nearest: SIMD3<Float>?
                
                for scanPoint in scanPointsArray {
                    let dist = distance(modelPoint, scanPoint)
                    if dist < minDist {
                        minDist = dist
                        nearest = scanPoint
                    }
                }
                
                if let nearestPoint = nearest, minDist < 0.5 { // 50cm threshold
                    correspondences.append((modelPoint, nearestPoint))
                    totalError += minDist * minDist
                }
            }
            
            guard !correspondences.isEmpty else {
                print("[Registration] No correspondences found")
                break
            }
            
            let rmse = sqrt(totalError / Float(correspondences.count))
            print("[Registration] Iteration \(iteration + 1): RMSE = \(rmse), Correspondences = \(correspondences.count)")
            
            // Check convergence
            if abs(previousError - rmse) < convergenceThreshold {
                print("[Registration] Converged at iteration \(iteration + 1)")
                break
            }
            previousError = rmse
            
            // Compute optimal transformation for this iteration, constrained to yaw (Y-axis rotation)
            // Note: correspondences are between transformedPoints and scanPoints
            // So deltaTransform moves transformedPoints -> scanPoints
            // We need to compose: currentTransform takes modelPoints -> transformedPoints
            // deltaTransform takes transformedPoints -> better alignment
            if let deltaTransform = computeOptimalYawTransform(correspondences: correspondences) ?? computeOptimalTransform(correspondences: correspondences) {
                // Compose the transforms: new = delta * current
                currentTransform = deltaTransform * currentTransform
                print("[Registration] Delta transform applied, new translation: \(currentTransform.columns.3)")
            }
        }
        
        // Compute final metrics
        let finalError = computeFinalMetrics(
            modelPoints: modelPoints,
            scanPoints: scanPoints,
            transform: currentTransform
        )
        
        print("[Registration] Final transform matrix:")
        print("[Registration]   [\(currentTransform.columns.0)]")
        print("[Registration]   [\(currentTransform.columns.1)]")
        print("[Registration]   [\(currentTransform.columns.2)]")
        print("[Registration]   [\(currentTransform.columns.3)]")
        print("[Registration] Final translation: (\(currentTransform.columns.3.x), \(currentTransform.columns.3.y), \(currentTransform.columns.3.z))")
        
        return RegistrationResult(
            transformMatrix: currentTransform,
            rmse: finalError.rmse,
            inlierFraction: finalError.inlierFraction,
            iterations: iterations
        )
    }
    
    /// Compute optimal rigid transformation from correspondences using a Kabsch-like approach
    private static func computeOptimalTransform(
        correspondences: [(model: SIMD3<Float>, scan: SIMD3<Float>)]
    ) -> simd_float4x4? {
        
        guard correspondences.count >= 3 else { return nil }
        
        // Compute centroids
        var modelCentroid = SIMD3<Float>(0, 0, 0)
        var scanCentroid = SIMD3<Float>(0, 0, 0)
        
        for (m, s) in correspondences {
            modelCentroid += m
            scanCentroid += s
        }
        
        modelCentroid /= Float(correspondences.count)
        scanCentroid /= Float(correspondences.count)
        
        // Compute cross-covariance matrix H = sum((model - model_centroid) * (scan - scan_centroid)^T)
        var H = simd_float3x3(0)
        for (m, s) in correspondences {
            let mp = m - modelCentroid
            let sp = s - scanCentroid
            // Outer product mp * sp^T
            H[0][0] += mp.x * sp.x; H[0][1] += mp.x * sp.y; H[0][2] += mp.x * sp.z
            H[1][0] += mp.y * sp.x; H[1][1] += mp.y * sp.y; H[1][2] += mp.y * sp.z
            H[2][0] += mp.z * sp.x; H[2][1] += mp.z * sp.y; H[2][2] += mp.z * sp.z
        }

        // Polar decomposition to approximate rotation without SVD
        // Iterate: R_{k+1} = 0.5 * (R_k + R_k^{-T}) starting from H
        var R = H
        let maxIter = 12
        let tol: Float = 1e-5
        for _ in 0..<maxIter {
            let RinvT = simd_transpose(simd_inverse(R))
            let Rnext = 0.5 * (R + RinvT)
            let diff = Rnext - R
            let norm = sqrtf(diff.columns.0.x*diff.columns.0.x + diff.columns.0.y*diff.columns.0.y + diff.columns.0.z*diff.columns.0.z +
                             diff.columns.1.x*diff.columns.1.x + diff.columns.1.y*diff.columns.1.y + diff.columns.1.z*diff.columns.1.z +
                             diff.columns.2.x*diff.columns.2.x + diff.columns.2.y*diff.columns.2.y + diff.columns.2.z*diff.columns.2.z)
            R = Rnext
            if norm < tol { break }
        }

        // Ensure orthonormality with a final Gram-Schmidt (stabilize)
        var c0 = SIMD3<Float>(R[0][0], R[1][0], R[2][0])
        var c1 = SIMD3<Float>(R[0][1], R[1][1], R[2][1])
        var c2 = SIMD3<Float>(R[0][2], R[1][2], R[2][2])
        c0 = simd_normalize(c0)
        c1 = simd_normalize(c1 - simd_dot(c0, c1) * c0)
        c2 = simd_cross(c0, c1)
        R[0][0] = c0.x; R[1][0] = c0.y; R[2][0] = c0.z
        R[0][1] = c1.x; R[1][1] = c1.y; R[2][1] = c1.z
        R[0][2] = c2.x; R[1][2] = c2.y; R[2][2] = c2.z

        // Avoid reflection: enforce det(R) > 0
        let detR = simd_determinant(R)
        if detR < 0 {
            // Flip the third column to correct reflection
            R[0][2] = -R[0][2]
            R[1][2] = -R[1][2]
            R[2][2] = -R[2][2]
        }

        // Translation: t = scanCentroid - R * modelCentroid
        let rotatedModelCentroid = R * modelCentroid
        let translation = scanCentroid - rotatedModelCentroid

        // Build 4x4 transform matrix
        var transform = simd_float4x4(1.0)
        transform.columns.0 = SIMD4<Float>(R[0][0], R[0][1], R[0][2], 0)
        transform.columns.1 = SIMD4<Float>(R[1][0], R[1][1], R[1][2], 0)
        transform.columns.2 = SIMD4<Float>(R[2][0], R[2][1], R[2][2], 0)
        transform.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1.0)

        return transform
    }

    /// Find best initial yaw by coarse angular search
    private static func findBestInitialYaw(
        modelPoints: [SIMD3<Float>],
        scanPoints: [SIMD3<Float>],
        modelCentroid: SIMD3<Float>,
        scanCentroid: SIMD3<Float>
    ) -> Float {
        let angleSteps = 36 // Search every 10 degrees
        var bestYaw: Float = 0
        var bestScore: Float = .infinity
        
        // Sample subset of points for speed
        let sampleSize = min(500, modelPoints.count)
        let step = max(1, modelPoints.count / sampleSize)
        let sampledModel = stride(from: 0, to: modelPoints.count, by: step).map { modelPoints[$0] }
        
        for i in 0..<angleSteps {
            let yaw = Float(i) * (2 * .pi / Float(angleSteps))
            let c = cosf(yaw)
            let s = sinf(yaw)
            
            // Rotate model points around Y
            var rotY = simd_float3x3(1)
            rotY[0,0] = c;  rotY[0,1] = 0; rotY[0,2] = s
            rotY[1,0] = 0;  rotY[1,1] = 1; rotY[1,2] = 0
            rotY[2,0] = -s; rotY[2,1] = 0; rotY[2,2] = c
            
            let t = scanCentroid - rotY * modelCentroid
            
            // Score: sum of squared distances to nearest scan points
            var score: Float = 0
            for mp in sampledModel {
                let transformed = rotY * mp + t
                var minDist: Float = .infinity
                for sp in scanPoints {
                    let d = distance_squared(transformed, sp)
                    if d < minDist { minDist = d }
                }
                score += minDist
            }
            
            if score < bestScore {
                bestScore = score
                bestYaw = yaw
            }
        }
        
        return bestYaw
    }
    
    /// Compute optimal yaw-only (rotation around Y axis) rigid transform
    private static func computeOptimalYawTransform(
        correspondences: [(model: SIMD3<Float>, scan: SIMD3<Float>)]
    ) -> simd_float4x4? {
        guard correspondences.count >= 3 else { return nil }

        // Centroids (full 3D for translation, but rotation uses XZ plane)
        var modelCentroid = SIMD3<Float>(0,0,0)
        var scanCentroid = SIMD3<Float>(0,0,0)
        for (m, s) in correspondences {
            modelCentroid += m
            scanCentroid += s
        }
        modelCentroid /= Float(correspondences.count)
        scanCentroid /= Float(correspondences.count)

        // Accumulate 2D cross terms on XZ plane
        var a: Float = 0 // Σ (mx' * sx' + mz' * sz')
        var b: Float = 0 // Σ (mx' * sz' - mz' * sx')
        for (m, s) in correspondences {
            let mx = m.x - modelCentroid.x
            let mz = m.z - modelCentroid.z
            let sx = s.x - scanCentroid.x
            let sz = s.z - scanCentroid.z
            a += mx * sx + mz * sz
            b += mx * sz - mz * sx
        }

        // Best yaw angle
        let theta = atan2f(b, a)
        let c = cosf(theta)
        let s = sinf(theta)

        var R = simd_float3x3(1)
        R[0,0] = c;  R[0,1] = 0; R[0,2] = s
        R[1,0] = 0;  R[1,1] = 1; R[1,2] = 0
        R[2,0] = -s; R[2,1] = 0; R[2,2] = c

        // Translation aligning centroids after rotation
        let t = scanCentroid - R * modelCentroid

        var T = simd_float4x4(1)
        T.columns.0 = SIMD4<Float>(R[0,0], R[0,1], R[0,2], 0)
        T.columns.1 = SIMD4<Float>(R[1,0], R[1,1], R[1,2], 0)
        T.columns.2 = SIMD4<Float>(R[2,0], R[2,1], R[2,2], 0)
        T.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)

        print("[Registration] Yaw-only angle (deg): \(theta * 180 / .pi)")
        return T
    }
    
    /// Compute final registration metrics
    private static func computeFinalMetrics(
        modelPoints: [SIMD3<Float>],
        scanPoints: [SIMD3<Float>],
        transform: simd_float4x4
    ) -> (rmse: Float, inlierFraction: Float) {
        
        var totalError: Float = 0
        var inliers = 0
        let threshold: Float = 0.1 // 10cm inlier threshold
        
        for point in modelPoints {
            let p4 = SIMD4<Float>(point.x, point.y, point.z, 1.0)
            let transformed = transform * p4
            let transformedPoint = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
            
            // Find nearest scan point
            var minDist: Float = .infinity
            for scanPoint in scanPoints {
                let dist = distance(transformedPoint, scanPoint)
                if dist < minDist {
                    minDist = dist
                }
            }
            
            totalError += minDist * minDist
            if minDist < threshold {
                inliers += 1
            }
        }
        
        let rmse = sqrt(totalError / Float(modelPoints.count))
        let inlierFraction = Float(inliers) / Float(modelPoints.count)
        
        return (rmse, inlierFraction)
    }
}
