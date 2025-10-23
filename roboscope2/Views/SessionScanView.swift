//
//  SessionScanView.swift
//  roboscope2
//
//  AR scanning view for work sessions
//

import SwiftUI
import RealityKit
import ARKit
import SceneKit

struct SessionScanView: View {
    let session: WorkSession
    let captureSession: CaptureSession  // Shared AR session from parent view
    var onRegistrationComplete: ((simd_float4x4) -> Void)?  // Callback to pass transform back
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spaceService = SpaceService.shared
    @StateObject private var settings = AppSettings.shared
    
    @State private var arView: ARView?
    
    // Scanning state
    @State private var isScanning = false
    @State private var hasScanData = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStatus: String = ""
    @State private var showSuccessMessage = false
    
    // Registration state
    @State private var isRegistering = false
    @State private var registrationProgress: String = ""
    @State private var showRegistrationResult = false
    @State private var registrationMetrics: String = ""
    @State private var transformMatrix: simd_float4x4?
    
    // Reference model state
    @State private var showReferenceModel = false
    @State private var referenceModelAnchor: AnchorEntity?
    @State private var isLoadingModel = false
    
    // Scan model state
    @State private var showScanModel = false
    @State private var scanModelAnchor: AnchorEntity?
    @State private var isLoadingScan = false
    
    var body: some View {
        ZStack {
            ARViewContainer(session: captureSession.session, arView: $arView)
                .ignoresSafeArea()
                .onAppear {
                    // Auto-start scanning when view appears (session already running)
                    startScanning()
                }
                .onDisappear {
                    // Stop scanning but keep the session running for parent view
                    if isScanning {
                        stopScanning()
                    }
                }
            
            // Top bar with Done button
            VStack {
                HStack {
                    Spacer()
                    
                    // Session Context Menu (ellipsis menu)
                    Menu {
                        Toggle(isOn: $showReferenceModel) {
                            Label("Show Reference Model", systemImage: "cube.box")
                        }
                        .onChange(of: showReferenceModel) { oldValue, newValue in
                            if newValue {
                                placeModelAtFrameOrigin()
                            } else {
                                removeReferenceModel()
                            }
                        }
                        
                        Toggle(isOn: $showScanModel) {
                            Label("Show Scanned Model", systemImage: "camera.metering.matrix")
                        }
                        .onChange(of: showScanModel) { oldValue, newValue in
                            if newValue {
                                placeScanModelAtFrameOrigin()
                            } else {
                                removeScanModel()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 8)
                    
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
                
                Spacer()
                
                // Bottom controls
                bottomControls
            }
            
            // Export progress overlay
            if isExporting {
                exportProgressOverlay
            }
            
            // Success message
            if showSuccessMessage {
                successMessageOverlay
            }
            
            // Registration progress overlay
            if isRegistering {
                registrationProgressOverlay
            }
            
            // Registration result overlay
            if showRegistrationResult {
                registrationResultOverlay
            }
            
            // Model loading indicator
            if isLoadingModel {
                modelLoadingOverlay
            }
            
            // Scan loading indicator
            if isLoadingScan {
                scanLoadingOverlay
            }
        }
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControls: some View {
        VStack(spacing: 16) {
            if isScanning {
                // Stop Scan button
                Button(action: stopScanning) {
                    Label("Stop Scan", systemImage: "stop.fill")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .lgCapsule(tint: .red)
            } else if hasScanData {
                // Find Space button
                Button(action: findSpace) {
                    Label("Find Space", systemImage: "magnifyingglass")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .lgCapsule(tint: .blue)
                .disabled(isExporting || isRegistering)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 32)
    }
    
    // MARK: - Export Progress Overlay
    
    private var exportProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView(value: exportProgress)
                .progressViewStyle(.linear)
                .tint(.white)
            
            Text(exportStatus)
                .font(.subheadline)
                .foregroundColor(.white)
            
            Text("\(Int(exportProgress * 100))%")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Success Message Overlay
    
    private var successMessageOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            
            Text("Scan Saved Successfully!")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("Session data updated with scan")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSuccessMessage = false
                }
            }
        }
    }
    
    // MARK: - Registration Progress Overlay
    
    private var registrationProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text(registrationProgress)
                .font(.subheadline)
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
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Registration Result Overlay
    
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
                    // Pass the transform back to parent view
                    if let transform = transformMatrix {
                        onRegistrationComplete?(transform)
                    }
                    // Close the scan view and return to AR session with transform applied
                    dismiss()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Model Loading Overlay
    
    private var modelLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text("Loading reference model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Scan Loading Overlay
    
    private var scanLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text("Loading scanned model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Scanning Actions
    
    private func startScanning() {
        captureSession.startScanning()
        isScanning = true
        hasScanData = false
        print("[SessionScan] Started scanning for session: \(session.id)")
    }
    
    private func stopScanning() {
        captureSession.stopScanning()
        isScanning = false
        hasScanData = true
        print("[SessionScan] Stopped scanning")
    }
    
    private func findSpace() {
        isRegistering = true
        registrationProgress = "Fetching space data..."
        
        Task {
            await performSpaceRegistration()
        }
    }
    
    private func performSpaceRegistration() async {
        let startTime = Date()
        
        // Log registration settings
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[SessionScan] REGISTRATION SETTINGS")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Preset: \(settings.currentPreset.rawValue)")
        print("Model Points: \(settings.modelPointsSampleCount)")
        print("Scan Points: \(settings.scanPointsSampleCount)")
        print("Max Iterations: \(settings.maxICPIterations)")
        print("Convergence Threshold: \(settings.icpConvergenceThreshold)")
        print("AR Pause: \(settings.pauseARDuringRegistration ? "ON" : "OFF")")
        print("Background Loading: \(settings.useBackgroundLoading ? "ON" : "OFF")")
        print("Skip Checks: \(settings.skipModelConsistencyChecks ? "ON" : "OFF")")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // Optionally pause AR session updates during registration for better performance
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
                }
            }
        }
        
        do {
            // Step 1: Fetch the Space data
            let stepStart = Date()
            registrationProgress = "Loading space information..."
            let space = try await spaceService.getSpace(id: session.spaceId)
            
            guard let usdcUrlString = space.modelUsdcUrl,
                  let usdcUrl = URL(string: usdcUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no USDC model"
                    isRegistering = false
                }
                print("[SessionScan] Error: Space has no USDC model")
                return
            }
            
            if settings.showPerformanceLogs {
                print("[SessionScan] Found space: \(space.name)")
                print("[SessionScan] USDC URL: \(usdcUrlString)")
                print("[SessionScan] ⏱️ Step 1 (Fetch space): \(Date().timeIntervalSince(stepStart))s")
            }
            
            // Step 2: Download and load the USDC model
            let downloadStart = Date()
            await MainActor.run {
                registrationProgress = "Downloading space model..."
            }
            
            let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
            
            // Save to temp file with .usdc extension (not .usdz)
            let tempDir = FileManager.default.temporaryDirectory
            let modelPath = tempDir.appendingPathComponent("space_model.usdc")
            try modelData.write(to: modelPath)
            
            if settings.showPerformanceLogs {
                print("[SessionScan] Downloaded USDC model to: \(modelPath)")
                print("[SessionScan] ⏱️ Step 2 (Download model): \(Date().timeIntervalSince(downloadStart))s")
            }
            
            // Step 3: Export the scan mesh to temp file
            let exportStart = Date()
            await MainActor.run {
                registrationProgress = "Exporting scan data..."
            }
            
            let scanPath = await exportScanMesh()
            
            guard let scanPath = scanPath else {
                await MainActor.run {
                    registrationProgress = "Error: Failed to export scan"
                    isRegistering = false
                }
                return
            }
            
            if settings.showPerformanceLogs {
                print("[SessionScan] Exported scan to: \(scanPath)")
                print("[SessionScan] ⏱️ Step 3 (Export scan): \(Date().timeIntervalSince(exportStart))s")
            }
            
            // Step 4: Load both models into SceneKit
            let loadStart = Date()
            await MainActor.run {
                registrationProgress = "Loading models..."
            }
            
            // Load models with settings-controlled options
            let loadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.convertUnitsToMeters: true,
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]
            
            let scanLoadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]
            
            // Load models (optionally on background thread)
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
            
            // Flatten the scene hierarchy to ensure we get all geometry
            let flattenedModelNode = SCNNode()
            flattenModelHierarchy(modelScene.rootNode, into: flattenedModelNode)
            
            let flattenedScanNode = SCNNode()
            flattenModelHierarchy(scanScene.rootNode, into: flattenedScanNode)
            
            if settings.showPerformanceLogs {
                print("[SessionScan] Model node children: \(flattenedModelNode.childNodes.count)")
                print("[SessionScan] Scan node children: \(flattenedScanNode.childNodes.count)")
                print("[SessionScan] ⏱️ Step 4 (Load models): \(Date().timeIntervalSince(loadStart))s")
            }
            
            // Step 5: Extract point clouds
            let extractStart = Date()
            await MainActor.run {
                registrationProgress = "Extracting point clouds..."
            }
            
            // Point sampling from settings
            let modelPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedModelNode,
                sampleCount: settings.modelPointsSampleCount
            )
            let scanPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedScanNode,
                sampleCount: settings.scanPointsSampleCount
            )
            
            if settings.showPerformanceLogs {
                print("[SessionScan] Model points: \(modelPoints.count) (target: \(settings.modelPointsSampleCount))")
                print("[SessionScan] Scan points: \(scanPoints.count) (target: \(settings.scanPointsSampleCount))")
                print("[SessionScan] ⏱️ Step 5 (Extract points): \(Date().timeIntervalSince(extractStart))s")
            }
            
            // Validate we have enough points
            guard !modelPoints.isEmpty else {
                await MainActor.run {
                    registrationProgress = "Error: Could not extract points from space model"
                    isRegistering = false
                }
                print("[SessionScan] Error: Model has no extractable geometry")
                return
            }
            
            guard !scanPoints.isEmpty else {
                await MainActor.run {
                    registrationProgress = "Error: Could not extract points from scan"
                    isRegistering = false
                }
                print("[SessionScan] Error: Scan has no extractable geometry")
                return
            }
            
            guard modelPoints.count > 100 && scanPoints.count > 100 else {
                await MainActor.run {
                    registrationProgress = "Error: Not enough points for registration (model: \(modelPoints.count), scan: \(scanPoints.count))"
                    isRegistering = false
                }
                print("[SessionScan] Error: Insufficient points for registration")
                return
            }
            
            // Step 6: Perform ICP registration
            let registrationStart = Date()
            await MainActor.run {
                registrationProgress = "Running registration algorithm..."
            }
            
            // Use parameters from settings
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
                    isRegistering = false
                }
                return
            }
            
            if settings.showPerformanceLogs {
                print("[SessionScan] Registration complete!")
                print("[SessionScan] RMSE: \(result.rmse)")
                print("[SessionScan] Inliers: \(result.inlierFraction)")
                print("[SessionScan] Transform matrix: \(result.transformMatrix)")
                print("[SessionScan] ⏱️ Step 6 (ICP registration): \(Date().timeIntervalSince(registrationStart))s")
                print("[SessionScan] ⏱️ TOTAL TIME: \(Date().timeIntervalSince(startTime))s")
            }
            
            // Step 7: Apply transformation to AR session
            await MainActor.run {
                transformMatrix = result.transformMatrix
                registrationMetrics = """
                RMSE: \(String(format: "%.3f", result.rmse))m
                Inliers: \(String(format: "%.1f", result.inlierFraction * 100))%
                Iterations: \(result.iterations)
                """
                
                isRegistering = false
                showRegistrationResult = true
                
                // Store transform for callback
                transformMatrix = result.transformMatrix
                
                // Apply transform to AR world coordinate system
                applyTransformToARSession(result.transformMatrix)
            }
            
        } catch {
            await MainActor.run {
                registrationProgress = "Error: \(error.localizedDescription)"
                isRegistering = false
            }
            print("[SessionScan] Registration error: \(error)")
        }
    }
    
    private func exportScanMesh() async -> URL? {
        return await withCheckedContinuation { continuation in
            captureSession.exportMeshData(
                progress: { progress, status in
                    // Progress updates handled by registration progress
                },
                completion: { url in
                    continuation.resume(returning: url)
                }
            )
        }
    }
    
    private func applyTransformToARSession(_ transform: simd_float4x4) {
        guard let arView = arView else { return }
        
        // Create an anchor at the origin with the inverse transform
        // This effectively moves the AR world to align with the space model
        let inverseTransform = transform.inverse
        let anchor = AnchorEntity(world: inverseTransform)
        
        // Store this anchor for later use in the parent view
        arView.scene.addAnchor(anchor)
        
        print("[SessionScan] Applied transform to AR session")
        print("[SessionScan] Transform: \(transform)")
    }
    
    /// Recursively flatten scene hierarchy and collect all geometry nodes
    private func flattenModelHierarchy(_ sourceNode: SCNNode, into targetNode: SCNNode) {
        // If this node has geometry, clone it and add to target
        if let geometry = sourceNode.geometry {
            let clone = sourceNode.clone()
            // Apply the node's transform to get world-space geometry
            clone.transform = sourceNode.worldTransform
            targetNode.addChildNode(clone)
        }
        
        // Recursively process children
        for child in sourceNode.childNodes {
            flattenModelHierarchy(child, into: targetNode)
        }
    }
    
    // MARK: - Reference Model Management
    
    /// Place the reference model at FrameOrigin (the AR camera's initial position and orientation)
    private func placeModelAtFrameOrigin() {
        guard let arView = arView else {
            print("[SessionScan] ARView not available")
            return
        }
        
        // Remove existing model if any
        removeReferenceModel()
        
        isLoadingModel = true
        
        Task {
            do {
                // Fetch space to get model URL
                let space = try await spaceService.getSpace(id: session.spaceId)
                
                guard let usdcUrlString = space.modelUsdcUrl,
                      let usdcUrl = URL(string: usdcUrlString) else {
                    await MainActor.run {
                        print("[SessionScan] Space has no USDC model URL")
                        isLoadingModel = false
                        showReferenceModel = false
                    }
                    return
                }
                
                print("[SessionScan] Loading reference model from: \(usdcUrlString)")
                
                // Download the model
                let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
                
                // Save to temporary file
                let tempDir = FileManager.default.temporaryDirectory
                let modelPath = tempDir.appendingPathComponent("reference_model.usdc")
                try modelData.write(to: modelPath)
                
                // Load the model entity
                let modelEntity = try await ModelEntity.loadModel(contentsOf: modelPath)
                
                await MainActor.run {
                    // Anchor at the current transformMatrix (FrameOrigin in this view)
                    let anchor = AnchorEntity(world: transformMatrix ?? matrix_identity_float4x4)
                    
                    // Add the model to the anchor
                    anchor.addChild(modelEntity)
                    
                    // Store reference and add to scene
                    referenceModelAnchor = anchor
                    arView.scene.addAnchor(anchor)
                    
                    isLoadingModel = false
                    print("[SessionScan] Reference model placed at FrameOrigin")
                }
                
            } catch {
                await MainActor.run {
                    print("[SessionScan] Failed to load reference model: \(error)")
                    isLoadingModel = false
                    showReferenceModel = false
                }
            }
        }
    }
    
    /// Remove the reference model from the scene
    private func removeReferenceModel() {
        guard let anchor = referenceModelAnchor else { return }
        
        arView?.scene.removeAnchor(anchor)
        referenceModelAnchor = nil
        
        print("[SessionScan] Reference model removed")
    }
    
    // MARK: - Scan Model Management
    
    /// Place the scanned model at FrameOrigin (the AR camera's initial position and orientation)
    private func placeScanModelAtFrameOrigin() {
        guard let arView = arView else {
            print("[SessionScan] ARView not available")
            return
        }
        
        // Remove existing scan model if any
        removeScanModel()
        
        isLoadingScan = true
        
        Task {
            do {
                // Fetch space to get scan URL
                let space = try await spaceService.getSpace(id: session.spaceId)
                
                guard let scanUrlString = space.scanUrl,
                      let scanUrl = URL(string: scanUrlString) else {
                    await MainActor.run {
                        print("[SessionScan] Space has no scan URL")
                        isLoadingScan = false
                        showScanModel = false
                    }
                    return
                }
                
                print("[SessionScan] Loading scanned model from: \(scanUrlString)")
                
                // Download the scan
                let (scanData, _) = try await URLSession.shared.data(from: scanUrl)
                
                // Determine file extension from URL
                let fileExtension = scanUrl.pathExtension.lowercased()
                let fileName = "scanned_model.\(fileExtension.isEmpty ? "usdc" : fileExtension)"
                
                // Save to temporary file
                let tempDir = FileManager.default.temporaryDirectory
                let scanPath = tempDir.appendingPathComponent(fileName)
                try scanData.write(to: scanPath)
                
                // Load the model entity
                let scanEntity = try await ModelEntity.loadModel(contentsOf: scanPath)
                
                await MainActor.run {
                    // Anchor at the current transformMatrix (FrameOrigin in this view)
                    let anchor = AnchorEntity(world: transformMatrix ?? matrix_identity_float4x4)
                    
                    // Add the scan to the anchor
                    anchor.addChild(scanEntity)
                    
                    // Store reference and add to scene
                    scanModelAnchor = anchor
                    arView.scene.addAnchor(anchor)
                    
                    isLoadingScan = false
                    print("[SessionScan] Scanned model placed at FrameOrigin")
                }
                
            } catch {
                await MainActor.run {
                    print("[SessionScan] Failed to load scanned model: \(error)")
                    isLoadingScan = false
                    showScanModel = false
                }
            }
        }
    }
    
    /// Remove the scanned model from the scene
    private func removeScanModel() {
        guard let anchor = scanModelAnchor else { return }
        
        arView?.scene.removeAnchor(anchor)
        scanModelAnchor = nil
        
        print("[SessionScan] Scanned model removed")
    }
}

#Preview {
    SessionScanView(
        session: WorkSession(
            id: UUID(),
            spaceId: UUID(),
            sessionType: .inspection,
            status: .active,
            startedAt: Date(),
            completedAt: nil,
            version: 1,
            meta: [:],
            createdAt: Date(),
            updatedAt: Date()
        ),
        captureSession: CaptureSession(),
        onRegistrationComplete: { transform in
            print("Registration complete with transform: \(transform)")
        }
    )
}
