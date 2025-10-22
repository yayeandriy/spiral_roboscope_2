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
    @State private var showScanView = false
    @State private var frameOriginTransform: simd_float4x4 = matrix_identity_float4x4  // Default to AR origin
    @State private var frameOriginAnchor: AnchorEntity?

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
                // Place initial frame origin at AR session origin
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    placeFrameOriginGizmo(at: frameOriginTransform)
                }
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
                        // Transform markers from FrameOrigin coordinates to AR world coordinates
                        let transformedMarkers = persisted.map { marker -> Marker in
                            // Create new marker with transformed points
                            let worldPoints = transformPointsFromFrameOrigin(marker.points)
                            return Marker(
                                id: marker.id,
                                workSessionId: marker.workSessionId,
                                label: marker.label,
                                p1: [Double(worldPoints[0].x), Double(worldPoints[0].y), Double(worldPoints[0].z)],
                                p2: [Double(worldPoints[1].x), Double(worldPoints[1].y), Double(worldPoints[1].z)],
                                p3: [Double(worldPoints[2].x), Double(worldPoints[2].y), Double(worldPoints[2].z)],
                                p4: [Double(worldPoints[3].x), Double(worldPoints[3].y), Double(worldPoints[3].z)],
                                color: marker.color,
                                version: marker.version,
                                meta: marker.meta,
                                createdAt: marker.createdAt,
                                updatedAt: marker.updatedAt
                            )
                        }
                        markerService.loadPersistedMarkers(transformedMarkers)
                        print("[ARSession] Loaded \(persisted.count) markers and transformed to world coordinates")
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
                            // Transform to FrameOrigin coordinates before persisting
                            let frameOriginPoints = transformPointsToFrameOrigin(updatedNodes)
                            
                            // Persist updated marker to backend
                            Task {
                                do {
                                    _ = try await markerApi.updateMarkerPosition(
                                        id: backendId,
                                        workSessionId: session.id,
                                        points: frameOriginPoints,
                                        version: version
                                    )
                                    print("[ARSession] Updated marker position in FrameOrigin coordinates")
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
                            // Transform to FrameOrigin coordinates before persisting
                            let frameOriginPoints = transformPointsToFrameOrigin(updatedNodes)
                            
                            // Persist updated marker to backend
                            Task {
                                do {
                                    _ = try await markerApi.updateMarkerPosition(
                                        id: backendId,
                                        workSessionId: session.id,
                                        points: frameOriginPoints,
                                        version: version
                                    )
                                    print("[ARSession] Updated marker transform in FrameOrigin coordinates")
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
                HStack(spacing: 12) {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .lgCapsule(tint: .white)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                Spacer()
            }
            .zIndex(2)

            // Bottom control: center plus button
            VStack {
                Spacer()
                
                // Marker info badge (shown when a marker is selected)
                if let info = markerService.selectedMarkerInfo {
                    MarkerBadgeView(
                        info: info,
                        onDelete: {
                            if let backendId = markerService.selectedBackendId {
                                Task {
                                    do {
                                        try await markerApi.deleteMarker(id: backendId)
                                        markerService.removeMarkerByBackendId(backendId)
                                    } catch {
                                        errorMessage = "Failed to delete marker: \(error.localizedDescription)"
                                    }
                                }
                            } else {
                                markerService.removeSelectedMarkerLocal()
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                    .transition(.opacity.combined(with: .scale))
                }
                
                HStack(spacing: 20) {
                    // Scan button (left)
                    Button {
                        showScanView = true
                    } label: {
                        Image(systemName: "scanner")
                            .font(.system(size: 24))
                            .frame(width: 60, height: 60)
                    }
                    .buttonStyle(.plain)
                    .lgCircle(tint: .blue)
                    
                    Spacer()
                    
                    // Plus button (center)
                    Button { createAndPersistMarker() } label: {
                        Image(systemName: isTwoFingers ? "hand.tap.fill" : (isHoldingScreen ? "hand.point.up.fill" : "plus"))
                            .font(.system(size: 36))
                            .frame(width: 80, height: 80)
                    }
                    .buttonStyle(.plain)
                    .lgCircle(tint: .white)
                    
                    Spacer()
                    
                    // Placeholder for symmetry (right)
                    Color.clear
                        .frame(width: 60, height: 60)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 50)
            }
            .animation(.easeInOut(duration: 0.2), value: markerService.selectedMarkerID)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage = errorMessage { Text(errorMessage) }
        }
        .sheet(isPresented: $showScanView) {
            SessionScanView(
                session: session,
                captureSession: captureSession,
                onRegistrationComplete: { transform in
                    frameOriginTransform = transform
                    placeFrameOriginGizmo(at: transform)
                    // Update all existing markers to new coordinate system
                    updateMarkersForNewFrameOrigin()
                }
            )
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
            // Transform marker points to FrameOrigin coordinate system
            let frameOriginPoints = transformPointsToFrameOrigin(spatial.nodes)
            
            // Save to backend with FrameOrigin coordinates
            Task {
                do {
                    let created = try await markerApi.createMarker(
                        CreateMarker(workSessionId: session.id, points: frameOriginPoints)
                    )
                    markerService.linkSpatialMarker(localId: spatial.id, backendId: created.id)
                    print("[ARSession] Created marker in FrameOrigin coordinates")
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
    
    // MARK: - Frame Origin Gizmo
    
    private func placeFrameOriginGizmo(at transform: simd_float4x4) {
        guard let arView = arView else { return }
        
        // Remove existing frame origin if any
        if let existingAnchor = frameOriginAnchor {
            arView.scene.removeAnchor(existingAnchor)
        }
        
        // Create anchor at the transformed origin
        let anchor = AnchorEntity(world: transform)
        
        // Create coordinate axes (RealityKit version)
        let axisLength: Float = 0.5  // 50cm axes
        let axisRadius: Float = 0.01  // 1cm thick
        
        // X-axis (Red)
        let xAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        xAxis.position = SIMD3<Float>(axisLength/2, 0, 0)
        xAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(0, 0, 1))
        
        // Y-axis (Green)
        let yAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        yAxis.position = SIMD3<Float>(0, axisLength/2, 0)
        
        // Z-axis (Blue)
        let zAxis = ModelEntity(
            mesh: .generateCylinder(height: axisLength, radius: axisRadius),
            materials: [SimpleMaterial(color: .blue, isMetallic: false)]
        )
        zAxis.position = SIMD3<Float>(0, 0, axisLength/2)
        zAxis.orientation = simd_quatf(angle: .pi/2, axis: SIMD3<Float>(1, 0, 0))
        
        // Add axis labels with spheres at the tips
        let sphereRadius: Float = 0.03
        
        let xTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .red, isMetallic: false)]
        )
        xTip.position = SIMD3<Float>(axisLength, 0, 0)
        
        let yTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .green, isMetallic: false)]
        )
        yTip.position = SIMD3<Float>(0, axisLength, 0)
        
        let zTip = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius),
            materials: [SimpleMaterial(color: .blue, isMetallic: false)]
        )
        zTip.position = SIMD3<Float>(0, 0, axisLength)
        
        // Center sphere (white/yellow to mark origin)
        let centerSphere = ModelEntity(
            mesh: .generateSphere(radius: sphereRadius * 1.5),
            materials: [SimpleMaterial(color: .yellow, isMetallic: false)]
        )
        
        // Add all components to anchor
        anchor.addChild(xAxis)
        anchor.addChild(yAxis)
        anchor.addChild(zAxis)
        anchor.addChild(xTip)
        anchor.addChild(yTip)
        anchor.addChild(zTip)
        anchor.addChild(centerSphere)
        
        // Add to scene
        arView.scene.addAnchor(anchor)
        frameOriginAnchor = anchor
        
        print("[ARSession] Placed frame origin gizmo at transform: \(transform)")
        print("[ARSession] Gizmo position in world: \(anchor.position(relativeTo: nil))")
    }
    
    // MARK: - Coordinate System Transformation
    
    /// Transform points from AR world coordinates to FrameOrigin coordinates
    private func transformPointsToFrameOrigin(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        // Get inverse of frame origin transform to convert world coords to frame coords
        let inverseTransform = frameOriginTransform.inverse
        
        return points.map { point in
            // Convert point to SIMD4
            let worldPoint = SIMD4<Float>(point.x, point.y, point.z, 1.0)
            
            // Transform to FrameOrigin space
            let framePoint = inverseTransform * worldPoint
            
            return SIMD3<Float>(framePoint.x, framePoint.y, framePoint.z)
        }
    }
    
    /// Transform points from FrameOrigin coordinates to AR world coordinates
    private func transformPointsFromFrameOrigin(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        return points.map { point in
            // Convert point to SIMD4
            let framePoint = SIMD4<Float>(point.x, point.y, point.z, 1.0)
            
            // Transform to world space
            let worldPoint = frameOriginTransform * framePoint
            
            return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
        }
    }
    
    /// Update all markers' visual positions when FrameOrigin changes
    private func updateMarkersForNewFrameOrigin() {
        // Reload markers from backend and transform them to the new world coordinates
        Task {
            do {
                let persisted = try await markerApi.getMarkersForSession(session.id)
                
                // Transform markers from FrameOrigin coordinates to new AR world coordinates
                let transformedMarkers = persisted.map { marker -> Marker in
                    let worldPoints = transformPointsFromFrameOrigin(marker.points)
                    return Marker(
                        id: marker.id,
                        workSessionId: marker.workSessionId,
                        label: marker.label,
                        p1: [Double(worldPoints[0].x), Double(worldPoints[0].y), Double(worldPoints[0].z)],
                        p2: [Double(worldPoints[1].x), Double(worldPoints[1].y), Double(worldPoints[1].z)],
                        p3: [Double(worldPoints[2].x), Double(worldPoints[2].y), Double(worldPoints[2].z)],
                        p4: [Double(worldPoints[3].x), Double(worldPoints[3].y), Double(worldPoints[3].z)],
                        color: marker.color,
                        version: marker.version,
                        meta: marker.meta,
                        createdAt: marker.createdAt,
                        updatedAt: marker.updatedAt
                    )
                }
                
                // Reload markers with new positions
                await MainActor.run {
                    markerService.loadPersistedMarkers(transformedMarkers)
                    print("[ARSession] Updated \(persisted.count) markers for new FrameOrigin")
                }
            } catch {
                print("Failed to update markers: \(error)")
            }
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

// MARK: - Marker Badge View

struct MarkerBadgeView: View {
    let info: SpatialMarkerService.MarkerInfo
    var onDelete: (() -> Void)? = nil
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
            // Dimensions row
            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("Width")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Text(String(format: "%.2f m", info.width))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: 30)
                
                VStack(spacing: 4) {
                    Text("Length")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Text(String(format: "%.2f m", info.length))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            
                Divider()
                    .background(Color.white.opacity(0.3))
            
            // Center coordinates row
            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text("X")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Text(String(format: "%.2f", info.centerX))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
                
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: 30)
                
                VStack(spacing: 4) {
                    Text("Z")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Text(String(format: "%.2f", info.centerZ))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.3), .white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 12, weight: .bold))
                        .padding(8)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.7), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                }
                .offset(x: 8, y: -8)
            }
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