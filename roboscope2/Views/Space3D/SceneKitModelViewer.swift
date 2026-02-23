//
//  SceneKitModelViewer.swift
//  roboscope2
//

import SwiftUI
import SceneKit
import ModelIO

// MARK: - SceneKit Model Viewer (for GLB, OBJ, and other formats)

struct SceneKitModelViewer: UIViewRepresentable {
    let url: String
    let fileExtension: String
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = .black
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.antialiasingMode = .multisampling4X
        
        let newScene = SCNScene()
        sceneView.scene = newScene
        
        // Setup camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 3)
        newScene.rootNode.addChildNode(cameraNode)
        
        // Add lighting
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .omni
        lightNode.position = SCNVector3(x: 0, y: 10, z: 10)
        newScene.rootNode.addChildNode(lightNode)
        
        let ambientLightNode = SCNNode()
        ambientLightNode.light = SCNLight()
        ambientLightNode.light?.type = .ambient
        ambientLightNode.light?.color = UIColor.white.withAlphaComponent(0.3)
        newScene.rootNode.addChildNode(ambientLightNode)
        
        Task {
            await loadModel(into: newScene, sceneView: sceneView)
        }
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {}
    
    private func loadModel(into scene: SCNScene, sceneView: SCNView) async {
        guard let modelURL = URL(string: url) else {
            return
        }
        
        do {
            
            
            // Download the model file
            let (data, response) = try await URLSession.shared.data(from: modelURL)
            
            
            
            // Save to temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: tempURL)
            
            
            
            // Verify file exists and has content
            let fileExists = FileManager.default.fileExists(atPath: tempURL.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = attributes?[.size] as? Int64 ?? 0
            
            
            // Create a container node
            let node = SCNNode()
            
            // Try loading with MDLAsset first
            let asset = MDLAsset(url: tempURL)
            
            if asset.count > 0 {
                // MDLAsset found objects
                
                for index in 0..<asset.count {
                    let object = asset.object(at: index)
                    
                    
                    // Try different object types
                    if let mesh = object as? MDLMesh {
                        let childNode = SCNNode(mdlObject: mesh)
                        node.addChildNode(childNode)
                        
                    } else if let mdlObject = object as? MDLObject {
                        // Try converting any MDLObject to SCNNode
                        let childNode = SCNNode(mdlObject: mdlObject)
                        node.addChildNode(childNode)
                        
                    } else {
                        
                    }
                }
                
                // If MDLAsset didn't work well, try SCNScene as fallback for USDC
                if node.childNodes.isEmpty && (fileExtension.lowercased() == "usdc" || fileExtension.lowercased() == "usdz") {
                    
                    if let loadedScene = try? SCNScene(url: tempURL, options: nil) {
                        for child in loadedScene.rootNode.childNodes {
                            node.addChildNode(child.clone())
                        }
                        
                    }
                }
            } else if fileExtension.lowercased() == "usdz" || fileExtension.lowercased() == "usdc" {
                
                
                // Check file signature
                let fileHandle = try FileHandle(forReadingFrom: tempURL)
                let headerData = fileHandle.readData(ofLength: 4)
                fileHandle.closeFile()
                let magic = headerData.map { String(format: "%02x", $0) }.joined()
                
                // USDZ files are ZIP archives (magic: 504b), USDC files start with PXR- (50 58 52 2d)
                let isZip = magic.hasPrefix("504b")
                let isUSDC = magic.hasPrefix("5058522d") // PXR-
                
                if fileExtension.lowercased() == "usdz" && !isZip {
                } else if fileExtension.lowercased() == "usdc" && !isUSDC {
                }
                
                if !isZip && !isUSDC {
                    
                    
                    await MainActor.run {
                        let errorText = SCNText(string: "Invalid USDZ file\nFile is corrupted", extrusionDepth: 0.05)
                        errorText.font = UIFont.systemFont(ofSize: 0.3)
                        errorText.alignmentMode = CATextLayerAlignmentMode.center.rawValue
                        errorText.firstMaterial?.diffuse.contents = UIColor.red
                        let errorNode = SCNNode(geometry: errorText)
                        errorNode.position = SCNVector3(x: -1, y: 0, z: 0)
                        scene.rootNode.addChildNode(errorNode)
                    }
                    
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
                
                do {
                    let loadedScene = try SCNScene(url: tempURL, options: [
                        .checkConsistency: true,
                        .createNormalsIfAbsent: true
                    ])
                    
                    
                    // Add all children from the loaded scene
                    for child in loadedScene.rootNode.childNodes {
                        node.addChildNode(child.clone())
                    }
                    
                    if node.childNodes.isEmpty {
                        
                        // Sometimes USDZ has nested structure
                        func addAllChildren(from parent: SCNNode, to target: SCNNode) {
                            for child in parent.childNodes {
                                target.addChildNode(child.clone())
                                if child.childNodes.count > 0 {
                                    addAllChildren(from: child, to: target)
                                }
                            }
                        }
                        addAllChildren(from: loadedScene.rootNode, to: node)
                    }
                    
                    if node.childNodes.isEmpty {
                        
                        
                        await MainActor.run {
                            let errorText = SCNText(string: "Empty USDZ file\nNo geometry found", extrusionDepth: 0.05)
                            errorText.font = UIFont.systemFont(ofSize: 0.3)
                            errorText.alignmentMode = CATextLayerAlignmentMode.center.rawValue
                            errorText.firstMaterial?.diffuse.contents = UIColor.orange
                            let errorNode = SCNNode(geometry: errorText)
                            errorNode.position = SCNVector3(x: -1.5, y: 0, z: 0)
                            scene.rootNode.addChildNode(errorNode)
                        }
                        
                        try? FileManager.default.removeItem(at: tempURL)
                        return
                    }
                    
                    
                } catch {
                    
                    
                    await MainActor.run {
                        let errorText = SCNText(string: "USDZ load failed\n\(error.localizedDescription)", extrusionDepth: 0.05)
                        errorText.font = UIFont.systemFont(ofSize: 0.25)
                        errorText.alignmentMode = CATextLayerAlignmentMode.center.rawValue
                        errorText.firstMaterial?.diffuse.contents = UIColor.red
                        let errorNode = SCNNode(geometry: errorText)
                        errorNode.position = SCNVector3(x: -1.5, y: 0, z: 0)
                        scene.rootNode.addChildNode(errorNode)
                    }
                    
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
            } else if fileExtension.lowercased() == "glb" {
                
                
                // Try SCNScene with all available options
                let loadOptions: [SCNSceneSource.LoadingOption: Any] = [
                    .checkConsistency: true,
                    .flattenScene: false,
                    .createNormalsIfAbsent: true,
                    .preserveOriginalTopology: false
                ]
                
                do {
                    let loadedScene = try SCNScene(url: tempURL, options: loadOptions)
                    
                    if loadedScene.rootNode.childNodes.isEmpty {
                        
                        
                        // Try using SCNSceneSource for more control
                        let sceneSource = SCNSceneSource(url: tempURL, options: nil)
                        if let sceneSource = sceneSource {
                            let entryIDs = sceneSource.identifiersOfEntries(withClass: SCNNode.self)
                            
                            for identifier in entryIDs {
                                if let entry = sceneSource.entryWithIdentifier(identifier, withClass: SCNNode.self) as? SCNNode {
                                    node.addChildNode(entry)
                                }
                            }
                        }
                    } else {
                        for child in loadedScene.rootNode.childNodes {
                            node.addChildNode(child.clone())
                        }
                        
                    }
                    
                    if node.childNodes.isEmpty {
                        
                        await MainActor.run {
                            // Show a placeholder or error
                            let errorGeometry = SCNText(string: "GLB Load Failed", extrusionDepth: 0.1)
                            errorGeometry.font = UIFont.systemFont(ofSize: 0.5)
                            let errorNode = SCNNode(geometry: errorGeometry)
                            scene.rootNode.addChildNode(errorNode)
                        }
                        try? FileManager.default.removeItem(at: tempURL)
                        return
                    }
                } catch {
                    
                    
                    await MainActor.run {
                        // Show a helpful error message
                        let errorText = SCNText(string: "GLB format not supported\nUse USDZ instead", extrusionDepth: 0.05)
                        errorText.font = UIFont.systemFont(ofSize: 0.3)
                        errorText.alignmentMode = CATextLayerAlignmentMode.center.rawValue
                        errorText.firstMaterial?.diffuse.contents = UIColor.orange
                        let errorNode = SCNNode(geometry: errorText)
                        errorNode.position = SCNVector3(x: -1, y: 0, z: 0)
                        scene.rootNode.addChildNode(errorNode)
                    }
                    
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }
            } else {
                
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            
            // Calculate bounds and center the model
            let (minBound, maxBound) = node.boundingBox
            let center = SCNVector3(
                x: (minBound.x + maxBound.x) / 2,
                y: (minBound.y + maxBound.y) / 2,
                z: (minBound.z + maxBound.z) / 2
            )
            
            // Calculate scale to fit in view
            let size = SCNVector3(
                x: maxBound.x - minBound.x,
                y: maxBound.y - minBound.y,
                z: maxBound.z - minBound.z
            )
            let maxDimension = max(size.x, max(size.y, size.z))
            
            if maxDimension > 0 {
                let scale = Float(2.0 / maxDimension)
                
                // Apply transformations
                node.position = SCNVector3(x: -center.x * scale, y: -center.y * scale, z: -center.z * scale)
                node.scale = SCNVector3(x: scale, y: scale, z: scale)
            }
            
            // Only add node if it has actual content
            guard !node.childNodes.isEmpty else {
                await MainActor.run {
                    let errorText = SCNText(string: "No 3D content\nFile may be empty", extrusionDepth: 0.05)
                    errorText.font = UIFont.systemFont(ofSize: 0.3)
                    errorText.alignmentMode = CATextLayerAlignmentMode.center.rawValue
                    errorText.firstMaterial?.diffuse.contents = UIColor.red
                    let errorNode = SCNNode(geometry: errorText)
                    errorNode.position = SCNVector3(x: -1, y: 0, z: 0)
                    scene.rootNode.addChildNode(errorNode)
                }
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            
            await MainActor.run {
                scene.rootNode.addChildNode(node)
            }
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)
            
        } catch {
        }
    }
}
