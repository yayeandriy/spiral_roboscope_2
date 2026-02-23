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
    
    @Environment(\.dismiss) var dismiss
    @StateObject var spaceService = SpaceService.shared
    @StateObject var settings = AppSettings.shared
    
    @State var arView: ARView?
    
    // Scanning state
    @State var isScanning = false
    @State var hasScanData = false
    @State var isExporting = false
    @State var exportProgress: Double = 0.0
    @State var exportStatus: String = ""
    @State var showSuccessMessage = false
    
    // Registration state
    @State var isRegistering = false
    @State var registrationProgress: String = ""
    @State var showRegistrationResult = false
    @State var registrationMetrics: String = ""
    @State var transformMatrix: simd_float4x4?
    
    // Reference model state
    @State var showReferenceModel = false
    @State var referenceModelAnchor: AnchorEntity?
    @State var isLoadingModel = false
    
    // Scan model state
    @State var showScanModel = false
    @State var scanModelAnchor: AnchorEntity?
    @State var isLoadingScan = false
    
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
        onRegistrationComplete: { _ in }
    )
}

// MARK: - Moved to extensions:
// bottomControls, overlays → SessionScanView+Overlays.swift
