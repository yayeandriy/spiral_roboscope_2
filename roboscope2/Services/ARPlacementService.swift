//
//  ARPlacementService.swift
//  roboscope2
//
//  Created by AI Assistant on 15.10.2025.
//

import RealityKit
import ARKit
import Combine

/// Holds a ModelEntity and applies pose in AR world space
final class ARPlacementService: ObservableObject {
    weak var arView: ARView?
    @Published var modelEntity: ModelEntity?
    private var modelAnchor: AnchorEntity?
    
    func loadModel(named: String) async throws {
        guard let resourceURL = Bundle.main.url(forResource: named, withExtension: "usdc") else {
            throw NSError(domain: "ARPlacementService", code: 0,
                         userInfo: [NSLocalizedDescriptionKey: "Could not find \(named).usdc in bundle"])
        }
        let loadedEntity = try await Entity.load(contentsOf: resourceURL)
        guard let entity = loadedEntity as? ModelEntity else {
            throw NSError(domain: "ARPlacementService", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Loaded entity is not a ModelEntity"])
        }
        entity.generateCollisionShapes(recursive: true)
        
        await MainActor.run {
            self.modelEntity = entity
        }
    }
    
    func apply(pose: simd_float4x4) {
        guard let arView = arView, let modelEntity = modelEntity else { return }
        
        // Remove previous anchor if exists
        if let oldAnchor = modelAnchor {
            arView.scene.removeAnchor(oldAnchor)
        }
        
        // Create new anchor at pose
        let anchor = AnchorEntity(world: pose)
        anchor.addChild(modelEntity)
        arView.scene.addAnchor(anchor)
        
        modelAnchor = anchor
    }
    
    func removeModel() {
        guard let arView = arView, let anchor = modelAnchor else { return }
        arView.scene.removeAnchor(anchor)
        modelAnchor = nil
    }
}
