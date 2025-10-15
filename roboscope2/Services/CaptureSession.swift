//
//  CaptureSession.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import ARKit
import Combine

/// Configures ARKit with scene reconstruction & gravity alignment
final class CaptureSession: NSObject, ObservableObject {
    let session = ARSession()
    
    @Published var isRunning: Bool = false
    @Published var gravityUp: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    
    private var cancellables = Set<AnyCancellable>()
    
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
        
        // Minimal configuration for fast performance
        config.worldAlignment = .gravity
        
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }
    
    func stop() {
        session.pause()
        isRunning = false
    }
    
    func getCurrentWorldOrigin() -> simd_float4x4 {
        return session.currentFrame?.camera.transform ?? .identity
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
        // Mesh anchors will be handled by MeshFusionService
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        // Mesh updates handled by MeshFusionService
    }
}
