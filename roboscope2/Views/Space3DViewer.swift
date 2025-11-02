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
    @StateObject private var settings = AppSettings.shared
    @State private var selectedModel: ModelType = .glb
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    // Mode switching
    @State private var currentMode: SpaceMode = .view3D
    @State private var showARView = false
    
    // Model display options
    @State private var showScanModel = true
    @State private var showPrimaryModel = true
    @State private var showGrid = true
    @State private var showAxes = true
    @State private var cameraAction: CameraControlButtons.CameraAction?
    
    // Registration state
    @State private var isRegistering = false
    @State private var registrationProgress: String = ""
    @State private var showRegistrationResult = false
    @State private var registrationMetrics: String = ""
    
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
                // 3D Viewer (full screen)
                modelViewer
            }
            
            // Top bar overlay
            VStack {
                topBar
                Spacer()
                
                // Registration button and progress
                registrationControls
            }
            
            // Registration result overlay
            if showRegistrationResult {
                registrationResultOverlay
            }
        }
        .sheet(isPresented: $showARView) {
            SpaceARView(space: space)
        }
        .onChange(of: showARView) { newValue in
            if !newValue {
                // When AR view is dismissed, switch back to 3D mode
                currentMode = .view3D
            }
        }
        .onAppear {
            // Select first available model, preferring USDC over GLB
            if space.modelUsdcUrl != nil {
                selectedModel = .usdc
            } else if space.scanUrl != nil {
                selectedModel = .scan
            } else if space.modelGlbUrl != nil {
                selectedModel = .glb
            } else if let firstModel = availableModels.first {
                selectedModel = firstModel
            }
        }
    }
    
    // MARK: - Subviews
    
    private var topBar: some View {
        HStack {
            // iOS Standard Segmented Control
            Picker("View Mode", selection: $currentMode) {
                Label("3D View", systemImage: "cube")
                    .tag(SpaceMode.view3D)
                Label("Scan", systemImage: "scanner")
                    .tag(SpaceMode.scan)
            }
            .pickerStyle(.segmented)
            .onChange(of: currentMode) { newMode in
                if newMode == .scan {
                    showARView = true
                }
            }
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .lgCapsule(tint: .white)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }
    
    private var modelViewer: some View {
        ZStack {
            // Always keep the 3D viewer mounted to avoid re-creating the SceneKit view
            CombinedModelViewer(
                space: space,
                cameraAction: $cameraAction,
                showGrid: $showGrid,
                showAxes: $showAxes,
                isLoading: $isLoading,
                isRegistering: $isRegistering,
                registrationProgress: $registrationProgress,
                onRegistrationComplete: { metrics in
                    isRegistering = false
                    registrationMetrics = "RMSE: \(String(format: "%.3f", metrics.rmse))m\nInliers: \(String(format: "%.1f", metrics.inlierFraction * 100))%\nIterations: \(metrics.iterations)"
                    showRegistrationResult = true
                }
            )
            .id(space.id)

            // Loading overlay (blocks interaction)
            if isLoading {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.5)
                    Text("Loading 3D Models...")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Please wait while we load the space and scan models")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            // Error overlay
            if let error = errorMessage {
                Color.black.opacity(0.45).ignoresSafeArea()
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
            }
        }
    }
    
    // MARK: - Registration Controls
    
    private var registrationControls: some View {
        VStack(spacing: 16) {
            if isRegistering {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    
                    Text(registrationProgress)
                        .font(.caption)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    
                    Divider()
                        .background(Color.white.opacity(0.3))
                        .padding(.horizontal, 8)
                    
                    // Settings info
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Preset:")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text(settings.currentPreset.rawValue)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        
                        HStack {
                            Text("Model/Scan Points:")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text("\(settings.modelPointsSampleCount) / \(settings.scanPointsSampleCount)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                        
                        HStack {
                            Text("Max Iterations:")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.7))
                            Spacer()
                            Text("\(settings.maxICPIterations)")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .cornerRadius(12)
            } else if space.modelUsdcUrl != nil && space.scanUrl != nil {
                Button(action: startRegistration) {
                    Label("Register Models", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .lgCapsule(tint: .blue)
            }
        }
        .padding(.bottom, 32)
    }
    
    private var registrationResultOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            
            Text("Registration Complete!")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(registrationMetrics)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Dismiss") {
                withAnimation {
                    showRegistrationResult = false
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Registration Handler
    
    private func startRegistration() {
        guard !isRegistering else { return }
        
        isRegistering = true
        registrationProgress = "Preparing models..."
        
        Task {
            await performRegistration()
        }
    }
    
    private func performRegistration() async {
        // This will be called from the CombinedModelViewer
        // The actual registration logic needs access to the scene nodes
    }
    
    // MARK: - Camera Control Handlers
    
    private func handleCameraAction(_ action: CameraControlButtons.CameraAction) {
        switch action {
        case .toggleGrid:
            showGrid.toggle()
            // Clear action immediately for toggle actions
            DispatchQueue.main.async {
                self.cameraAction = nil
            }
        case .toggleAxes:
            showAxes.toggle()
            // Clear action immediately for toggle actions
            DispatchQueue.main.async {
                self.cameraAction = nil
            }
        default:
            // For camera view changes, set the action to trigger update
            cameraAction = action
            // Clear after a delay to allow the view to update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.cameraAction = nil
            }
        }
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
        // Create ARView without AR session (just 3D rendering)
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.backgroundColor = .black
        arView.environment.background = .color(.black)
        
        // Setup camera for 3D viewing
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
        
        // Add lighting
        let directionalLight = DirectionalLight()
        directionalLight.light.intensity = 3000
        directionalLight.look(at: .zero, from: [2, 2, 2], relativeTo: nil)
        let lightAnchor = AnchorEntity(world: .zero)
        lightAnchor.addChild(directionalLight)
        arView.scene.addAnchor(lightAnchor)
        
        Task {
            await loadModel(into: anchor, arView: arView)
        }
        
        // Enable rotation gestures
        let rotationGesture = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
        arView.addGestureRecognizer(rotationGesture)
        
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
        
        context.coordinator.anchor = anchor
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    private func loadModel(into anchor: AnchorEntity, arView: ARView) async {
        guard let modelURL = URL(string: url) else {
            return
        }
        
        do {
            
            
            // Download the model
            let (data, response) = try await URLSession.shared.data(from: modelURL)
            
            
            
            // Validate minimum file size
            guard data.count > 100 else { return }
            
            // Save to temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: tempURL)
            
            // Verify file was written
            let fileSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64 ?? 0
            
            
            // Check if file is actually USDZ by reading magic bytes
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            let headerData = fileHandle.readData(ofLength: 4)
            fileHandle.closeFile()
            
            let magic = headerData.map { String(format: "%02x", $0) }.joined()
            
            // Try loading with RealityKit first
            
            
            do {
                let entity = try await Entity.load(contentsOf: tempURL)
                
                // Wrap in ModelEntity if needed
                let modelEntity: ModelEntity
                if let model = entity as? ModelEntity {
                    modelEntity = model
                } else {
                    modelEntity = ModelEntity()
                    modelEntity.addChild(entity)
                }
                
                // Center and scale the model
                let bounds = modelEntity.visualBounds(relativeTo: nil)
                let size = bounds.extents
                let maxDimension = max(size.x, size.y, size.z)
                
                if maxDimension > 0 {
                    let scale = 1.0 / maxDimension
                    modelEntity.scale = [scale, scale, scale]
                    
                    // Center the model
                    let center = bounds.center
                    modelEntity.position = -center * scale
                }
                
                await MainActor.run {
                    anchor.addChild(modelEntity)
                }
                
                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)
                
            } catch {
                
                
                // Fall back to SceneKit which has better USDZ support
                do {
                    let scene = try SCNScene(url: tempURL, options: nil)
                    
                    // Create a wrapper to convert SCNScene to RealityKit
                    // Since we can't easily convert, show an error
                    await MainActor.run {}
                    
                    try? FileManager.default.removeItem(at: tempURL)
                    
                } catch {
                    
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
            
        } catch {
            
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        var anchor: AnchorEntity?
        var lastRotation: Float = 0
        
        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard let anchor = anchor else { return }
            
            if gesture.state == .changed {
                let rotation = Float(gesture.rotation)
                let rotationDiff = rotation - lastRotation
                anchor.transform.rotation *= simd_quatf(angle: rotationDiff, axis: [0, 1, 0])
                lastRotation = rotation
            } else if gesture.state == .ended {
                lastRotation = 0
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let anchor = anchor, let view = gesture.view else { return }
            
            let translation = gesture.translation(in: view)
            let rotationX = Float(translation.y) * 0.01
            let rotationY = Float(translation.x) * 0.01
            
            if gesture.state == .changed {
                anchor.transform.rotation *= simd_quatf(angle: rotationY, axis: [0, 1, 0])
                anchor.transform.rotation *= simd_quatf(angle: rotationX, axis: [1, 0, 0])
            }
        }
    }
}

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
                    } else if let mdlObject = object as? MDLObject {
                        let childNode = SCNNode(mdlObject: mdlObject)
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
        
        // Log registration settings
        let settings = AppSettings.shared
        
        
        // Extract point clouds using settings
        await updateProgress("Extracting primary model points...", context: context)
        let primaryPoints = ModelRegistrationService.extractPointCloud(from: primaryNode, sampleCount: AppSettings.shared.modelPointsSampleCount)
        
        await updateProgress("Extracting scan points...", context: context)
        let scanPoints = ModelRegistrationService.extractPointCloud(from: scanNode, sampleCount: AppSettings.shared.scanPointsSampleCount)
        
        // Perform registration using settings
        if let result = await ModelRegistrationService.registerModels(
            modelPoints: primaryPoints,
            scanPoints: scanPoints,
            maxIterations: AppSettings.shared.maxICPIterations,
            convergenceThreshold: Float(AppSettings.shared.icpConvergenceThreshold),
            progressHandler: { progress in
                Task { @MainActor in
                    self.registrationProgress = progress
                }
            }
        ) {
            // Apply transform to primary model with animation
            await MainActor.run {
                let originalPos = primaryNode.position
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
                
                let newPos = primaryNode.position
                let translation = SIMD3<Float>(newPos.x - originalPos.x, newPos.y - originalPos.y, newPos.z - originalPos.z)
                
                let finalTransform = primaryNode.simdTransform
                
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

// MARK: - SCNGeometry Extension for Lines

extension SCNGeometry {
    static func line(from start: SCNVector3, to end: SCNVector3) -> SCNGeometry {
        let vertices: [SCNVector3] = [start, end]
        let indices: [Int32] = [0, 1]
        
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .line,
            primitiveCount: 1,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        return SCNGeometry(sources: [vertexSource], elements: [element])
    }
}

// MARK: - Camera Control Buttons

struct CameraControlButtons: View {
    let onAction: (CameraAction) -> Void
    
    enum CameraAction: Equatable {
        case fitAll
        case topView
        case frontView
        case sideView
        case resetView
        case toggleGrid
        case toggleAxes
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // View presets
            HStack(spacing: 8) {
                controlButton(icon: "cube.fill", title: "Fit All") {
                    onAction(.fitAll)
                }
                
                controlButton(icon: "arrow.up.circle", title: "Top") {
                    onAction(.topView)
                }
                
                controlButton(icon: "arrow.right.circle", title: "Side") {
                    onAction(.sideView)
                }
                
                controlButton(icon: "circle.circle", title: "Front") {
                    onAction(.frontView)
                }
            }
            
            // Display toggles
            HStack(spacing: 8) {
                controlButton(icon: "grid", title: "Grid") {
                    onAction(.toggleGrid)
                }
                
                controlButton(icon: "point.3.connected.trianglepath.dotted", title: "Axes") {
                    onAction(.toggleAxes)
                }
                
                controlButton(icon: "arrow.counterclockwise", title: "Reset") {
                    onAction(.resetView)
                }
            }
        }
        .padding(12)
    }
    
    private func controlButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15))
            .cornerRadius(8)
            .foregroundColor(.white)
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
        scanUrl: "https://example.com/scan.usdc",
        meta: nil,
        createdAt: Date(),
        updatedAt: Date()
    ))
}
