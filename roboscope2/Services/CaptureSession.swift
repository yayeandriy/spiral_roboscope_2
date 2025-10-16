//
//  CaptureSession.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import ARKit
import Combine
import RealityKit
import ModelIO
import SceneKit.ModelIO

/// Configures ARKit with scene reconstruction & gravity alignment
final class CaptureSession: NSObject, ObservableObject {
    let session = ARSession()
    
    @Published var isRunning: Bool = false
    @Published var gravityUp: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    @Published var isScanning: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var meshAnchors: [ARMeshAnchor] = []
    
    override init() {
        super.init()
        session.delegate = self
    }
    
    func start() {
        guard !isRunning else {
            print("ARSession already running, skipping start")
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        
        // Enable plane detection for raycasting
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }
    
    func stop() {
        session.pause()
        isRunning = false
    }
    
    // MARK: - Scanning
    
    func startScanning() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("Mesh scanning not supported on this device")
            return
        }
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        config.sceneReconstruction = .mesh
        
        session.run(config, options: [])
        isScanning = true
        meshAnchors.removeAll()
        print("Started mesh scanning")
    }
    
    func stopScanning() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        config.sceneReconstruction = []
        
        session.run(config, options: [])
        isScanning = false
        print("Stopped mesh scanning - captured \(meshAnchors.count) mesh anchors")
    }
    
    func exportMeshData(
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (URL?) -> Void
    ) {
        guard !meshAnchors.isEmpty else {
            print("No mesh data to export")
            completion(nil)
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(nil)
                return
            }
            
            let totalAnchors = self.meshAnchors.count
            let mdlAsset = MDLAsset()
            
            progress(0.0, "Processing \(totalAnchors) mesh tiles...")
            
            for (index, anchor) in self.meshAnchors.enumerated() {
                let mdlMesh = self.convertARMeshToMDLMesh(anchor.geometry, transform: anchor.transform)
                mdlAsset.add(mdlMesh)
                
                let currentProgress = Double(index + 1) / Double(totalAnchors) * 0.8 // 80% for processing
                progress(currentProgress, "Processing tile \(index + 1) of \(totalAnchors)...")
            }
            
            // Create export URL
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let exportURL = documentsPath.appendingPathComponent("spatial_scan_\(timestamp).obj")
            
            // Export as OBJ
            progress(0.85, "Writing OBJ file...")
            
            do {
                try mdlAsset.export(to: exportURL)
                print("Exported mesh data to: \(exportURL.path)")
                
                progress(1.0, "Export complete!")
                
                // Small delay to show completion
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    completion(exportURL)
                }
            } catch {
                print("Failed to export mesh: \(error)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
    
    private func convertARMeshToMDLMesh(_ geometry: ARMeshGeometry, transform: simd_float4x4) -> MDLMesh {
        let vertices = geometry.vertices
        let faces = geometry.faces
        
        let vertexCount = vertices.count
        let vertexStride = vertices.stride
        
        let vertexBuffer = vertices.buffer
        let faceBuffer = faces.buffer
        
        // Create MDL vertex descriptor
        let allocator = MDLMeshBufferDataAllocator()
        
        // Transform vertices to world space
        // CRITICAL: Use stride to read vertices correctly (not tightly packed)
        let sourcePtr = vertexBuffer.contents()
        var transformedVertices: [SIMD3<Float>] = []
        transformedVertices.reserveCapacity(vertexCount)
        
        for i in 0..<vertexCount {
            // Read vertex at correct offset using stride
            let offset = i * vertexStride
            let vertexPtr = sourcePtr.advanced(by: offset).assumingMemoryBound(to: Float.self)
            let localVertex = SIMD3<Float>(vertexPtr[0], vertexPtr[1], vertexPtr[2])
            
            // Apply anchor transform to move from local mesh space to world space
            let worldVertex4 = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1.0)
            transformedVertices.append(SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z))
        }
        
        // Create vertex buffer with transformed data
        let vertexData = Data(bytes: transformedVertices, count: MemoryLayout<SIMD3<Float>>.stride * vertexCount)
        let mdlVertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
        
        // Create index buffer
        // ARMeshGeometry uses specific index types - need to read correctly
        let indexCount = faces.count * faces.indexCountPerPrimitive
        let bytesPerIndex = faces.bytesPerIndex
        
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        
        let facePtr = faceBuffer.contents()
        for i in 0..<indexCount {
            let offset = i * bytesPerIndex
            if bytesPerIndex == MemoryLayout<UInt16>.size {
                // 16-bit indices
                let index = facePtr.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee
                indices.append(UInt32(index))
            } else {
                // 32-bit indices
                let index = facePtr.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
                indices.append(index)
            }
        }
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let mdlIndexBuffer = allocator.newBuffer(with: indexData, type: .index)
        
        // Create submesh
        let submesh = MDLSubmesh(
            indexBuffer: mdlIndexBuffer,
            indexCount: indexCount,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )
        
        // Create vertex descriptor
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
        
        // Create MDL mesh
        let mdlMesh = MDLMesh(
            vertexBuffer: mdlVertexBuffer,
            vertexCount: vertexCount,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )
        
        return mdlMesh
    }
}

// MARK: - ARSessionDelegate

extension CaptureSession: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Update gravity from camera transform
        let camera = frame.camera
        gravityUp = normalize(SIMD3<Float>(camera.transform.columns.1.x,
                                           camera.transform.columns.1.y,
                                           camera.transform.columns.1.z))
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isScanning else { return }
        
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                meshAnchors.append(meshAnchor)
                print("Added mesh anchor - total: \(meshAnchors.count)")
            }
        }
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isScanning else { return }
        
        for anchor in anchors {
            if let meshAnchor = anchor as? ARMeshAnchor {
                // Update existing mesh anchor
                if let index = meshAnchors.firstIndex(where: { $0.identifier == meshAnchor.identifier }) {
                    meshAnchors[index] = meshAnchor
                } else {
                    meshAnchors.append(meshAnchor)
                }
            }
        }
    }
}
