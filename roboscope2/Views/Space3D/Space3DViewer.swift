//
//  Space3DViewer.swift
//  roboscope2
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
        mlModelUrl: nil,
        meta: nil,
        createdAt: Date(),
        updatedAt: Date()
    ))
}
