//
//  ARSessionView.swift
//  roboscope2
//
//  AR view for a specific work session
//

import SwiftUI
import RealityKit
import ARKit
import UIKit

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
    // one-finger edge move is now handled by the overlay's one-finger pan

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
            // SwiftUI DragGesture removed; we now drive one-finger via the overlay to avoid conflicts
            // Removed LongPressGesture: selection is automatic; long-press was cancelling active movement

            // Invisible two-finger overlay to detect two-finger contact immediately
            TwoFingerTouchOverlay(
                onStart: {
                    // Two-finger whole-marker move
                    guard !isTwoFingers else { return }
                    isTwoFingers = true
                    isHoldingScreen = true
                    // Cancel any active one-finger edge move
                    if moveUpdateTimer != nil {
                        markerService.endMoveSelectedEdge()
                        moveUpdateTimer?.invalidate()
                        moveUpdateTimer = nil
                    }
                    // Start whole-marker movement if a marker is selected
                    if markerService.selectedMarkerID != nil {
                        let rect = getTargetRect()
                        let center = CGPoint(x: rect.midX, y: rect.midY)
                        if markerService.startTransformSelectedMarker(referenceCenter: center) {
                            let timer = Timer(timeInterval: 0.033, repeats: true) { _ in
                                markerService.updateTransform(dragTranslation: currentDrag, pinchScale: currentScale)
                            }
                            RunLoop.main.add(timer, forMode: .common)
                            moveUpdateTimer = timer
                        }
                    }
                },
                onOneFingerStart: {
                    // Start one-finger edge movement with grace already applied inside overlay
                    if !isTwoFingers && moveUpdateTimer == nil {
                        isHoldingScreen = true
                        if markerService.startMoveSelectedEdge() {
                            let timer = Timer(timeInterval: 0.033, repeats: true) { _ in
                                markerService.updateMoveSelectedEdge(withDrag: currentDrag)
                            }
                            RunLoop.main.add(timer, forMode: .common)
                            moveUpdateTimer = timer
                        }
                    }
                },
                onOneFingerEnd: {
                    // End one-finger edge move if not in two-finger mode
                    if !isTwoFingers {
                        isHoldingScreen = false
                        if let (backendId, version, updatedNodes) = markerService.endMoveSelectedEdge() {
                            // Persist updated marker to backend
                            Task {
                                do {
                                    _ = try await markerApi.updateMarkerPosition(
                                        id: backendId,
                                        workSessionId: session.id,
                                        points: updatedNodes,
                                        version: version
                                    )
                                } catch {
                                    // Silently handle error
                                }
                            }
                        }
                        moveUpdateTimer?.invalidate()
                        moveUpdateTimer = nil
                        currentDrag = .zero
                        currentScale = 1.0
                    }
                },
                onChange: { translation, scale in
                    // Stream pan/pinch changes
                    currentDrag = translation
                    currentScale = scale
                },
                onEnd: {
                    // Two-finger ended: stop whole-marker movement
                    if isTwoFingers {
                        isTwoFingers = false
                        isHoldingScreen = false
                        if let (backendId, version, updatedNodes) = markerService.endTransform() {
                            // Persist updated marker to backend
                            Task {
                                do {
                                    _ = try await markerApi.updateMarkerPosition(
                                        id: backendId,
                                        workSessionId: session.id,
                                        points: updatedNodes,
                                        version: version
                                    )
                                } catch {
                                    // Silently handle error
                                }
                            }
                        }
                        moveUpdateTimer?.invalidate()
                        moveUpdateTimer = nil
                        currentScale = 1.0
                        currentDrag = .zero
                    }
                }
            )
            .allowsHitTesting(true)
            .edgesIgnoringSafeArea(.all)

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

// Private overlay to detect two-finger contacts immediately and forward begin/end.
private struct TwoFingerTouchOverlay: UIViewRepresentable {
    let onStart: () -> Void
    let onOneFingerStart: () -> Void
    let onOneFingerEnd: () -> Void
    let onChange: (CGSize, CGFloat) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onStart: onStart, onOneFingerStart: onOneFingerStart, onOneFingerEnd: onOneFingerEnd, onChange: onChange, onEnd: onEnd) }

    func makeUIView(context: Context) -> UIView {
        let touchView = TouchPassthroughView()
        touchView.backgroundColor = .clear
        touchView.isUserInteractionEnabled = true
        touchView.coordinator = context.coordinator
        // Pinch for scale (still useful for two-finger)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        touchView.addGestureRecognizer(pinch)
        return touchView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let touchView = uiView as? TouchPassthroughView {
            touchView.coordinator = context.coordinator
        }
    }

    // Custom UIView that directly handles touches and forwards to coordinator
    class TouchPassthroughView: UIView {
        weak var coordinator: Coordinator?
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            coordinator?.handleTouchesBegan(touches, event: event, in: self)
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            coordinator?.handleTouchesMoved(touches, event: event, in: self)
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            coordinator?.handleTouchesEnded(touches, event: event, in: self)
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            coordinator?.handleTouchesCancelled(touches, event: event, in: self)
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onStart: () -> Void
        let onOneFingerStart: () -> Void
        let onOneFingerEnd: () -> Void
        let onChange: (CGSize, CGFloat) -> Void
        let onEnd: () -> Void
        private var twoFingerActive = false
        private var oneFingerActive = false
        private var oneFingerPending: Timer?
        private var currentScale: CGFloat = 1.0
        private var currentTranslation: CGSize = .zero
        private var trackingTouches: Set<UITouch> = []
        private var touchStartLocation: CGPoint = .zero

        init(onStart: @escaping () -> Void, onOneFingerStart: @escaping () -> Void, onOneFingerEnd: @escaping () -> Void, onChange: @escaping (CGSize, CGFloat) -> Void, onEnd: @escaping () -> Void) {
            self.onStart = onStart
            self.onOneFingerStart = onOneFingerStart
            self.onOneFingerEnd = onOneFingerEnd
            self.onChange = onChange
            self.onEnd = onEnd
        }
        
        // Direct touch handling (bypasses gesture recognizers which ARView was blocking)
        func handleTouchesBegan(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            trackingTouches.formUnion(touches)
            let touchCount = trackingTouches.count
            
            if touchCount == 1, let touch = trackingTouches.first {
                touchStartLocation = touch.location(in: view)
                currentTranslation = .zero
                if !twoFingerActive && !oneFingerActive && oneFingerPending == nil {
                    oneFingerPending = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        if !self.twoFingerActive && !self.oneFingerActive && self.trackingTouches.count == 1 {
                            self.oneFingerActive = true
                            self.onOneFingerStart()
                        }
                    }
                }
            } else if touchCount >= 2 {
                // Cancel one-finger and start two-finger immediately
                oneFingerPending?.invalidate(); oneFingerPending = nil
                if oneFingerActive {
                    oneFingerActive = false
                    onOneFingerEnd()
                }
                if !twoFingerActive {
                    // Compute initial centroid for two-finger tracking
                    if let first = trackingTouches.first, let second = trackingTouches.dropFirst().first {
                        let loc1 = first.location(in: view)
                        let loc2 = second.location(in: view)
                        touchStartLocation = CGPoint(x: (loc1.x + loc2.x)/2, y: (loc1.y + loc2.y)/2)
                    }
                    twoFingerActive = true
                    currentScale = 1.0
                    currentTranslation = .zero
                    onStart()
                    onChange(currentTranslation, currentScale)
                }
            }
        }
        
        func handleTouchesMoved(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            let touchCount = trackingTouches.count
            if touchCount == 1, let touch = trackingTouches.first, oneFingerActive && !twoFingerActive {
                let currentLoc = touch.location(in: view)
                currentTranslation = CGSize(width: currentLoc.x - touchStartLocation.x, height: currentLoc.y - touchStartLocation.y)
                onChange(currentTranslation, currentScale)
            } else if touchCount >= 2 && twoFingerActive {
                // Two-finger pan: compute centroid delta
                if let first = trackingTouches.first, let second = trackingTouches.dropFirst().first {
                    let loc1 = first.location(in: view)
                    let loc2 = second.location(in: view)
                    let centroid = CGPoint(x: (loc1.x + loc2.x)/2, y: (loc1.y + loc2.y)/2)
                    currentTranslation = CGSize(width: centroid.x - touchStartLocation.x, height: centroid.y - touchStartLocation.y)
                    onChange(currentTranslation, currentScale)
                }
            }
        }
        
        func handleTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            trackingTouches.subtract(touches)
            let remaining = trackingTouches.count
            
            if remaining == 0 {
                oneFingerPending?.invalidate(); oneFingerPending = nil
                if oneFingerActive {
                    oneFingerActive = false
                    onOneFingerEnd()
                }
                if twoFingerActive {
                    twoFingerActive = false
                    onEnd()
                }
                currentTranslation = .zero
                currentScale = 1.0
            } else if remaining == 1 && twoFingerActive {
                // Went from two to one: end two-finger
                twoFingerActive = false
                onEnd()
            }
        }
        
        func handleTouchesCancelled(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
            handleTouchesEnded(touches, event: event, in: view)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            currentScale = recognizer.scale
            if !twoFingerActive && recognizer.state == .began {
                twoFingerActive = true
                currentTranslation = .zero
                onStart()
            }
            if twoFingerActive {
                onChange(currentTranslation, currentScale)
            }
            // End handled by long press recognizer
        }
        // Allow pinch, pan, and long-press to recognize together without blocking ARView
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}

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