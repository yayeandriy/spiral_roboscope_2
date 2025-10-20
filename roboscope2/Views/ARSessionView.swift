//
//  ARSessionView.swift
//  roboscope2
//
//  AR view for a specific work session
//

import SwiftUI
import RealityKit
import ARKit

struct ARSessionView: View {
    let session: WorkSession
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var captureSession = CaptureSession()
    @StateObject private var markerService = SpatialMarkerService()
    @StateObject private var workSessionService = WorkSessionService.shared
    @StateObject private var presenceService = PresenceService.shared
    @StateObject private var lockService = LockService.shared
    
    @State private var arView: ARView?
    @State private var isSessionActive = false
    @State private var showingEndSessionAlert = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            ZStack {
                // AR View
                ARViewContainer(
                    session: captureSession.session,
                    arView: $arView
                )
                .edgesIgnoringSafeArea(.all)
                .onAppear {
                    startARSession()
                }
                .onDisappear {
                    endARSession()
                }
                .onChange(of: arView) { newValue in
                    markerService.arView = newValue
                }
                
                // Session Info Overlay
                VStack {
                    sessionInfoCard
                    
                    Spacer()
                    
                    // Controls
                    sessionControls
                }
                .padding()
            }
            .navigationTitle("AR Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("End Session") {
                        showingEndSessionAlert = true
                    }
                    .foregroundColor(.red)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("End Session", isPresented: $showingEndSessionAlert) {
                Button("End Session", role: .destructive) {
                    Task {
                        await completeSession()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to end this session? This will mark it as completed.")
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
        .navigationBarBackButtonHidden()
    }
    
    // MARK: - Session Info Card
    
    private var sessionInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: session.sessionType.icon)
                    .foregroundColor(.blue)
                
                Text(session.sessionType.displayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                StatusBadge(status: session.status)
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Users")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(presenceService.activeUsers.count)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Markers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(markerService.markers.count)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Session Controls
    
    private var sessionControls: some View {
        HStack(spacing: 16) {
            // Add Marker Button
            Button {
                addMarkerAtCenter()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                    Text("Add Marker")
                        .font(.caption)
                }
            }
            .foregroundColor(.blue)
            
            Spacer()
            
            // Lock Status
            if lockService.holdsLock(sessionId: session.id) {
                VStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.title)
                        .foregroundColor(.green)
                    Text("Locked")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } else {
                Button {
                    Task {
                        await acquireLock()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "lock.open")
                            .font(.title)
                        Text("Lock")
                            .font(.caption)
                    }
                }
                .foregroundColor(.orange)
            }
            
            Spacer()
            
            // Clear Markers Button
            Button {
                clearAllMarkers()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash.circle.fill")
                        .font(.title)
                    Text("Clear")
                        .font(.caption)
                }
            }
            .foregroundColor(.red)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Actions
    
    private func startARSession() {
        // Start AR capture
        captureSession.start()
        
        // Join presence session
        Task {
            do {
                try await presenceService.joinSession(session.id)
                
                // Try to acquire lock for collaborative editing
                await acquireLock()
                
                isSessionActive = true
            } catch {
                errorMessage = "Failed to join session: \(error.localizedDescription)"
            }
        }
    }
    
    private func endARSession() {
        // Leave presence session
        presenceService.leaveCurrentSession()
        
        // Release lock if we have it
        if lockService.holdsLock(sessionId: session.id) {
            Task {
                try? await lockService.releaseLock(sessionId: session.id)
            }
        }
        
        isSessionActive = false
    }
    
    private func acquireLock() async {
        do {
            let acquired = try await lockService.acquireLock(sessionId: session.id)
            if !acquired {
                errorMessage = "Another user is currently editing this session"
            }
        } catch {
            errorMessage = "Failed to acquire lock: \(error.localizedDescription)"
        }
    }
    
    private func addMarkerAtCenter() {
        guard let arView = arView else { return }
        
        // Get screen center
        let screenCenter = CGPoint(
            x: arView.bounds.midX,
            y: arView.bounds.midY
        )
        
        // Raycast from center
        let results = arView.raycast(
            from: screenCenter,
            allowing: .estimatedPlane,
            alignment: .any
        )
        
        guard let result = results.first else {
            errorMessage = "No surface detected. Point at a surface and try again."
            return
        }
        
        // Create marker at the hit position
        let position = SIMD3<Float>(
            result.worldTransform.columns.3.x,
            result.worldTransform.columns.3.y,
            result.worldTransform.columns.3.z
        )
        
        // Create a simple square marker
        let size: Float = 0.1
        let points = [
            SIMD3<Float>(position.x - size/2, position.y, position.z - size/2),
            SIMD3<Float>(position.x + size/2, position.y, position.z - size/2),
            SIMD3<Float>(position.x + size/2, position.y, position.z + size/2),
            SIMD3<Float>(position.x - size/2, position.y, position.z + size/2)
        ]
        
        markerService.placeMarker(targetCorners: [screenCenter, screenCenter, screenCenter, screenCenter])
        
        // TODO: Sync marker to server
        Task {
            // This would create the marker on the server
            // let marker = try await MarkerService.shared.createMarkerFromARPoints(
            //     workSessionId: session.id,
            //     points: points,
            //     label: "Marker \(markerService.markers.count + 1)",
            //     color: "#FF0000"
            // )
        }
    }
    
    private func clearAllMarkers() {
        markerService.markers.removeAll()
        
        // TODO: Clear markers from server
        Task {
            // This would delete all markers for the session
            // try await MarkerService.shared.deleteAllMarkersForSession(session.id)
        }
    }
    
    private func completeSession() async {
        do {
            _ = try await workSessionService.completeSession(
                id: session.id,
                version: session.version
            )
            
            endARSession()
            dismiss()
        } catch {
            errorMessage = "Failed to complete session: \(error.localizedDescription)"
        }
    }
}



// MARK: - Preview

#Preview {
    ARSessionView(
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
        )
    )
}