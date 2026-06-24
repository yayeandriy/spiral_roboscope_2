//
//  CombinedModelViewer.swift
//  roboscope2
//

import SwiftUI
import SceneKit
import ARKit
import RealityKit
import ModelIO

// MARK: - Combined Model Viewer (Primary Model + Scan)

struct CombinedModelViewer: UIViewRepresentable {
    let space: Space
    @Binding var cameraAction: CameraControlButtons.CameraAction?
    @Binding var showGrid: Bool
    @Binding var showAxes: Bool
    @Binding var isLoading: Bool
    @Binding var isRegistering: Bool
    @Binding var registrationProgress: String
    let onRegistrationComplete: (ModelRegistrationService.RegistrationResult) -> Void
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = .black
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = false // We'll handle lighting manually
        sceneView.antialiasingMode = .multisampling4X
        
        let newScene = SCNScene()
        sceneView.scene = newScene
        
        // Setup camera with better defaults
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 1000
        cameraNode.camera?.zNear = 0.1
        cameraNode.camera?.fieldOfView = 60
        cameraNode.position = SCNVector3(x: 3, y: 3, z: 3)
        cameraNode.look(at: SCNVector3(x: 0, y: 0, z: 0))
        cameraNode.name = "mainCamera"
        newScene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        
        // Add floor grid
        addFloorGrid(to: newScene)
        
        // Add coordinate axes
        addCoordinateAxes(to: newScene)
        
        // Add comprehensive lighting
        addLighting(to: newScene)
        
        // Store scene in coordinator for camera controls
        context.coordinator.scene = newScene
        context.coordinator.sceneView = sceneView
        
        // Only load models once - prevent infinite loop from isLoading binding changes
        if !context.coordinator.hasLoadedModels {
            context.coordinator.hasLoadedModels = true
            Task {
                await loadModels(into: newScene, sceneView: sceneView, coordinator: context.coordinator)
            }
        }
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        // Handle visibility toggles
        if let scene = context.coordinator.scene {
            scene.rootNode.childNode(withName: "floorGrid", recursively: false)?.isHidden = !showGrid
            scene.rootNode.childNode(withName: "coordinateAxes", recursively: false)?.isHidden = !showAxes
        }
        
        // Handle camera actions - only process if it's different from last action
        if let action = cameraAction, action != context.coordinator.lastCameraAction {
            context.coordinator.lastCameraAction = action
            handleCameraAction(action, context: context)
        }
        
        // Handle registration trigger
        if isRegistering && !context.coordinator.isRegistering {
            context.coordinator.isRegistering = true
            Task {
                await performRegistration(context: context)
            }
        }
    }
    
    private func handleCameraAction(_ action: CameraControlButtons.CameraAction, context: Context) {
        guard let scene = context.coordinator.scene,
              let camera = scene.rootNode.childNode(withName: "mainCamera", recursively: false),
              let bounds = context.coordinator.modelBounds else { return }
        
        let center = SCNVector3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        
        let size = SCNVector3(
            x: bounds.max.x - bounds.min.x,
            y: bounds.max.y - bounds.min.y,
            z: bounds.max.z - bounds.min.z
        )
        
        let maxDimension = max(size.x, max(size.y, size.z))
        let distance = Float(maxDimension * 2.5)
        
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        
        switch action {
        case .fitAll, .resetView:
            camera.position = SCNVector3(
                x: center.x + distance * 0.7,
                y: center.y + distance * 0.7,
                z: center.z + distance * 0.7
            )
            camera.look(at: center)
            
        case .topView:
            camera.position = SCNVector3(
                x: center.x,
                y: center.y + distance,
                z: center.z
            )
            camera.look(at: center)
            
        case .frontView:
            camera.position = SCNVector3(
                x: center.x,
                y: center.y,
                z: center.z + distance
            )
            camera.look(at: center)
            
        case .sideView:
            camera.position = SCNVector3(
                x: center.x + distance,
                y: center.y,
                z: center.z
            )
            camera.look(at: center)
            
        case .toggleGrid:
            // Handled in updateUIView
            break
            
        case .toggleAxes:
            // Handled in updateUIView
            break
        }
        
        SCNTransaction.commit()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var scene: SCNScene?
        var sceneView: SCNView?
        var modelBounds: (min: SCNVector3, max: SCNVector3)?
        var lastCameraAction: CameraControlButtons.CameraAction?
        var primaryModelNode: SCNNode?
        var scanModelNode: SCNNode?
        var isRegistering: Bool = false
        var hasLoadedModels: Bool = false
    }
    
    // MARK: - Scene Setup Helpers
    
    private func addFloorGrid(to scene: SCNScene) {
        let gridSize: CGFloat = 20
        let divisions: Int = 20
        let step = gridSize / CGFloat(divisions)
        
        let gridNode = SCNNode()
        gridNode.name = "floorGrid"
        
        // Create grid lines
        for i in 0...divisions {
            let offset = -gridSize/2 + CGFloat(i) * step
            
            // Lines parallel to X axis
            let lineX = SCNGeometry.line(
                from: SCNVector3(x: Float(-gridSize/2), y: 0, z: Float(offset)),
                to: SCNVector3(x: Float(gridSize/2), y: 0, z: Float(offset))
            )
            lineX.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(i == divisions/2 ? 0.4 : 0.15)
            let lineXNode = SCNNode(geometry: lineX)
            gridNode.addChildNode(lineXNode)
            
            // Lines parallel to Z axis
            let lineZ = SCNGeometry.line(
                from: SCNVector3(x: Float(offset), y: 0, z: Float(-gridSize/2)),
                to: SCNVector3(x: Float(offset), y: 0, z: Float(gridSize/2))
            )
            lineZ.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(i == divisions/2 ? 0.4 : 0.15)
            let lineZNode = SCNNode(geometry: lineZ)
            gridNode.addChildNode(lineZNode)
        }
        
        scene.rootNode.addChildNode(gridNode)
    }
    
    private func addCoordinateAxes(to scene: SCNScene) {
        let axisLength: CGFloat = 2.0
        let axisThickness: CGFloat = 0.02
        
        // X axis (Red)
        let xAxis = SCNCylinder(radius: axisThickness, height: axisLength)
        xAxis.firstMaterial?.diffuse.contents = UIColor.red
        let xAxisNode = SCNNode(geometry: xAxis)
        xAxisNode.eulerAngles = SCNVector3(x: 0, y: 0, z: Float.pi / 2)
        xAxisNode.position = SCNVector3(x: Float(axisLength/2), y: 0, z: 0)
        
        // Y axis (Green)
        let yAxis = SCNCylinder(radius: axisThickness, height: axisLength)
        yAxis.firstMaterial?.diffuse.contents = UIColor.green
        let yAxisNode = SCNNode(geometry: yAxis)
        yAxisNode.position = SCNVector3(x: 0, y: Float(axisLength/2), z: 0)
        
        // Z axis (Blue)
        let zAxis = SCNCylinder(radius: axisThickness, height: axisLength)
        zAxis.firstMaterial?.diffuse.contents = UIColor.blue
        let zAxisNode = SCNNode(geometry: zAxis)
        zAxisNode.eulerAngles = SCNVector3(x: Float.pi / 2, y: 0, z: 0)
        zAxisNode.position = SCNVector3(x: 0, y: 0, z: Float(axisLength/2))
        
        let axesNode = SCNNode()
        axesNode.name = "coordinateAxes"
        axesNode.addChildNode(xAxisNode)
        axesNode.addChildNode(yAxisNode)
        axesNode.addChildNode(zAxisNode)
        
        scene.rootNode.addChildNode(axesNode)
    }
    
    private func addLighting(to scene: SCNScene) {
        // Key light (main directional light)
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.light?.intensity = 1000
        keyLight.light?.castsShadow = true
        keyLight.light?.shadowMode = .deferred
        keyLight.position = SCNVector3(x: 5, y: 10, z: 5)
        keyLight.look(at: SCNVector3(x: 0, y: 0, z: 0))
        scene.rootNode.addChildNode(keyLight)
        
        // Fill light (softer, opposite side)
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .omni
        fillLight.light?.intensity = 500
        fillLight.position = SCNVector3(x: -5, y: 5, z: -5)
        scene.rootNode.addChildNode(fillLight)
        
        // Ambient light (overall illumination)
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 300
        ambientLight.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambientLight)
    }
    
    private func loadModels(into scene: SCNScene, sceneView: SCNView, coordinator: Coordinator) async {
        
        
        // Set loading state
        await MainActor.run {
            isLoading = true
        }
        
        // Load primary model (USDC/GLB)
        if let usdcUrl = space.modelUsdcUrl {
            let fileExt = usdcUrl.hasSuffix(".usdz") ? "usdz" : "usdc"
            
            let node = await loadModel(url: usdcUrl, fileExtension: fileExt, into: scene, offset: SCNVector3(x: 0, y: 0, z: 0), color: nil, nodeName: "primaryModel")
            coordinator.primaryModelNode = node
        } else if let glbUrl = space.modelGlbUrl {
            
            let node = await loadModel(url: glbUrl, fileExtension: "glb", into: scene, offset: SCNVector3(x: 0, y: 0, z: 0), color: nil, nodeName: "primaryModel")
            coordinator.primaryModelNode = node
        }
        
        // Load scan model (USDC/OBJ/GLB)
        if let scanUrl = space.scanUrl {
            let fileExt: String
            if scanUrl.hasSuffix(".usdc") || scanUrl.hasSuffix(".usdz") {
                fileExt = scanUrl.hasSuffix(".usdz") ? "usdz" : "usdc"
            } else if scanUrl.hasSuffix(".glb") {
                fileExt = "glb"
            } else if scanUrl.hasSuffix(".obj") {
                fileExt = "obj"
            } else {
                // Default to usdc for scan files (new format)
                fileExt = "usdc"
            }
            
            let node = await loadModel(url: scanUrl, fileExtension: fileExt, into: scene, offset: SCNVector3(x: 0, y: 0, z: 0), color: UIColor.cyan.withAlphaComponent(0.5), nodeName: "scanModel")
            coordinator.scanModelNode = node
        }
        
        // Calculate bounds and fit camera to view all objects
        await MainActor.run {
            if let bounds = calculateSceneBounds(scene: scene) {
                coordinator.modelBounds = bounds
                fitCameraToShowAll(scene: scene, sceneView: sceneView, bounds: bounds)
            }
            
            // Clear loading state
            isLoading = false
        }
    }
    
    private func calculateSceneBounds(scene: SCNScene) -> (min: SCNVector3, max: SCNVector3)? {
        var minPoint = SCNVector3(x: Float.infinity, y: Float.infinity, z: Float.infinity)
        var maxPoint = SCNVector3(x: -Float.infinity, y: -Float.infinity, z: -Float.infinity)
        var hasGeometry = false
        
        scene.rootNode.enumerateChildNodes { node, _ in
            // Skip grid and axes
            if node.name == "floorGrid" || node.name == "coordinateAxes" {
                return
            }
            
            if node.geometry != nil {
                hasGeometry = true
                let (nodeMin, nodeMax) = node.boundingBox
                let worldMin = node.convertPosition(nodeMin, to: scene.rootNode)
                let worldMax = node.convertPosition(nodeMax, to: scene.rootNode)
                
                minPoint.x = min(minPoint.x, worldMin.x, worldMax.x)
                minPoint.y = min(minPoint.y, worldMin.y, worldMax.y)
                minPoint.z = min(minPoint.z, worldMin.z, worldMax.z)
                
                maxPoint.x = max(maxPoint.x, worldMin.x, worldMax.x)
                maxPoint.y = max(maxPoint.y, worldMin.y, worldMax.y)
                maxPoint.z = max(maxPoint.z, worldMin.z, worldMax.z)
            }
        }
        
        return hasGeometry ? (minPoint, maxPoint) : nil
    }
    
    private func fitCameraToShowAll(scene: SCNScene, sceneView: SCNView, bounds: (min: SCNVector3, max: SCNVector3)) {
        guard let camera = scene.rootNode.childNode(withName: "mainCamera", recursively: false) else { return }
        
        let center = SCNVector3(
            x: (bounds.min.x + bounds.max.x) / 2,
            y: (bounds.min.y + bounds.max.y) / 2,
            z: (bounds.min.z + bounds.max.z) / 2
        )
        
        let size = SCNVector3(
            x: bounds.max.x - bounds.min.x,
            y: bounds.max.y - bounds.min.y,
            z: bounds.max.z - bounds.min.z
        )
        
        let maxDimension = max(size.x, max(size.y, size.z))
        let distance = Float(maxDimension * 2.5) // 2.5x to give some margin
        
        // Position camera at 45-degree angle
        camera.position = SCNVector3(
            x: center.x + distance * 0.7,
            y: center.y + distance * 0.7,
            z: center.z + distance * 0.7
        )
        camera.look(at: center)
        
        
    }
    
    private func loadModel(url: String, fileExtension: String, into scene: SCNScene, offset: SCNVector3, color: UIColor?, nodeName: String) async -> SCNNode? {
        guard let modelURL = URL(string: url) else {
            return nil
        }
        
        do {
            
            
            let (data, _) = try await URLSession.shared.data(from: modelURL)
            
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: tempURL)
            
            let containerNode = SCNNode()
            let asset = MDLAsset(url: tempURL)
            
            if asset.count > 0 {
                for index in 0..<asset.count {
                    let object = asset.object(at: index)
                    
                    if let mesh = object as? MDLMesh {
                        let childNode = SCNNode(mdlObject: mesh)
                        containerNode.addChildNode(childNode)
                    } else {
                        let childNode = SCNNode(mdlObject: object)
                        containerNode.addChildNode(childNode)
                    }
                }
            }
            
            // If MDLAsset didn't produce nodes, try loading as SCNScene (better for USDC/USDZ)
            if containerNode.childNodes.isEmpty {
                if let loadedScene = try? SCNScene(url: tempURL, options: [
                    SCNSceneSource.LoadingOption.convertUnitsToMeters: true,
                    SCNSceneSource.LoadingOption.flattenScene: true
                ]) {
                    for child in loadedScene.rootNode.childNodes {
                        containerNode.addChildNode(child.clone())
                    }
                    
                }
            }
            
            // Apply color if specified (for scan visualization)
            if let color = color {
                containerNode.enumerateChildNodes { node, _ in
                    node.geometry?.firstMaterial?.diffuse.contents = color
                    node.geometry?.firstMaterial?.transparency = color.cgColor.alpha
                }
            }
            
            // Apply offset
            containerNode.position = offset
            containerNode.name = nodeName
            
            await MainActor.run {
                scene.rootNode.addChildNode(containerNode)
            }
            
            try? FileManager.default.removeItem(at: tempURL)
            return containerNode
            
        } catch {
            return nil
        }
    }
    
    // MARK: - Registration
    
    private func performRegistration(context: Context) async {
        guard let primaryNode = context.coordinator.primaryModelNode,
              let scanNode = context.coordinator.scanModelNode else {
            await MainActor.run {
                context.coordinator.isRegistering = false
                isRegistering = false
            }
            return
        }
        
        // Extract point clouds using settings
        await updateProgress("Extracting primary model points...", context: context)
        let primaryPoints = ModelRegistrationService.extractPointCloud(from: primaryNode, sampleCount: 5000)
        
        await updateProgress("Extracting scan points...", context: context)
        let scanPoints = ModelRegistrationService.extractPointCloud(from: scanNode, sampleCount: 10000)
        
        // Perform registration using settings
        if let result = await ModelRegistrationService.registerModels(
            modelPoints: primaryPoints,
            scanPoints: scanPoints,
            maxIterations: 30,
            convergenceThreshold: 0.001,
            progressHandler: { progress in
                Task { @MainActor in
                    self.registrationProgress = progress
                }
            }
        ) {
            // Apply transform to primary model with animation
            await MainActor.run {
                let originalTransform = primaryNode.simdTransform
                
                // The result.transformMatrix is a world-space transform computed from world-space points
                // We need to convert this to the node's local space
                // If the node has a parent, we need: localTransform = parentTransform^-1 * worldTransform
                // But since both models are children of scene.rootNode with no parent transform, we can directly use it
                
                // Use SCNTransaction for smooth animation
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 1.0
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                
                // Compose the registration transform with the current transform
                // New world transform = T_result (world) * originalTransform (world)
                let composedTransform = result.transformMatrix * originalTransform
                primaryNode.simdTransform = composedTransform
                
                SCNTransaction.commit()
                
                context.coordinator.isRegistering = false
                onRegistrationComplete(result)
            }
        } else {
            await MainActor.run {
                context.coordinator.isRegistering = false
                isRegistering = false
            }
        }
    }
    
    private func updateProgress(_ message: String, context: Context) async {
        await MainActor.run {
            registrationProgress = message
        }
    }
}
