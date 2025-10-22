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
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spaceService = SpaceService.shared
    
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
        do {
            // Step 1: Fetch the Space data
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
            
            print("[SessionScan] Found space: \(space.name)")
            print("[SessionScan] USDC URL: \(usdcUrlString)")
            
            // Step 2: Download and load the USDC model
            await MainActor.run {
                registrationProgress = "Downloading space model..."
            }
            
            let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
            
            // Save to temp file with .usdc extension (not .usdz)
            let tempDir = FileManager.default.temporaryDirectory
            let modelPath = tempDir.appendingPathComponent("space_model.usdc")
            try modelData.write(to: modelPath)
            
            print("[SessionScan] Downloaded USDC model to: \(modelPath)")
            
            // Step 3: Export the scan mesh to temp file
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
            
            print("[SessionScan] Exported scan to: \(scanPath)")
            
            // Step 4: Load both models into SceneKit
            await MainActor.run {
                registrationProgress = "Loading models..."
            }
            
            // Load USDC model with proper options for geometry extraction
            let modelScene = try SCNScene(url: modelPath, options: [
                SCNSceneSource.LoadingOption.convertUnitsToMeters: true,
                SCNSceneSource.LoadingOption.flattenScene: true
            ])
            
            let scanScene = try SCNScene(url: scanPath, options: [
                SCNSceneSource.LoadingOption.flattenScene: true
            ])
            
            // Flatten the scene hierarchy to ensure we get all geometry
            let flattenedModelNode = SCNNode()
            flattenModelHierarchy(modelScene.rootNode, into: flattenedModelNode)
            
            let flattenedScanNode = SCNNode()
            flattenModelHierarchy(scanScene.rootNode, into: flattenedScanNode)
            
            print("[SessionScan] Model node children: \(flattenedModelNode.childNodes.count)")
            print("[SessionScan] Scan node children: \(flattenedScanNode.childNodes.count)")
            
            // Step 5: Extract point clouds
            await MainActor.run {
                registrationProgress = "Extracting point clouds..."
            }
            
            let modelPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedModelNode,
                sampleCount: 10000
            )
            let scanPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedScanNode,
                sampleCount: 10000
            )
            
            print("[SessionScan] Model points: \(modelPoints.count)")
            print("[SessionScan] Scan points: \(scanPoints.count)")
            
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
            await MainActor.run {
                registrationProgress = "Running registration algorithm..."
            }
            
            guard let result = await ModelRegistrationService.registerModels(
                modelPoints: modelPoints,
                scanPoints: scanPoints,
                maxIterations: 50,
                convergenceThreshold: 0.0001,
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
            
            print("[SessionScan] Registration complete!")
            print("[SessionScan] RMSE: \(result.rmse)")
            print("[SessionScan] Inliers: \(result.inlierFraction)")
            print("[SessionScan] Transform matrix: \(result.transformMatrix)")
            
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
        captureSession: CaptureSession()
    )
}
