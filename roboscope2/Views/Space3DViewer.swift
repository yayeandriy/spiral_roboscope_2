//
//  Space3DViewer.swift
//  roboscope2
//
//  3D model viewer for spaces with support for GLB, USDC, and OBJ scan files
//

import SwiftUI
import RealityKit
import ModelIO
import SceneKit

struct Space3DViewer: View {
    let space: Space
    @Environment(\.dismiss) private var dismiss
    @State private var selectedModel: ModelType = .glb
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    enum ModelType: String, CaseIterable {
        case glb = "GLB"
        case usdc = "USDC"
        case scan = "SCAN"
        
        var color: Color {
            switch self {
            case .glb: return .green
            case .usdc: return .blue
            case .scan: return .orange
            }
        }
    }
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top bar
                topBar
                
                // 3D Viewer
                modelViewer
                
                // Bottom controls
                if availableModels.count > 1 {
                    modelSelector
                }
            }
        }
        .onAppear {
            // Select first available model
            if let firstModel = availableModels.first {
                selectedModel = firstModel
            }
        }
    }
    
    // MARK: - Subviews
    
    private var topBar: some View {
        HStack {
            // Close button
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                    )
            }
            .lgCircle()
            
            Spacer()
            
            // Space name
            VStack(alignment: .trailing, spacing: 2) {
                Text(space.name)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(selectedModel.rawValue)
                    .font(.caption)
                    .foregroundColor(selectedModel.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.3))
    }
    
    private var modelViewer: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("Failed to load model")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                // Show the appropriate viewer based on selected model
                if selectedModel == .scan, let scanUrl = space.scanUrl {
                    OBJModelViewer(url: scanUrl)
                } else if selectedModel == .glb, let glbUrl = space.modelGlbUrl {
                    RealityKitModelViewer(url: glbUrl, fileExtension: "glb")
                } else if selectedModel == .usdc, let usdcUrl = space.modelUsdcUrl {
                    RealityKitModelViewer(url: usdcUrl, fileExtension: "usdz")
                }
            }
        }
    }
    
    private var modelSelector: some View {
        HStack(spacing: 12) {
            ForEach(availableModels, id: \.self) { modelType in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedModel = modelType
                    }
                }) {
                    Text(modelType.rawValue)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(selectedModel == modelType ? .white : modelType.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedModel == modelType ? modelType.color : Color.white.opacity(0.1))
                        )
                }
                .lgCapsule()
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.3))
    }
    
    // MARK: - Computed Properties
    
    private var availableModels: [ModelType] {
        var models: [ModelType] = []
        
        if space.modelGlbUrl != nil {
            models.append(.glb)
        }
        if space.modelUsdcUrl != nil {
            models.append(.usdc)
        }
        if space.scanUrl != nil {
            models.append(.scan)
        }
        
        return models
    }
}

// MARK: - RealityKit Model Viewer (for GLB and USDC)

struct RealityKitModelViewer: UIViewRepresentable {
    let url: String
    let fileExtension: String
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.backgroundColor = .clear
        
        // Setup camera
        let camera = PerspectiveCamera()
        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.position = [0, 0, 3]
        cameraAnchor.look(at: .zero, from: cameraAnchor.position, relativeTo: nil)
        cameraAnchor.addChild(camera)
        
        // Create anchor for the model
        let anchor = AnchorEntity()
        
        // Add anchors to the scene
        arView.scene.addAnchor(anchor)
        arView.scene.addAnchor(cameraAnchor)
        
        Task {
            await loadModel(into: anchor, arView: arView)
        }
        
        // Enable gestures
        arView.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap)))
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    private func loadModel(into anchor: AnchorEntity, arView: ARView) async {
        guard let modelURL = URL(string: url) else { return }
        
        do {
            // Download the model
            let (data, _) = try await URLSession.shared.data(from: modelURL)
            
            // Save to temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: tempURL)
            
            // Load model entity
            let modelEntity = try await ModelEntity(contentsOf: tempURL)
            
            // Center and scale the model
            let bounds = modelEntity.visualBounds(relativeTo: nil)
            let size = bounds.extents
            let maxDimension = max(size.x, size.y, size.z)
            let scale = 1.0 / maxDimension
            modelEntity.scale = [scale, scale, scale]
            
            // Center the model
            let center = bounds.center
            modelEntity.position = -center * scale
            
            await MainActor.run {
                anchor.addChild(modelEntity)
            }
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)
            
        } catch {
            print("[3DViewer] Failed to load model: \(error)")
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            // Handle tap for rotation/interaction
        }
    }
}

// MARK: - OBJ Model Viewer (for Scans)

struct OBJModelViewer: UIViewRepresentable {
    let url: String
    
    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = .clear
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
            await loadOBJModel(into: newScene, sceneView: sceneView)
        }
        
        return sceneView
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {}
    
    private func loadOBJModel(into scene: SCNScene, sceneView: SCNView) async {
        guard let modelURL = URL(string: url) else {
            print("[3DViewer] Invalid URL: \(url)")
            return
        }
        
        do {
            print("[3DViewer] Loading OBJ from: \(modelURL)")
            
            // Download the OBJ file
            let (data, _) = try await URLSession.shared.data(from: modelURL)
            
            // Save to temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("obj")
            try data.write(to: tempURL)
            
            print("[3DViewer] Saved to temp: \(tempURL)")
            
            // Load OBJ using MDLAsset
            let asset = MDLAsset(url: tempURL)
            
            guard let object = asset.object(at: 0) as? MDLMesh else {
                print("[3DViewer] Failed to extract mesh from OBJ")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            
            // Convert to SCNNode
            let node = SCNNode(mdlObject: object)
            
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
            let scale = Float(2.0 / maxDimension)
            
            // Apply transformations
            node.position = SCNVector3(x: -center.x * scale, y: -center.y * scale, z: -center.z * scale)
            node.scale = SCNVector3(x: scale, y: scale, z: scale)
            
            // Add material
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemGray
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.5
            material.metalness.contents = 0.0
            node.geometry?.materials = [material]
            
            await MainActor.run {
                scene.rootNode.addChildNode(node)
                print("[3DViewer] OBJ model loaded successfully")
            }
            
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)
            
        } catch {
            print("[3DViewer] Failed to load OBJ: \(error)")
        }
    }
}

// MARK: - Preview

#Preview {
    Space3DViewer(space: Space(
        id: UUID(),
        key: "preview-space",
        name: "Preview Space",
        description: "Test space with models",
        modelGlbUrl: "https://example.com/model.glb",
        modelUsdcUrl: "https://example.com/model.usdz",
        previewUrl: nil,
        scanUrl: "https://example.com/scan.obj",
        meta: nil,
        createdAt: Date(),
        updatedAt: Date()
    ))
}
