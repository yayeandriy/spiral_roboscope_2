//
//  ARSessionView+Registration.swift
//  roboscope2
//
//  Saved scan registration workflow and helpers
//

import SwiftUI
import SceneKit
import ARKit

extension ARSessionView {
    // MARK: - Saved Scan Registration
    func useSavedScan() async {
        let startTime = Date()
        isRegistering = true
        
    //
        
        // Optionally pause AR session during registration
        if settings.pauseARDuringRegistration {
            await MainActor.run {
                captureSession.session.pause()
            }
        }
        
        defer {
            // Resume AR session if it was paused
            if settings.pauseARDuringRegistration {
                Task { @MainActor in
                    captureSession.session.run(captureSession.session.configuration!)
                    isRegistering = false
                }
            } else {
                Task { @MainActor in
                    isRegistering = false
                }
            }
        }
        
        do {
            // Step 1: Fetch the Space data
            let stepStart = Date()
            await MainActor.run {
                registrationProgress = "Loading space information..."
            }
            
            let space = try await spaceService.getSpace(id: session.spaceId)
            
            guard let usdcUrlString = space.modelUsdcUrl,
                  let usdcUrl = URL(string: usdcUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no USDC model"
                    errorMessage = "Space has no USDC model"
                }
                return
            }
            
            guard let scanUrlString = space.scanUrl,
                  let scanUrl = URL(string: scanUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no saved scan"
                    errorMessage = "Space has no saved scan"
                }
                return
            }
            
            
            
            // Step 2: Download USDC model
            let downloadStart = Date()
            await MainActor.run {
                registrationProgress = "Downloading space model..."
            }
            
            let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
            let tempDir = FileManager.default.temporaryDirectory
            let modelPath = tempDir.appendingPathComponent("space_model.usdc")
            try modelData.write(to: modelPath)
            
            
            
            // Step 3: Download saved scan
            let scanDownloadStart = Date()
            await MainActor.run {
                registrationProgress = "Downloading saved scan..."
            }
            
            let (scanData, _) = try await URLSession.shared.data(from: scanUrl)
            let scanPath = tempDir.appendingPathComponent("saved_scan.usdc")
            try scanData.write(to: scanPath)
            
            
            
            // Step 4: Load both models into SceneKit
            let loadStart = Date()
            await MainActor.run {
                registrationProgress = "Loading models..."
            }
            
            let loadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.convertUnitsToMeters: true,
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]
            
            let scanLoadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]
            
            let (modelScene, scanScene): (SCNScene, SCNScene)
            if settings.useBackgroundLoading {
                (modelScene, scanScene) = await Task.detached(priority: .userInitiated) {
                    let modelScene = try SCNScene(url: modelPath, options: loadOptions)
                    let scanScene = try SCNScene(url: scanPath, options: scanLoadOptions)
                    return (modelScene, scanScene)
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
            let extractStart = Date()
            await MainActor.run {
                registrationProgress = "Extracting point clouds..."
            }
            
            let modelPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedModelNode,
                sampleCount: settings.modelPointsSampleCount
            )
            let scanPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedScanNode,
                sampleCount: settings.scanPointsSampleCount
            )
            
            
            
            guard !modelPoints.isEmpty && !scanPoints.isEmpty else {
                await MainActor.run {
                    registrationProgress = "Error: Could not extract points"
                    errorMessage = "Could not extract points from models"
                }
                return
            }
            
            guard modelPoints.count > 100 && scanPoints.count > 100 else {
                await MainActor.run {
                    registrationProgress = "Error: Not enough points"
                    errorMessage = "Not enough points for registration"
                }
                return
            }
            
            // Step 6: Perform ICP registration
            let registrationStart = Date()
            await MainActor.run {
                registrationProgress = "Running registration algorithm..."
            }
            
            guard let result = await ModelRegistrationService.registerModels(
                modelPoints: modelPoints,
                scanPoints: scanPoints,
                maxIterations: settings.maxICPIterations,
                convergenceThreshold: Float(settings.icpConvergenceThreshold),
                progressHandler: { progress in
                    Task { @MainActor in
                        registrationProgress = progress
                    }
                }
            ) else {
                await MainActor.run {
                    registrationProgress = "Error: Registration failed"
                    errorMessage = "Registration failed"
                }
                return
            }
            
            
            
            // Step 7: Apply transformation
            await MainActor.run {
                frameOriginTransform = result.transformMatrix
                placeFrameOriginGizmo(at: result.transformMatrix)
                updateMarkersForNewFrameOrigin()
                // NOTE: Reference model and scan model positions are automatically
                // updated via frameOriginTransform didSet observer
                
                registrationProgress = "Registration complete!"
                
                // Show brief success message
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isRegistering = false
                }
            }
            
        } catch {
            await MainActor.run {
                registrationProgress = "Error: \(error.localizedDescription)"
                errorMessage = "Registration failed: \(error.localizedDescription)"
            }
            
            
            // Auto-dismiss error after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isRegistering = false
            }
        }
    }
    
    // Helper function to flatten scene hierarchy
    func flattenModelHierarchy(_ node: SCNNode, into container: SCNNode) {
        if let geometry = node.geometry {
            let clone = SCNNode(geometry: geometry)
            clone.transform = node.worldTransform
            container.addChildNode(clone)
        }
        for child in node.childNodes {
            flattenModelHierarchy(child, into: container)
        }
    }
}

extension LaserGuideARSessionView {
    // MARK: - Saved Scan Registration
    func useSavedScan() async {
        let startTime = Date()
        isRegistering = true

        // Optionally pause AR session during registration
        if settings.pauseARDuringRegistration {
            await MainActor.run {
                captureSession.session.pause()
            }
        }

        defer {
            // Resume AR session if it was paused
            if settings.pauseARDuringRegistration {
                Task { @MainActor in
                    captureSession.session.run(captureSession.session.configuration!)
                    isRegistering = false
                }
            } else {
                Task { @MainActor in
                    isRegistering = false
                }
            }
        }

        do {
            // Step 1: Fetch the Space data
            let stepStart = Date()
            await MainActor.run {
                registrationProgress = "Loading space information..."
            }

            let space = try await spaceService.getSpace(id: session.spaceId)

            guard let usdcUrlString = space.modelUsdcUrl,
                  let usdcUrl = URL(string: usdcUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no USDC model"
                    errorMessage = "Space has no USDC model"
                }
                return
            }

            guard let scanUrlString = space.scanUrl,
                  let scanUrl = URL(string: scanUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no saved scan"
                    errorMessage = "Space has no saved scan"
                }
                return
            }

            // Step 2: Download USDC model
            let downloadStart = Date()
            await MainActor.run {
                registrationProgress = "Downloading space model..."
            }

            let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
            let tempDir = FileManager.default.temporaryDirectory
            let modelPath = tempDir.appendingPathComponent("space_model.usdc")
            try modelData.write(to: modelPath)

            // Step 3: Download saved scan
            let scanDownloadStart = Date()
            await MainActor.run {
                registrationProgress = "Downloading saved scan..."
            }

            let (scanData, _) = try await URLSession.shared.data(from: scanUrl)
            let scanPath = tempDir.appendingPathComponent("saved_scan.usdc")
            try scanData.write(to: scanPath)

            // Step 4: Load both models into SceneKit
            let loadStart = Date()
            await MainActor.run {
                registrationProgress = "Loading models..."
            }

            let loadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.convertUnitsToMeters: true,
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]

            let scanLoadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]

            let (modelScene, scanScene): (SCNScene, SCNScene)
            if settings.useBackgroundLoading {
                (modelScene, scanScene) = await Task.detached(priority: .userInitiated) {
                    let modelScene = try SCNScene(url: modelPath, options: loadOptions)
                    let scanScene = try SCNScene(url: scanPath, options: scanLoadOptions)
                    return (modelScene, scanScene)
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
            let extractStart = Date()
            await MainActor.run {
                registrationProgress = "Extracting point clouds..."
            }

            let modelPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedModelNode,
                sampleCount: settings.modelPointsSampleCount
            )
            let scanPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedScanNode,
                sampleCount: settings.scanPointsSampleCount
            )

            guard !modelPoints.isEmpty && !scanPoints.isEmpty else {
                await MainActor.run {
                    registrationProgress = "Error: Could not extract points"
                    errorMessage = "Could not extract points from models"
                }
                return
            }

            guard modelPoints.count > 100 && scanPoints.count > 100 else {
                await MainActor.run {
                    registrationProgress = "Error: Not enough points"
                    errorMessage = "Not enough points for registration"
                }
                return
            }

            // Step 6: Perform ICP registration
            let registrationStart = Date()
            await MainActor.run {
                registrationProgress = "Running registration algorithm..."
            }

            guard let result = await ModelRegistrationService.registerModels(
                modelPoints: modelPoints,
                scanPoints: scanPoints,
                maxIterations: settings.maxICPIterations,
                convergenceThreshold: Float(settings.icpConvergenceThreshold),
                progressHandler: { progress in
                    Task { @MainActor in
                        registrationProgress = progress
                    }
                }
            ) else {
                await MainActor.run {
                    registrationProgress = "Error: Registration failed"
                    errorMessage = "Registration failed"
                }
                return
            }

            // Step 7: Apply transformation
            await MainActor.run {
                frameOriginTransform = result.transformMatrix
                placeFrameOriginGizmo(at: result.transformMatrix)
                updateMarkersForNewFrameOrigin()

                registrationProgress = "Registration complete!"

                // Show brief success message
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isRegistering = false
                }
            }
        } catch {
            await MainActor.run {
                registrationProgress = "Error: \(error.localizedDescription)"
                errorMessage = "Registration failed: \(error.localizedDescription)"
            }

            // Auto-dismiss error after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isRegistering = false
            }
        }

        _ = startTime
    }

    // Helper function to flatten scene hierarchy
    func flattenModelHierarchy(_ node: SCNNode, into container: SCNNode) {
        if let geometry = node.geometry {
            let clone = SCNNode(geometry: geometry)
            clone.transform = node.worldTransform
            container.addChildNode(clone)
        }
        for child in node.childNodes {
            flattenModelHierarchy(child, into: container)
        }
    }
}
