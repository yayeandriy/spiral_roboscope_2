//
//  SpaceARView.swift
//  roboscope2
//
//  AR view for visualizing a Space (independent of sessions)
//

import SwiftUI
import RealityKit
import ARKit

struct SpaceARView: View {
    let space: Space
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var captureSession = CaptureSession()
    @StateObject private var spaceService = SpaceService.shared
    @State private var arView: ARView?
    
    // Mode switching
    @State private var currentMode: SpaceMode = .scan
    @State private var show3DViewer = false
    
    // Scanning state
    @State private var isScanning = false
    @State private var hasScanData = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStatus: String = ""
    @State private var showSuccessMessage = false
    
    // MARK: - Computed Properties
    
    /// Check if the space has any 3D model available for viewing
    private var hasAvailable3DModel: Bool {
        space.modelGlbUrl != nil || space.modelUsdcUrl != nil || space.scanUrl != nil
    }
    
    var body: some View {
        ZStack {
            ARViewContainer(session: captureSession.session, arView: $arView)
                .ignoresSafeArea()
                .onAppear { captureSession.start() }
                .onDisappear { captureSession.stop() }
                .task { await loadPrimaryModelIfAvailable() }
            
            // Top bar with Done button and Mode Switcher
            VStack {
                HStack {
                    // iOS Standard Segmented Control
                    Picker("View Mode", selection: $currentMode) {
                        Label("3D View", systemImage: "cube")
                            .tag(SpaceMode.view3D)
                        Label("Scan", systemImage: "scanner")
                            .tag(SpaceMode.scan)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!hasAvailable3DModel && currentMode == .scan)
                    .onChange(of: currentMode) { newMode in
                        if newMode == .view3D {
                            show3DViewer = true
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
        }
        .sheet(isPresented: $show3DViewer) {
            Space3DViewer(space: space)
        }
        .onChange(of: show3DViewer) { newValue in
            if !newValue {
                // When 3D viewer is dismissed, switch back to scan mode
                currentMode = .scan
            }
        }
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControls: some View {
        VStack(spacing: 16) {
            if !isScanning && !hasScanData {
                // Start Scan button
                Button(action: startScanning) {
                    Label("Start Scan", systemImage: "scanner")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .lgCapsule(tint: .white)
                .disabled(isExporting)
            } else if isScanning {
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
                // Start Again & Save buttons
                HStack(spacing: 12) {
                    Button(action: startAgain) {
                        Label("Start Again", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .lgCapsule(tint: .orange)
                    
                    Button(action: saveToSpace) {
                        Label("Save to Space", systemImage: "arrow.up.doc")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .lgCapsule(tint: .green)
                    .disabled(isExporting)
                }
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
            
            Text("Space data updated with scan URL")
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
    
    // MARK: - Model Loading
    
    private func loadPrimaryModelIfAvailable() async {
        guard let urlString = space.primaryModelUrl,
              let url = URL(string: urlString) else {
            return
        }
        
        do {
            let entity = try await Entity.load(contentsOf: url)
            await MainActor.run {
                if let arView {
                    let anchor = AnchorEntity(world: matrix_identity_float4x4)
                    let model = (entity as? ModelEntity) ?? {
                        let wrapper = ModelEntity()
                        wrapper.addChild(entity)
                        return wrapper
                    }()
                    anchor.addChild(model)
                    arView.scene.addAnchor(anchor)
                }
            }
        } catch {
            print("Failed to load space model: \(error)")
        }
    }
    
    // MARK: - Scanning Actions
    
    private func startScanning() {
        captureSession.startScanning()
        isScanning = true
        hasScanData = false
        print("[SpaceAR] Started scanning")
    }
    
    private func stopScanning() {
        captureSession.stopScanning()
        isScanning = false
        hasScanData = true
        print("[SpaceAR] Stopped scanning")
    }
    
    private func startAgain() {
        hasScanData = false
        isScanning = false
        print("[SpaceAR] Starting new scan")
    }
    
    private func saveToSpace() {
        isExporting = true
        exportProgress = 0.0
        exportStatus = "Preparing scan data..."
        
        print("[SpaceAR] Saving scan to space: \(space.name)")
        
        // Export and upload mesh data
        captureSession.exportAndUploadMeshData(
            sessionId: nil,
            spaceId: space.id,
            progress: { progress, status in
                DispatchQueue.main.async {
                    self.exportProgress = progress
                    self.exportStatus = status
                }
            },
            completion: { localURL, cloudURL in
                DispatchQueue.main.async {
                    self.isExporting = false
                    
                    guard let cloudURL = cloudURL else {
                        print("[SpaceAR] Upload failed - no cloud URL")
                        self.exportStatus = "Upload failed"
                        return
                    }
                    
                    print("[SpaceAR] Scan uploaded: \(cloudURL)")
                    
                    // Update space with scan URL
                    Task {
                        await updateSpaceWithScanUrl(cloudURL)
                    }
                }
            }
        )
    }
    
    private func updateSpaceWithScanUrl(_ scanUrl: String) async {
        do {
            print("[SpaceAR] 🔄 Starting space update...")
            print("[SpaceAR] 📍 Space ID: \(space.id)")
            print("[SpaceAR] 🔗 Scan URL: \(scanUrl)")
            
            let update = UpdateSpace(scanUrl: scanUrl)
            print("[SpaceAR] 📦 Created UpdateSpace DTO")
            
            let updatedSpace = try await spaceService.updateSpace(id: space.id, update: update)
            
            print("[SpaceAR] ✅ Space updated successfully!")
            print("[SpaceAR] 📊 Updated space scan_url: \(updatedSpace.scanUrl ?? "nil")")
            
            await MainActor.run {
                hasScanData = false
                withAnimation {
                    showSuccessMessage = true
                }
            }
            
        } catch {
            print("[SpaceAR] ❌ Failed to update space!")
            print("[SpaceAR] ❌ Error: \(error)")
            print("[SpaceAR] ❌ Error description: \(error.localizedDescription)")
            await MainActor.run {
                exportStatus = "Failed to update space"
            }
        }
    }
}

#Preview {
    SpaceARView(space: Space(
        id: UUID(),
        key: "demo",
        name: "Demo Space",
        description: "",
        modelGlbUrl: nil,
        modelUsdcUrl: nil,
        previewUrl: nil,
        scanUrl: nil,
        meta: nil,
        createdAt: nil,
        updatedAt: nil
    ))
}
