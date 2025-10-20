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

    @State private var arView: ARView?
    @State private var isSessionActive = false
    @State private var showingEndSessionAlert = false
    @State private var errorMessage: String?

    // Match scanning interactions
    @State private var isHoldingScreen = false
    @State private var isTwoFingers = false
    @State private var moveUpdateTimer: Timer?
    @State private var markerTrackingTimer: Timer?

    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(
                session: captureSession.session,
                arView: $arView
            )
            .edgesIgnoringSafeArea(.all)
            .onAppear {
                startARSession()
                // Start tracking markers continuously
                markerTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    checkMarkersInTarget()
                }
            }
            .onDisappear {
                markerTrackingTimer?.invalidate()
                markerTrackingTimer = nil
                stopMovingMarker()
                endARSession()
            }
            .onChange(of: arView) { newValue in
                markerService.arView = newValue
            }
            // Gestures similar to Scan screen
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHoldingScreen { isHoldingScreen = true }
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
                        if !isTwoFingers {
                            isTwoFingers = true
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

            // Target overlay (same as Scan)
            TargetOverlayView()
                .allowsHitTesting(false)

            // Top controls styled like Scan
            VStack {
                HStack(spacing: 20) {
                    Button("End Session") { showingEndSessionAlert = true }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .lgCapsule(tint: .red)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .lgCapsule(tint: .white)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                Spacer()
            }

            // Bottom controls styled like Scan
            VStack {
                Spacer()
                HStack(spacing: 20) {
                    Button { placeMarker() } label: {
                        Image(systemName: isTwoFingers ? "hand.tap.fill" : (isHoldingScreen ? "hand.point.up.fill" : "plus"))
                            .font(.system(size: 36))
                            .frame(width: 80, height: 80)
                    }
                    .buttonStyle(.plain)
                    .lgCircle(tint: .white)

                    Spacer()

                    Button { clearAllMarkers() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 24))
                            .frame(width: 70, height: 70)
                    }
                    .buttonStyle(.plain)
                    .lgCircle(tint: .red)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 50)
            }
        }
        .alert("End Session", isPresented: $showingEndSessionAlert) {
            Button("End Session", role: .destructive) {
                Task { await completeSession() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to end this session? This will mark it as completed.")
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage = errorMessage { Text(errorMessage) }
        }
        .navigationBarBackButtonHidden()
    }
    
    // MARK: - Actions
    
    private func startARSession() {
        captureSession.start()
        isSessionActive = true
    }
    
    private func endARSession() {
        // Realtime features disabled: no presence leave / lock release
        isSessionActive = false
    }
    
    // MARK: - Marker helpers (aligned with Scan view)
    private func placeMarker() {
        guard let arView = arView else { return }
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200
        let half = targetSize / 2
        let corners = [
            CGPoint(x: centerX - half, y: targetY - half),
            CGPoint(x: centerX + half, y: targetY - half),
            CGPoint(x: centerX + half, y: targetY + half),
            CGPoint(x: centerX - half, y: targetY + half)
        ]
        markerService.placeMarker(targetCorners: corners)
    }
    
    private func getTargetRect() -> CGRect {
        guard let arView = arView else { return .zero }
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200
        let expanded = targetSize * 1.1
        return CGRect(x: centerX - expanded/2, y: targetY - expanded/2, width: expanded, height: expanded)
    }
    
    private func checkMarkersInTarget() {
        let rect = getTargetRect()
        markerService.updateMarkersInTarget(targetRect: rect)
    }
    
    private func selectMarkerInTarget() {
        let rect = getTargetRect()
        markerService.selectMarkerInTarget(targetRect: rect)
    }
    
    private func startMovingMarker() {
        if markerService.startMovingSelectedMarker() {
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