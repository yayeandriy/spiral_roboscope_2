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
                let mdlMesh = self.convertARMeshToMDLMesh(anchor.geometry, transform: anchor.transform, decimationFactor: 3.0)
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
    
    private func convertARMeshToMDLMesh(_ geometry: ARMeshGeometry, transform: simd_float4x4, decimationFactor: Float = 1.0) -> MDLMesh {
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
        
        // Apply decimation if requested
        var finalVertices = transformedVertices
        var finalIndices = indices
        
        if decimationFactor > 1.0 {
            let decimated = decimateMesh(vertices: transformedVertices, indices: indices, factor: decimationFactor)
            finalVertices = decimated.vertices
            finalIndices = decimated.indices
        }
        
        // Create vertex buffer with final data
        let finalVertexData = Data(bytes: finalVertices, count: MemoryLayout<SIMD3<Float>>.stride * finalVertices.count)
        let finalMdlVertexBuffer = allocator.newBuffer(with: finalVertexData, type: .vertex)
        
        let indexData = Data(bytes: finalIndices, count: finalIndices.count * MemoryLayout<UInt32>.size)
        let mdlIndexBuffer = allocator.newBuffer(with: indexData, type: .index)
        
        // Create submesh
        let submesh = MDLSubmesh(
            indexBuffer: mdlIndexBuffer,
            indexCount: finalIndices.count,
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
            vertexBuffer: finalMdlVertexBuffer,
            vertexCount: finalVertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )
        
        return mdlMesh
    }
    
    // MARK: - Mesh Decimation
    
    private func decimateMesh(vertices: [SIMD3<Float>], indices: [UInt32], factor: Float) -> (vertices: [SIMD3<Float>], indices: [UInt32]) {
        // Simple grid-based decimation
        // Group vertices into voxel grid and merge nearby vertices
        let voxelSize = 0.01 * factor // Larger voxel = more decimation (in meters)
        
        var voxelMap: [SIMD3<Int>: UInt32] = [:]
        var newVertices: [SIMD3<Float>] = []
        var vertexMapping: [UInt32: UInt32] = [:]
        
        // Process each vertex
        for (oldIndex, vertex) in vertices.enumerated() {
            // Compute voxel grid coordinate
            let voxelKey = SIMD3<Int>(
                Int(vertex.x / voxelSize),
                Int(vertex.y / voxelSize),
                Int(vertex.z / voxelSize)
            )
            
            if let existingIndex = voxelMap[voxelKey] {
                // Reuse existing vertex in this voxel
                vertexMapping[UInt32(oldIndex)] = existingIndex
            } else {
                // Create new vertex
                let newIndex = UInt32(newVertices.count)
                newVertices.append(vertex)
                voxelMap[voxelKey] = newIndex
                vertexMapping[UInt32(oldIndex)] = newIndex
            }
        }
        
        // Remap indices and remove degenerate triangles
        var newIndices: [UInt32] = []
        let triangleCount = indices.count / 3
        
        for i in 0..<triangleCount {
            let i0 = vertexMapping[indices[i * 3]] ?? 0
            let i1 = vertexMapping[indices[i * 3 + 1]] ?? 0
            let i2 = vertexMapping[indices[i * 3 + 2]] ?? 0
            
            // Skip degenerate triangles (all vertices collapsed to same point)
            if i0 != i1 && i1 != i2 && i0 != i2 {
                newIndices.append(i0)
                newIndices.append(i1)
                newIndices.append(i2)
            }
        }
        
        return (newVertices, newIndices)
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

// MARK: - Storage Upload Integration

extension CaptureSession {
    
    /// Export mesh data and upload to Spiral Storage
    /// - Parameters:
    ///   - sessionId: Work session ID for organized storage
    ///   - spaceId: Space ID for organized storage
    ///   - progress: Progress callback with (progress: 0-1, status: String)
    ///   - completion: Completion callback with (localURL: URL?, cloudURL: String?)
    func exportAndUploadMeshData(
        sessionId: UUID?,
        spaceId: UUID?,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (URL?, String?) -> Void
    ) {
        // First export locally
        exportMeshData(progress: { exportProgress, status in
            // Export takes 0-80% of total progress
            progress(exportProgress * 0.8, status)
        }, completion: { [weak self] localURL in
            guard let self = self, let localURL = localURL else {
                completion(nil, nil)
                return
            }
            
            // Then upload to cloud (20-100% of progress)
            Task {
                do {
                    progress(0.8, "Uploading to cloud...")
                    
                    let storageService = SpiralStorageService.shared
                    let cloudURL = try await storageService.uploadFileWithRetry(
                        fileURL: localURL,
                        destinationPath: SpiralStorageService.generatePath(
                            for: .scan,
                            fileName: localURL.lastPathComponent,
                            sessionId: sessionId,
                            spaceId: spaceId
                        )
                    ) { uploadProgress in
                        let totalProgress = 0.8 + (uploadProgress * 0.2)
                        progress(totalProgress, "Uploading... \(Int(uploadProgress * 100))%")
                    }
                    
                    progress(1.0, "Upload complete!")
                    completion(localURL, cloudURL)
                    
                } catch {
                    print("[CaptureSession] Upload failed: \(error)")
                    // Still return local URL even if upload fails
                    completion(localURL, nil)
                }
            }
        })
    }
}
