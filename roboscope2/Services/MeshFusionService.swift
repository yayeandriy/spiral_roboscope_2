//
//  MeshFusionService.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import ARKit
import simd
import Combine

/// Fuses ARMeshAnchor geometry into a deduplicated point set
final class MeshFusionService: ObservableObject {
    private struct VoxelKey: Hashable {
        let x, y, z: Int32
    }
    
    private var voxelMap: [VoxelKey: (point: SIMD3<Float>, confidence: UInt8, count: Int)] = [:]
    private let voxelSize: Float = 0.01 // 1cm for deduplication
    private let queue = DispatchQueue(label: "com.roboscope.meshfusion", qos: .userInitiated)
    
    @Published var pointCount: Int = 0
    
    func reset() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.voxelMap.removeAll()
            DispatchQueue.main.async {
                self.pointCount = 0
            }
        }
    }
    
    func append(meshAnchor: ARMeshAnchor) {
        // Capture all needed data from meshAnchor synchronously on ARKit's thread
        let geometry = meshAnchor.geometry
        let transform = meshAnchor.transform
        
        // Get vertex count and validate
        let vertexCount = Int(geometry.vertices.count)
        guard vertexCount > 0 else { return }
        
        // Copy vertex data immediately to avoid accessing ARKit objects later
        let vertexBuffer = geometry.vertices.buffer
        let vertexBufferPointer = vertexBuffer.contents()
        let vertexStride = geometry.vertices.stride
        
        var vertexData: [simd_float3] = []
        vertexData.reserveCapacity(vertexCount)
        
        // Safely copy vertex data
        for i in 0..<vertexCount {
            let offset = i * vertexStride
            let vertexPointer = vertexBufferPointer.advanced(by: offset).assumingMemoryBound(to: Float.self)
            let vertex = simd_float3(vertexPointer[0], vertexPointer[1], vertexPointer[2])
            vertexData.append(vertex)
        }
        
        // Copy classification data if available
        let faceCount = Int(geometry.faces.count)
        var classificationData: [ARMeshClassification] = []
        
        if let classificationBuffer = geometry.classification?.buffer {
            let classificationPointer = classificationBuffer.contents()
                .assumingMemoryBound(to: ARMeshClassification.self)
            classificationData.reserveCapacity(faceCount)
            for i in 0..<min(faceCount, vertexCount) {
                classificationData.append(classificationPointer[i])
            }
        }
        
        // Now process on background queue with copied data
        queue.async { [weak self, vertexData, classificationData, transform, faceCount] in
            guard let self = self else { return }
            
            for i in 0..<vertexData.count {
                let vertex = vertexData[i]
            var localPoint = SIMD3<Float>(vertex.x, vertex.y, vertex.z)
            
            // Transform to world space
            let worldPoint4 = transform * simd_float4(localPoint, 1.0)
            let worldPoint = SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)
            
            // Skip invalid points (NaN or infinite values)
            guard worldPoint.x.isFinite && worldPoint.y.isFinite && worldPoint.z.isFinite else {
                continue
            }
            
            // Estimate confidence (ARKit doesn't provide per-vertex confidence directly)
            // Use classification as proxy: unknown = low, floor/wall/etc = high
            var confidence: UInt8 = 128 // medium default
            if !classificationData.isEmpty && i < classificationData.count {
                let classification = classificationData[i]
                confidence = classification == .none ? 64 : 255
            }
            
            // Voxelize to deduplicate
            let voxelX = (worldPoint.x / voxelSize).rounded(.down)
            let voxelY = (worldPoint.y / voxelSize).rounded(.down)
            let voxelZ = (worldPoint.z / voxelSize).rounded(.down)
            
            // Additional safety check before converting to Int32
            guard voxelX.isFinite && voxelY.isFinite && voxelZ.isFinite,
                  voxelX >= Float(Int32.min) && voxelX <= Float(Int32.max),
                  voxelY >= Float(Int32.min) && voxelY <= Float(Int32.max),
                  voxelZ >= Float(Int32.min) && voxelZ <= Float(Int32.max) else {
                continue
            }
            
            let key = VoxelKey(
                x: Int32(voxelX),
                y: Int32(voxelY),
                z: Int32(voxelZ)
            )
            
            if let existing = voxelMap[key] {
                // Average with existing point
                let newCount = existing.count + 1
                
                // Break up complex point averaging expression
                let weightedExisting = existing.point * Float(existing.count)
                let sumPoints = weightedExisting + worldPoint
                let avgPoint = sumPoints / Float(newCount)
                
                // Break up complex confidence averaging expression
                let existingConf = Int(existing.confidence) * existing.count
                let totalConf = existingConf + Int(confidence)
                let avgConfInt = totalConf / newCount
                let avgConf = UInt8(avgConfInt)
                
                voxelMap[key] = (avgPoint, avgConf, newCount)
            } else {
                self.voxelMap[key] = (worldPoint, confidence, 1)
            }
            }
            
            let currentCount = self.voxelMap.count
            DispatchQueue.main.async { [weak self] in
                self?.pointCount = currentCount
            }
        }
    }
    
    func snapshotPointCloud() -> RawCloud {
        return queue.sync {
            self.createSnapshot()
        }
    }
    
    private func createSnapshot() -> RawCloud {
        var points: [SIMD3<Float>] = []
        var confidences: [UInt8] = []
        
        points.reserveCapacity(voxelMap.count)
        confidences.reserveCapacity(voxelMap.count)
        
        for (_, value) in voxelMap {
            points.append(value.point)
            confidences.append(value.confidence)
        }
        
        return RawCloud(points: points, confidences: confidences)
    }
}
