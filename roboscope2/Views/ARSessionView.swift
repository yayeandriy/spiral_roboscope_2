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
    @StateObject private var markerApi = MarkerService.shared

    @State private var arView: ARView?
    @State private var isSessionActive = false
    @State private var errorMessage: String?

    // Match scanning interactions
    @State private var isHoldingScreen = false
    @State private var isTwoFingers = false
    @State private var moveUpdateTimer: Timer?
    @State private var markerTrackingTimer: Timer?
    // Transform state (for finger-driven move/resize)
    @State private var currentDrag: CGSize = .zero
    @State private var currentScale: CGFloat = 1.0

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
                let tracking = Timer(timeInterval: 0.1, repeats: true) { _ in
                    // print("[Timer] Marker tracking tick")
                    checkMarkersInTarget()
                }
                RunLoop.main.add(tracking, forMode: .common)
                markerTrackingTimer = tracking
                // Load persisted markers for this session
                Task {
                    do {
                        let persisted = try await markerApi.getMarkersForSession(session.id)
                        markerService.loadPersistedMarkers(persisted)
                    } catch {
                        print("Failed to load markers: \(error)")
                    }
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
                    .onChanged { value in
                        if !isHoldingScreen { isHoldingScreen = true }
                        currentDrag = value.translation
                        if !isTwoFingers {
                            // One finger path: start edge move once and keep timer running while finger holds
                            if moveUpdateTimer == nil {
                                if markerService.startMoveSelectedEdge() {
                                    print("[Gesture] Start one-finger move timer (common runloop)")
                                    let timer = Timer(timeInterval: 0.033, repeats: true) { _ in
                                        markerService.updateMoveSelectedEdge()
                                    }
                                    RunLoop.main.add(timer, forMode: .common)
                                    moveUpdateTimer = timer
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        isHoldingScreen = false
                        if !isTwoFingers {
                            markerService.endMoveSelectedEdge()
                            print("[Gesture] End one-finger move timer")
                            moveUpdateTimer?.invalidate()
                            moveUpdateTimer = nil
                        }
                        currentDrag = .zero
                        currentScale = 1.0
                    }
            )
            .simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0)
                    .onChanged { scale in
                        if !isTwoFingers {
                            isTwoFingers = true
                            // Begin transform around target center if a marker is selected
                            if markerService.selectedMarkerID != nil {
                                let rect = getTargetRect()
                                let center = CGPoint(x: rect.midX, y: rect.midY)
                                if moveUpdateTimer == nil {
                                    if markerService.startTransformSelectedMarker(referenceCenter: center) {
                                        print("[Gesture] Start two-finger move timer (common runloop)")
                                        let timer = Timer(timeInterval: 0.033, repeats: true) { _ in
                                            markerService.updateMovingMarker()
                                        }
                                        RunLoop.main.add(timer, forMode: .common)
                                        moveUpdateTimer = timer
                                    }
                                }
                            }
                        }
                        currentScale = scale
                    }
                    .onEnded { _ in
                        isTwoFingers = false
                        // Finish transform
                        markerService.endTransform()
                        print("[Gesture] End two-finger move timer")
                        moveUpdateTimer?.invalidate()
                        moveUpdateTimer = nil
                        currentScale = 1.0
                        currentDrag = .zero
                    }
            )
            // Removed LongPressGesture: selection is automatic; long-press was cancelling active movement

            // Target overlay (same as Scan)
            TargetOverlayView()
                .allowsHitTesting(false)
                .zIndex(1)

            // Top controls styled like Scan
            VStack {
                HStack(spacing: 20) {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .lgCapsule(tint: .white)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Spacer()
            }
            .zIndex(2)

            // Bottom control: center plus button
            VStack {
                Spacer()
                HStack(spacing: 0) {
                    Spacer()
                    Button { createAndPersistMarker() } label: {
                        Image(systemName: isTwoFingers ? "hand.tap.fill" : (isHoldingScreen ? "hand.point.up.fill" : "plus"))
                            .font(.system(size: 36))
                            .frame(width: 80, height: 80)
                    }
                    .buttonStyle(.plain)
                    .lgCircle(tint: .white)
                    Spacer()
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 50)
            }
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
    
    // Persisted create: place marker in AR and save to backend
    private func createAndPersistMarker() {
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
        if let spatial = markerService.placeMarkerReturningSpatial(targetCorners: corners) {
            // Save to backend
            Task {
                do {
                    let created = try await markerApi.createMarker(
                        CreateMarker(workSessionId: session.id, points: spatial.nodes)
                    )
                    markerService.linkSpatialMarker(localId: spatial.id, backendId: created.id)
                } catch {
                    print("Failed to persist marker: \(error)")
                }
            }
        }
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
    
    private func clearAllMarkersPersisted() {
        // Remove visually
        markerService.clearMarkers()
        // Remove persisted markers for this session
        Task {
            do {
                try await markerApi.deleteAllMarkersForSession(session.id)
            } catch {
                print("Failed to delete markers: \(error)")
            }
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