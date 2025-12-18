//
//  ARSessionView+Models.swift
//  roboscope2
//
//  Reference and Scan model placement/update helpers
//

import SwiftUI
import RealityKit

extension ARSessionView {
    // MARK: - Reference Model Management
    func placeModelAtFrameOrigin() {
        guard let arView = arView else { return }
        // Create or replace the reference model anchor at the current frame origin transform
        if let existing = referenceModelAnchor { arView.scene.removeAnchor(existing) }
        let anchor = AnchorEntity(world: frameOriginTransform)
        // Simple placeholder geometry to visualize the reference model
        let model = ModelEntity()
        model.name = "referenceModel"
        let box = MeshResource.generateBox(size: 0.05)
        model.model = ModelComponent(mesh: box, materials: [SimpleMaterial(color: .blue.withAlphaComponent(0.3), isMetallic: false)])
        anchor.addChild(model)
        referenceModelEntity = model
        arView.scene.addAnchor(anchor)
        referenceModelAnchor = anchor
    }

    func removeReferenceModel() {
        guard let arView = arView else { return }
        if let anchor = referenceModelAnchor { arView.scene.removeAnchor(anchor) }
        referenceModelAnchor = nil
        referenceModelEntity = nil
    }

    func updateReferenceModelPosition() {
        // Keep the reference model anchor aligned to the frame origin
        referenceModelAnchor?.transform = Transform(matrix: frameOriginTransform)
    }

    // MARK: - Scan Model Management
    func placeScanModelAtFrameOrigin() {
        guard let arView = arView else { return }
        if let existing = scanModelAnchor { arView.scene.removeAnchor(existing) }
        let anchor = AnchorEntity(world: frameOriginTransform)
        // Placeholder geometry for scan model
        let model = ModelEntity()
        model.name = "scanModel"
        let box = MeshResource.generateBox(size: 0.05)
        model.model = ModelComponent(mesh: box, materials: [SimpleMaterial(color: .green.withAlphaComponent(0.3), isMetallic: false)])
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        scanModelAnchor = anchor
    }

    func removeScanModel() {
        guard let arView = arView else { return }
        if let anchor = scanModelAnchor { arView.scene.removeAnchor(anchor) }
        scanModelAnchor = nil
    }

    func updateScanModelPosition() {
        scanModelAnchor?.transform = Transform(matrix: frameOriginTransform)
    }
}

extension LaserGuideARSessionView {
    // MARK: - Reference Model Management
    func placeModelAtFrameOrigin() {
        guard let arView = arView else { return }
        // Create or replace the reference model anchor at the current frame origin transform
        if let existing = referenceModelAnchor { arView.scene.removeAnchor(existing) }
        let anchor = AnchorEntity(world: frameOriginTransform)
        // Simple placeholder geometry to visualize the reference model
        let model = ModelEntity()
        model.name = "referenceModel"
        let box = MeshResource.generateBox(size: 0.05)
        model.model = ModelComponent(mesh: box, materials: [SimpleMaterial(color: .blue.withAlphaComponent(0.3), isMetallic: false)])
        anchor.addChild(model)
        referenceModelEntity = model
        arView.scene.addAnchor(anchor)
        referenceModelAnchor = anchor
    }

    func removeReferenceModel() {
        guard let arView = arView else { return }
        if let anchor = referenceModelAnchor { arView.scene.removeAnchor(anchor) }
        referenceModelAnchor = nil
        referenceModelEntity = nil
    }

    func updateReferenceModelPosition() {
        // Keep the reference model anchor aligned to the frame origin
        referenceModelAnchor?.transform = Transform(matrix: frameOriginTransform)
    }

    // MARK: - Scan Model Management
    func placeScanModelAtFrameOrigin() {
        guard let arView = arView else { return }
        if let existing = scanModelAnchor { arView.scene.removeAnchor(existing) }
        let anchor = AnchorEntity(world: frameOriginTransform)
        // Placeholder geometry for scan model
        let model = ModelEntity()
        model.name = "scanModel"
        let box = MeshResource.generateBox(size: 0.05)
        model.model = ModelComponent(mesh: box, materials: [SimpleMaterial(color: .green.withAlphaComponent(0.3), isMetallic: false)])
        anchor.addChild(model)
        arView.scene.addAnchor(anchor)
        scanModelAnchor = anchor
    }

    func removeScanModel() {
        guard let arView = arView else { return }
        if let anchor = scanModelAnchor { arView.scene.removeAnchor(anchor) }
        scanModelAnchor = nil
    }

    func updateScanModelPosition() {
        scanModelAnchor?.transform = Transform(matrix: frameOriginTransform)
    }
}
