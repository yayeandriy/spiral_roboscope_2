//
//  SessionScanView+Registration.swift
//  roboscope2
//
//  ICP registration pipeline and AR model management for SessionScanView.
//

import SwiftUI
import RealityKit
import ARKit
import SceneKit

extension SessionScanView {

    // MARK: - Registration

    func performSpaceRegistration() async {
        if true {
            await MainActor.run { captureSession.session.pause() }
        }

        defer {
            if true {
                Task { @MainActor in
                    captureSession.session.run(captureSession.session.configuration!)
                }
            }
        }

        do {
            // Step 1: Fetch the Space data
            await MainActor.run { registrationProgress = "Loading space information..." }
            let space = try await spaceService.getSpace(id: session.spaceId)

            guard let usdcUrlString = space.modelUsdcUrl,
                  let usdcUrl = URL(string: usdcUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no Reference model"
                    isRegistering = false
                }
                return
            }

            // Step 2: Download reference model
            await MainActor.run { registrationProgress = "Downloading reference model..." }
            let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
            let tempDir = FileManager.default.temporaryDirectory
            let modelPath = tempDir.appendingPathComponent("space_model.usdc")
            try modelData.write(to: modelPath)

            // Step 3: Export scan mesh
            await MainActor.run { registrationProgress = "Exporting scan data..." }
            let scanPath = await exportScanMesh()
            guard let scanPath else {
                await MainActor.run {
                    registrationProgress = "Error: Failed to export scan"
                    isRegistering = false
                }
                return
            }

            // Step 4: Load both models
            await MainActor.run { registrationProgress = "Loading models..." }
            let loadOptions: [SCNSceneSource.LoadingOption: Any] = [
                .convertUnitsToMeters: true,
                .flattenScene: true,
                .checkConsistency: false
            ]
            let scanLoadOptions: [SCNSceneSource.LoadingOption: Any] = [
                .flattenScene: true,
                .checkConsistency: false
            ]

            let (modelScene, scanScene): (SCNScene, SCNScene)
            if true {
                (modelScene, scanScene) = try await Task.detached(priority: .userInitiated) {
                    let m = try SCNScene(url: modelPath, options: loadOptions)
                    let s = try SCNScene(url: scanPath, options: scanLoadOptions)
                    return (m, s)
                }.value
            } else {
                modelScene = try SCNScene(url: modelPath, options: loadOptions)
                scanScene = try SCNScene(url: scanPath, options: scanLoadOptions)
            }

            let flattenedModelNode = SCNNode()
            flattenModelHierarchy(modelScene.rootNode, into: flattenedModelNode)
            let flattenedScanNode = SCNNode()
            flattenModelHierarchy(scanScene.rootNode, into: flattenedScanNode)

            // Step 5: Extract point clouds
            await MainActor.run { registrationProgress = "Extracting point clouds..." }
            let modelPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedModelNode,
                sampleCount: 5000
            )
            let scanPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedScanNode,
                sampleCount: 10000
            )

            guard !modelPoints.isEmpty else {
                await MainActor.run { registrationProgress = "Error: Could not extract points from space model"; isRegistering = false }
                return
            }
            guard !scanPoints.isEmpty else {
                await MainActor.run { registrationProgress = "Error: Could not extract points from scan"; isRegistering = false }
                return
            }
            guard modelPoints.count > 100 && scanPoints.count > 100 else {
                await MainActor.run {
                    registrationProgress = "Error: Not enough points (model: \(modelPoints.count), scan: \(scanPoints.count))"
                    isRegistering = false
                }
                return
            }

            // Step 6: ICP registration
            await MainActor.run { registrationProgress = "Running registration algorithm..." }
            guard let result = await ModelRegistrationService.registerModels(
                modelPoints: modelPoints,
                scanPoints: scanPoints,
                maxIterations: 30,
                convergenceThreshold: Float(0.001),
                progressHandler: { progress in
                    Task { @MainActor in registrationProgress = progress }
                }
            ) else {
                await MainActor.run { registrationProgress = "Error: Registration failed"; isRegistering = false }
                return
            }

            // Step 7: Apply result
            await MainActor.run {
                transformMatrix = result.transformMatrix
                registrationMetrics = """
                RMSE: \(String(format: "%.3f", result.rmse))m
                Inliers: \(String(format: "%.1f", result.inlierFraction * 100))%
                Iterations: \(result.iterations)
                """
                isRegistering = false
                showRegistrationResult = true
                applyTransformToARSession(result.transformMatrix)
            }

        } catch {
            await MainActor.run {
                registrationProgress = "Error: \(error.localizedDescription)"
                isRegistering = false
            }
        }
    }

    func exportScanMesh() async -> URL? {
        await withCheckedContinuation { continuation in
            captureSession.exportMeshData(
                progress: { _, _ in },
                completion: { url in continuation.resume(returning: url) }
            )
        }
    }

    func applyTransformToARSession(_ transform: simd_float4x4) {
        guard let arView else { return }
        let anchor = AnchorEntity(world: transform.inverse)
        arView.scene.addAnchor(anchor)
    }

    func flattenModelHierarchy(_ sourceNode: SCNNode, into targetNode: SCNNode) {
        if sourceNode.geometry != nil {
            let clone = sourceNode.clone()
            clone.transform = sourceNode.worldTransform
            targetNode.addChildNode(clone)
        }
        for child in sourceNode.childNodes {
            flattenModelHierarchy(child, into: targetNode)
        }
    }

    // MARK: - Reference Model Management

    func placeModelAtFrameOrigin() {
        guard let arView else { return }
        removeReferenceModel()
        isLoadingModel = true

        Task {
            do {
                let space = try await spaceService.getSpace(id: session.spaceId)
                guard let usdcUrlString = space.modelUsdcUrl,
                      let usdcUrl = URL(string: usdcUrlString) else {
                    await MainActor.run { isLoadingModel = false; showReferenceModel = false }
                    return
                }
                let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
                let modelPath = FileManager.default.temporaryDirectory.appendingPathComponent("reference_model.usdc")
                try modelData.write(to: modelPath)
                let modelEntity = try await ModelEntity(contentsOf: modelPath)
                await MainActor.run {
                    let anchor = AnchorEntity(world: transformMatrix ?? matrix_identity_float4x4)
                    anchor.addChild(modelEntity)
                    referenceModelAnchor = anchor
                    arView.scene.addAnchor(anchor)
                    isLoadingModel = false
                }
            } catch {
                await MainActor.run { isLoadingModel = false; showReferenceModel = false }
            }
        }
    }

    func removeReferenceModel() {
        guard let anchor = referenceModelAnchor else { return }
        arView?.scene.removeAnchor(anchor)
        referenceModelAnchor = nil
    }

    // MARK: - Scan Model Management

    func placeScanModelAtFrameOrigin() {
        guard let arView else { return }
        removeScanModel()
        isLoadingScan = true

        Task {
            do {
                let space = try await spaceService.getSpace(id: session.spaceId)
                guard let scanUrlString = space.scanUrl,
                      let scanUrl = URL(string: scanUrlString) else {
                    await MainActor.run { isLoadingScan = false; showScanModel = false }
                    return
                }
                let (scanData, _) = try await URLSession.shared.data(from: scanUrl)
                let fileExtension = scanUrl.pathExtension.lowercased()
                let fileName = "scanned_model.\(fileExtension.isEmpty ? "usdc" : fileExtension)"
                let scanPath = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try scanData.write(to: scanPath)
                let scanEntity = try await ModelEntity(contentsOf: scanPath)
                await MainActor.run {
                    let anchor = AnchorEntity(world: transformMatrix ?? matrix_identity_float4x4)
                    anchor.addChild(scanEntity)
                    scanModelAnchor = anchor
                    arView.scene.addAnchor(anchor)
                    isLoadingScan = false
                }
            } catch {
                await MainActor.run { isLoadingScan = false; showScanModel = false }
            }
        }
    }

    func removeScanModel() {
        guard let anchor = scanModelAnchor else { return }
        arView?.scene.removeAnchor(anchor)
        scanModelAnchor = nil
    }
}
