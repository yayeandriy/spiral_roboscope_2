//
//  SessionScanView.swift
//  roboscope2
//
//  AR scanning view for work sessions
//

import SwiftUI
import RealityKit
import ARKit

struct SessionScanView: View {
    let session: WorkSession
    let captureSession: CaptureSession  // Shared AR session from parent view
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var arView: ARView?
    
    // Scanning state
    @State private var isScanning = false
    @State private var hasScanData = false
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportStatus: String = ""
    @State private var showSuccessMessage = false
    
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
                // Find Space button (placeholder for now)
                Button(action: findSpace) {
                    Label("Find Space", systemImage: "magnifyingglass")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .lgCapsule(tint: .blue)
                .disabled(isExporting)
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
        // Placeholder for Find Space functionality
        print("[SessionScan] Find Space button tapped - functionality to be implemented")
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
