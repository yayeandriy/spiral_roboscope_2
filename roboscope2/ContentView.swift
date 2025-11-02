//
//  ContentView.swift
//  roboscope2
//
//  Created by Andrii Ieroshevych on 14.10.2025.
//

import SwiftUI
import RealityKit
import ARKit

struct ContentView : View {
    @StateObject private var captureSession = CaptureSession()
    @StateObject private var markerService = SpatialMarkerService()
    
    @State private var isExpanded: Bool = false
    @State private var arView: ARView?
    @Namespace private var namespace
    @State private var isHoldingScreen = false
    @State private var isTwoFingers = false
    @State private var moveUpdateTimer: Timer?
    @State private var markerTrackingTimer: Timer?
    
    // Scanning states
    @State private var isScanning = false
    @State private var hasScanData = false
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    
    // Export progress
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStatus: String = ""
    
    // Model placement
    @State private var roomModel: ModelEntity?
    @State private var isModelPlaced = false
    @State private var placedModelAnchor: AnchorEntity?
    
    // Model alignment
    @State private var isAlignmentScanning = false
    @State private var alignmentScanData = false

    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(
                session: captureSession.session,
                arView: $arView
            )
            .edgesIgnoringSafeArea(.all)
            .onAppear {
                // Start AR immediately when view appears
                captureSession.start()
                
                // Load room model
                loadRoomModel()
                
                // Start tracking markers continuously
                markerTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    checkMarkersInTarget()
                }
            }
            .onDisappear {
                markerTrackingTimer?.invalidate()
                markerTrackingTimer = nil
            }
            .onChange(of: arView) { newValue in
                // Connect marker service to AR view
                markerService.arView = newValue
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Single finger - just track holding
                        if !isHoldingScreen {
                            isHoldingScreen = true
                        }
                    }
                    .onEnded { _ in
                        isHoldingScreen = false
                        isTwoFingers = false
                        stopMovingMarker()
                    }
            )
            .simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0)
                    .onChanged { _ in
                        // Two fingers detected
                        if !isTwoFingers {
                            isTwoFingers = true
                            // Try to start moving if a marker is selected
                            if markerService.selectedMarkerID != nil {
                                startMovingMarker()
                            }
                        }
                    }
                    .onEnded { _ in
                        isTwoFingers = false
                        stopMovingMarker()
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3)
                    .onEnded { _ in
                        selectMarkerInTarget()
                    }
            )
            
            // Target overlay (150pt size, 80px from top)
            TargetOverlayView()
                .allowsHitTesting(false)
            
            // Top bar with scan controls
            VStack {
                HStack(spacing: 20.0) {
                    // Send spatial data button (top-left)
                    if hasScanData && !isScanning {
                        Button("Send spatial data") {
                            exportSpatialData()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .lgCapsule(tint: .white)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    
                    Spacer()
                    
                    // Scan/Stop scan button (top-right)
                    Button(isScanning ? "Stop scan" : "Scan") {
                        toggleScanning()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .lgCapsule(tint: isScanning ? .red : .white)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                
                Spacer()
            }
            
            // Bottom buttons - liquid glass style
            VStack {
                Spacer()
                
                HStack(spacing: 20) {
                    // Place Marker Button (bottom-center)
                    Button {
                        placeMarker()
                    } label: {
                        Image(systemName: isTwoFingers ? "hand.tap.fill" : (isHoldingScreen ? "hand.point.up.fill" : "plus"))
                            .font(.system(size: 36))
                            .frame(width: 80, height: 80)
                    }
                    .buttonStyle(.plain)
                    .lgCircle(tint: .white)
                    
                    Spacer()
                    
                    // Fix Model Button (appears when model is placed, bottom-right)
                    if isModelPlaced {
                        Button(isAlignmentScanning ? "Stop scan" : "Fix model") {
                            toggleAlignmentScanning()
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .lgCapsule(tint: isAlignmentScanning ? .red : .orange)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    
                    // Place Model Button (bottom-right)
                    Button {
                        placeRoomModel()
                    } label: {
                        Image(systemName: isModelPlaced ? "cube.fill" : "cube")
                            .font(.system(size: 24))
                            .frame(width: 70, height: 70)
                    }
                    .buttonStyle(.plain)
                    .lgCircle(tint: isModelPlaced ? .green : .white)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 50)
            }
            
            // Export progress overlay
            if isExporting {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView(value: exportProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                            .tint(.white)
                        
                        Text(exportStatus)
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .lgCapsule(tint: .white)
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
    
    private func placeMarker() {
        guard let arView = arView else { return }
        
        // Get screen bounds
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        
        // Target size (150x150 points), positioned higher to match visual position
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200  // Adjusted to match where marker appears
        let halfSize = targetSize / 2
        
        // Calculate 4 corner positions in screen space
        let corners = [
            CGPoint(x: centerX - halfSize, y: targetY - halfSize), // Top-left
            CGPoint(x: centerX + halfSize, y: targetY - halfSize), // Top-right
            CGPoint(x: centerX + halfSize, y: targetY + halfSize), // Bottom-right
            CGPoint(x: centerX - halfSize, y: targetY + halfSize)  // Bottom-left
        ]
        
        markerService.placeMarker(targetCorners: corners)
    }
    
    private func getTargetRect() -> CGRect {
        guard let arView = arView else { return .zero }
        
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200
        
        // Expand target by 10% for detection
        let expandedSize = targetSize * 1.1
        
        return CGRect(
            x: centerX - expandedSize / 2,
            y: targetY - expandedSize / 2,
            width: expandedSize,
            height: expandedSize
        )
    }
    
    private func checkMarkersInTarget() {
        guard let arView = arView else { return }
        
        let targetRect = getTargetRect()
        markerService.updateMarkersInTarget(targetRect: targetRect)
    }
    
    private func selectMarkerInTarget() {
        guard let arView = arView else { return }
        
        let targetRect = getTargetRect()
        markerService.selectMarkerInTarget(targetRect: targetRect)
    }
    
    private func startMovingMarker() {
        guard let arView = arView,
              markerService.selectedMarkerID != nil else { return }
        
        // Start moving the selected marker
        if markerService.startMovingSelectedMarker() {
            // Update marker position continuously while holding
            moveUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
                markerService.updateMovingMarker()
            }
        }
    }
    
    private func stopMovingMarker() {
        moveUpdateTimer?.invalidate()
        moveUpdateTimer = nil
        markerService.stopMovingMarker()
    }
    
    // MARK: - Scanning Functions
    
    private func toggleScanning() {
        if isScanning {
            stopScanning()
        } else {
            startScanning()
        }
    }
    
    private func startScanning() {
        isScanning = true
        hasScanData = false
        captureSession.startScanning()
    }
    
    private func stopScanning() {
        isScanning = false
        captureSession.stopScanning()
        hasScanData = true
    }
    
    private func exportSpatialData() {
        isExporting = true
        exportProgress = 0.0
        exportStatus = "Preparing export..."
        
        captureSession.exportMeshData { progress, status in
            DispatchQueue.main.async {
                self.exportProgress = progress
                self.exportStatus = status
            }
        } completion: { url in
            DispatchQueue.main.async {
                self.isExporting = false
                if let url = url {
                    self.exportURL = url
                    self.showShareSheet = true
                }
            }
        }
    }
    
    // MARK: - Model Placement
    
    private func loadRoomModel() {
        Task {
            do {
                // Try multiple loading approaches
                var entity: Entity?
                
                // Approach 1: Try loading from Models subdirectory
                if let url = Bundle.main.url(forResource: "room", withExtension: "usdc", subdirectory: "Models") {
                    entity = try await Entity.load(contentsOf: url)
                }
                // Approach 2: Try loading from bundle root
                else if let url = Bundle.main.url(forResource: "room", withExtension: "usdc") {
                    entity = try await Entity.load(contentsOf: url)
                }
                // Approach 3: Try named resource (for Reality Composer scenes)
                else {
                    entity = try await Entity.load(named: "room")
                }
                
                guard let loadedEntity = entity else {
                    return
                }
                
                await MainActor.run {
                    if let modelEntity = loadedEntity as? ModelEntity {
                        roomModel = modelEntity
                    } else {
                        // If it's not a ModelEntity, wrap it in one
                        let model = ModelEntity()
                        model.addChild(loadedEntity)
                        roomModel = model
                    }
                }
            } catch {
                // Silent fail; UI can present error state if needed
            }
        }
    }
    
    private func placeRoomModel() {
        guard let arView = arView,
              let model = roomModel else {
            return
        }
        
        // Get camera transform for placement
        guard let cameraTransform = arView.session.currentFrame?.camera.transform else { return }
        
        if isModelPlaced, let anchor = placedModelAnchor {
            // Remove existing model
            arView.scene.removeAnchor(anchor)
            placedModelAnchor = nil
            isModelPlaced = false
            isAlignmentScanning = false
            alignmentScanData = false
            
        } else {
            // Place model at world origin with no rotation (identity)
            // Since the model is now Y-up (matching ARKit), it should appear correctly oriented
            let modelTransform = Transform(
                scale: SIMD3<Float>(1, 1, 1),
                rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), // Identity rotation
                translation: SIMD3<Float>(0, 0, 0) // World origin
            )
            
            // Create anchor and add model clone
            let anchor = AnchorEntity(world: modelTransform.matrix)
            let clonedModel = model.clone(recursive: true)
            anchor.addChild(clonedModel)
            arView.scene.addAnchor(anchor)
            
            placedModelAnchor = anchor
            isModelPlaced = true
            
        }
    }
    
    // MARK: - Model Alignment
    
    private func toggleAlignmentScanning() {
        if isAlignmentScanning {
            stopAlignmentScanning()
        } else {
            startAlignmentScanning()
        }
    }
    
    private func startAlignmentScanning() {
        isAlignmentScanning = true
        alignmentScanData = false
    captureSession.startScanning()
    }
    
    private func stopAlignmentScanning() {
        isAlignmentScanning = false
    captureSession.stopScanning()
        alignmentScanData = true
        
        
        // Start alignment process
        alignModelWithServer()
    }
    
    private func alignModelWithServer() {
        guard let anchor = placedModelAnchor else {
            return
        }
        
        isExporting = true
        exportProgress = 0.0
        exportStatus = "Preparing scan for alignment..."
        
        // Export mesh data for alignment
        captureSession.exportMeshData { progress, status in
            DispatchQueue.main.async {
                self.exportProgress = progress * 0.5 // First 50% for export
                self.exportStatus = status
            }
        } completion: { url in
            guard let url = url else {
                DispatchQueue.main.async {
                    self.isExporting = false
                }
                return
            }
            
            // Send to alignment server (after triggering local network permission if needed)
            Task {
                await withCheckedContinuation { cont in
                    LocalNetworkPermission.shared.request {
                        cont.resume()
                    }
                }
                await self.sendScanToAlignmentServer(scanURL: url, modelAnchor: anchor)
            }
        }
    }
    
    private func sendScanToAlignmentServer(scanURL: URL, modelAnchor: AnchorEntity) async {
        do {
            await MainActor.run {
                exportProgress = 0.5
                exportStatus = "Sending to alignment server..."
            }
            
            // Read scan data
            let scanData = try Data(contentsOf: scanURL)
            
            // TODO: Replace with your actual server URL
            let serverURL = "http://192.168.0.115:6000/align"
            
            // Create request
            var request = URLRequest(url: URL(string: serverURL)!)
            request.httpMethod = "POST"
            request.httpBody = scanData
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30 // 30 second timeout
            
            await MainActor.run {
                exportProgress = 0.6
                exportStatus = "Processing alignment..."
            }
            
            // Send request (first attempt)
            var (data, response) = try await URLSession.shared.data(for: request)

            // If not OK, try a one-time retry after re-triggering permission
            if (response as? HTTPURLResponse)?.statusCode == nil {
                await withCheckedContinuation { cont in
                    LocalNetworkPermission.shared.request { cont.resume() }
                }
                (data, response) = try await URLSession.shared.data(for: request)
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            // Parse response JSON
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            
            // Check for error response (400/500 status codes)
            if let errorMessage = json["error"] as? String {
                await MainActor.run {
                    self.exportStatus = "Server error: \(errorMessage)"
                }
                throw URLError(.badServerResponse)
            }
            
            guard httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            await MainActor.run {
                exportProgress = 0.8
                exportStatus = "Applying transformation..."
            }
            
            // Extract transformation matrix
            guard let matrixArray = json["matrix"] as? [[Double]] else {
                if let matrixFloat = json["matrix"] as? [[Float]] {
                    // Try Float conversion
                    let transform = parseTransformMatrix(from: matrixFloat.map { $0.map { Double($0) } })
                    await MainActor.run {
                        modelAnchor.transform = Transform(matrix: transform)
                        exportProgress = 1.0
                        exportStatus = "Model aligned!"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.isExporting = false
                            self.alignmentScanData = false
                        }
                    }
                    return
                }
                throw URLError(.cannotParseResponse)
            }
            
            // Convert to simd_float4x4
            let modelToScanTransform = parseTransformMatrix(from: matrixArray)
            
            // Apply transformation to model
            // The server returns MODEL→SCAN transform, which is exactly what we need
            // to position the model in the scan's coordinate frame
            await MainActor.run {
                modelAnchor.transform = Transform(matrix: modelToScanTransform)
                
                exportProgress = 1.0
                exportStatus = "Model aligned!"
                
                
                
                // Hide progress after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.isExporting = false
                    self.alignmentScanData = false
                }
            }
            
        } catch {
            await MainActor.run {
                self.isExporting = false
                
                // Show error to user
                self.exportStatus = "Alignment failed: \(error.localizedDescription)"
            }
        }
    }
    
    private func parseTransformMatrix(from matrixArray: [[Double]]) -> simd_float4x4 {
        // Server sends column-major format (perfect for simd_float4x4)
        // Convert Double to Float for simd_float4x4
        let col0 = SIMD4<Float>(Float(matrixArray[0][0]), Float(matrixArray[0][1]), Float(matrixArray[0][2]), Float(matrixArray[0][3]))
        let col1 = SIMD4<Float>(Float(matrixArray[1][0]), Float(matrixArray[1][1]), Float(matrixArray[1][2]), Float(matrixArray[1][3]))
        let col2 = SIMD4<Float>(Float(matrixArray[2][0]), Float(matrixArray[2][1]), Float(matrixArray[2][2]), Float(matrixArray[2][3]))
        let col3 = SIMD4<Float>(Float(matrixArray[3][0]), Float(matrixArray[3][1]), Float(matrixArray[3][2]), Float(matrixArray[3][3]))
        
        return simd_float4x4(columns: (col0, col1, col2, col3))
    }
}

// Extracted TargetOverlayView and ARViewContainer into Views/Common for reuse

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// (Using Apple’s built-in Liquid Glass APIs — no local stubs)

#Preview {
    ContentView()
}

// MARK: - Liquid Glass Helpers (iOS 18+ with graceful fallback)

extension View {
    @ViewBuilder
    func lgCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 18.0, *) {
            let appliedTint = tint ?? .white
            self
                .tint(appliedTint)
                .glassEffect(in: .capsule)
        } else {
            // Fallback for iOS < 18: approximate with material
            let appliedTint = tint ?? .white
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.25)))
                .overlay(Capsule().fill(appliedTint.opacity(0.18)))
        }
    }

    @ViewBuilder
    func lgCircle(tint: Color? = nil) -> some View {
        if #available(iOS 18.0, *) {
            let appliedTint = tint ?? .white
            self
                .tint(appliedTint)
                .glassEffect(in: .circle)
        } else {
            let appliedTint = tint ?? .white
            self
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25)))
                .overlay(Circle().fill(appliedTint.opacity(0.18)))
        }
    }
}
