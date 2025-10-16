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
    
    func exportMeshData(completion: @escaping (URL?) -> Void) {
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
            
            let mdlAsset = MDLAsset()
            
            for anchor in self.meshAnchors {
                let mdlMesh = self.convertARMeshToMDLMesh(anchor.geometry)
                mdlAsset.add(mdlMesh)
            }
            
            // Create export URL
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let exportURL = documentsPath.appendingPathComponent("spatial_scan_\(timestamp).obj")
            
            // Export as OBJ
            do {
                try mdlAsset.export(to: exportURL)
                print("Exported mesh data to: \(exportURL.path)")
                DispatchQueue.main.async {
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
    
    private func convertARMeshToMDLMesh(_ geometry: ARMeshGeometry) -> MDLMesh {
        let vertices = geometry.vertices
        let faces = geometry.faces
        
        let vertexCount = vertices.count
        let vertexStride = vertices.stride
        
        let vertexBuffer = vertices.buffer
        let faceBuffer = faces.buffer
        
        // Create MDL vertex descriptor
        let allocator = MDLMeshBufferDataAllocator()
        
        // Create vertex buffer
        let vertexData = Data(bytes: vertexBuffer.contents(), count: vertexStride * vertexCount)
        let mdlVertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
        
        // Create index buffer
        let indexCount = faces.count * faces.indexCountPerPrimitive
        let indexData = Data(bytes: faceBuffer.contents(), count: indexCount * MemoryLayout<UInt32>.size)
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
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: vertexStride)
        
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
