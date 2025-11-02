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
import SceneKit

struct ARSessionView: View {
    let session: WorkSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var captureSession: CaptureSession
    @StateObject private var markerService: SpatialMarkerService
    @StateObject private var workSessionService: WorkSessionService
    @StateObject private var markerApi: MarkerService
    @StateObject private var spaceService: SpaceService
    @StateObject private var settings: AppSettings
    @StateObject private var viewModel: ARSessionViewModel

    init(session: WorkSession) {
        self.session = session
        let capture = CaptureSession()
        let markerService = SpatialMarkerService()
        let workService = WorkSessionService.shared
        let markerApi = MarkerService.shared
        let spaceService = SpaceService.shared
        let settings = AppSettings.shared
        _captureSession = StateObject(wrappedValue: capture)
        _markerService = StateObject(wrappedValue: markerService)
        _workSessionService = StateObject(wrappedValue: workService)
        _markerApi = StateObject(wrappedValue: markerApi)
        _spaceService = StateObject(wrappedValue: spaceService)
        _settings = StateObject(wrappedValue: settings)
        _viewModel = StateObject(wrappedValue: ARSessionViewModel(sessionId: session.id, markerService: markerService, markerApi: markerApi))
    }

    @State private var arView: ARView?
    @State private var isSessionActive = false
    @State private var errorMessage: String?
    @State private var showScanView = false
    @State private var isRegistering = false
    @State private var registrationProgress: String = ""
    @State private var showActionsDialog: Bool = false
    @State private var frameOriginTransform: simd_float4x4 = matrix_identity_float4x4 {
        didSet {
            // Automatically update all entities when FrameOrigin changes
            // FrameOrigin represents the reference model's coordinate system origin
            updateFrameOriginGizmoPosition()
            updateReferenceModelPosition()
            updateScanModelPosition()
        }
    }
    @State private var frameOriginAnchor: AnchorEntity?
    
    // Manual Two-Point Origin placement
    private enum ManualPlacementState { case inactive, placeFirst, placeSecond, readyToApply }
    @State private var manualPlacementState: ManualPlacementState = .inactive
    @State private var manualFirstPoint: SIMD3<Float>? = nil
    @State private var manualSecondPoint: SIMD3<Float>? = nil
    // Persisted two-point positions (last applied) to restore on next entry into Two Point mode
    @State private var preservedFirstPoint: SIMD3<Float>? = nil
    @State private var preservedSecondPoint: SIMD3<Float>? = nil
    @State private var manualFirstAnchor: AnchorEntity? = nil
    @State private var manualSecondAnchor: AnchorEntity? = nil
    @State private var manualFirstPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State private var manualSecondPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    // Persisted preferred alignments to restore editing behavior
    @State private var preservedFirstPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State private var preservedSecondPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State private var selectedManualPointIndex: Int? = nil // 1 or 2
    @State private var manualPointMoveTimer: Timer? = nil
    @State private var fixedManualMoveScreenPoint: CGPoint? = nil // Fixed screen point captured at movement start
    
    // Reference model state
    @State private var showReferenceModel = false
    @State private var referenceModelAnchor: AnchorEntity?
    @State private var isLoadingModel = false
    @State private var referenceModelEntity: ModelEntity?  // For RealityKit raycasting
    
    // Scan model state
    @State private var showScanModel = false
    @State private var scanModelAnchor: AnchorEntity?
    @State private var isLoadingScan = false

    // Match scanning interactions
    @State private var autoDropTimer: Timer?
    @State private var autoDropAttempts: Int = 0
    // one-finger edge move is now handled by the overlay's one-finger pan
    
    // MARK: - Computed Properties
    
    private var associatedSpaceName: String? {
        guard let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) else {
            return "Space: \(session.spaceId.uuidString.prefix(8))..."
        }
        return space.name
    }
    
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
                    // Start auto-drop with retries so it lands as soon as a plane is available
                    startAutoDropFrameOrigin()
                }
                // Start tracking markers continuously via ViewModel
                viewModel.startTracking(getTargetRect: { getTargetRect() }, onManualSelectionUpdate: {
                    // While holding to move a manual point, freeze selection to avoid drops
                    if !(viewModel.isHoldingScreen && manualPlacementState != .inactive) {
                        updateManualPointSelection()
                    }
                })
                
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
                                customProps: marker.customProps,
                                createdAt: marker.createdAt,
                                updatedAt: marker.updatedAt,
                                details: marker.details
                            )
                        }
                        markerService.loadPersistedMarkers(transformedMarkers)
                        print("[ARSession] Loaded \(persisted.count) markers and transformed to world coordinates")
                        
                        // Calculate details for any markers that don't have them yet
                        for marker in transformedMarkers {
                            if marker.details == nil {
                                print("[ARSession] Calculating details for marker \(marker.id)")
                                Task {
                                    await markerService.refreshMarkerDetails(backendId: marker.id)
                                }
                            }
                        }
                    } catch {
                        print("Failed to load markers: \(error)")
                    }
                }
            }
            .onDisappear {
                viewModel.cancelAllTimers()
                autoDropTimer?.invalidate()
                autoDropTimer = nil
                autoDropAttempts = 0
                endManualPointMove()
                endARSession()
            }
            .onChange(of: arView) { newValue in
                markerService.arView = newValue
                viewModel.bindARView(newValue)
            }
            // SwiftUI DragGesture removed; we now drive one-finger via the overlay to avoid conflicts
            // Removed LongPressGesture: selection is automatic; long-press was cancelling active movement

            // Invisible two-finger overlay to detect two-finger contact immediately
            TwoFingerTouchOverlay(
                onStart: {
                    if manualPlacementState != .inactive {
                        // Ignore two-finger in manual mode for now
                        return
                    }
                    viewModel.twoFingerStart(getTargetRect: { getTargetRect() })
                },
                onOneFingerStart: {
                    if manualPlacementState != .inactive {
                        // Begin moving selected manual point (if any)
                        if selectedManualPointIndex != nil {
                            viewModel.isHoldingScreen = true
                            startManualPointMove()
                        }
                        return
                    }
                    viewModel.oneFingerStart()
                },
                onOneFingerEnd: {
                    if manualPlacementState != .inactive {
                        // End moving manual point
                        viewModel.isHoldingScreen = false
                        endManualPointMove()
                        return
                    }
                    viewModel.oneFingerEnd(transformToFrameOrigin: { pts in transformPointsToFrameOrigin(pts) })
                },
                onChange: { translation, scale in
                    if manualPlacementState != .inactive { return }
                    viewModel.gestureChanged(translation: translation, scale: scale)
                },
                onEnd: {
                    if manualPlacementState != .inactive {
                        // Ignore two-finger end in manual mode
                    } else {
                        viewModel.twoFingerEnd(transformToFrameOrigin: { pts in transformPointsToFrameOrigin(pts) })
                    }
                }
            )
            .allowsHitTesting(!showActionsDialog)
            .edgesIgnoringSafeArea(.all)

            // Target overlay (switch to crosshair in manual placement mode)
            TargetOverlayView(style: manualPlacementState == .inactive ? .brackets : .cross)
                .allowsHitTesting(false)
                .zIndex(1)

            // Top controls styled like Scan + left 'more' menu in liquid glass
            VStack {
                HStack(spacing: 12) {
                    // Top-left actions presented via confirmationDialog to avoid gesture interception
                    Button {
                        showActionsDialog = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(
                                                LinearGradient(
                                                    colors: [.white.opacity(0.35), .white.opacity(0.1)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                ),
                                                lineWidth: 1
                                            )
                                    )
                            )
                    }

                    Spacer(minLength: 8)
                    
                    // Marker count in center-left
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("\(markerService.markers.count)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [.white.opacity(0.35), .white.opacity(0.1)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                            lineWidth: 1
                                    )
                            )
                    )
                    
                    Spacer(minLength: 8)
                    
                    // Space name (smaller, center-right)
                    if let spaceName = associatedSpaceName {
                        Text(spaceName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer(minLength: 8)
                    
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
            
            // Registration progress overlay
            if isRegistering {
                registrationProgressOverlay
                    .zIndex(3)
            }
            
            // Model loading indicator
            if isLoadingModel {
                modelLoadingOverlay
                    .zIndex(3)
            }
            
            // Scan loading indicator
            if isLoadingScan {
                scanLoadingOverlay
                    .zIndex(3)
            }

            // Bottom controls: Center action row; optional Clear below Apply; no separate setup row
            VStack {
                Spacer()

                // Marker info badge (shown when a marker is selected)
                if let info = markerService.selectedMarkerInfo {
                    MarkerBadgeView(
                        info: info,
                        details: markerService.selectedMarkerDetails,
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

                // Bottom row: Centered main action (Plus or Apply)
                HStack {
                    Spacer()
                    if manualPlacementState == .inactive {
                        Button { createAndPersistMarker() } label: {
                            Image(systemName: viewModel.isTwoFingers ? "hand.tap.fill" : (viewModel.isHoldingScreen ? "hand.point.up.fill" : "plus"))
                                .font(.system(size: 36))
                                .frame(width: 80, height: 80)
                        }
                        .buttonStyle(.plain)
                        .lgCircle(tint: .white)
                    } else {
                        VStack(spacing: 10) {
                            Button {
                                manualPlacementPrimaryAction()
                            } label: {
                                Text(manualPlacementButtonTitle())
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(minWidth: 200, minHeight: 54)
                            }
                            .buttonStyle(.plain)
                            .lgCapsule(tint: .blue)

                            if manualFirstPoint != nil && manualSecondPoint != nil {
                                Button(role: .destructive) {
                                    clearTwoPointPlacement()
                                } label: {
                                    Text("Clear")
                                        .font(.system(size: 16, weight: .semibold))
                                        .frame(minWidth: 160, minHeight: 48)
                                }
                                .buttonStyle(.plain)
                                .lgCapsule(tint: .red)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16) // keep horizontal padding consistent
                .padding(.bottom, 50)
            }
            .animation(.easeInOut(duration: 0.2), value: markerService.selectedMarkerID)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage = errorMessage { Text(errorMessage) }
        }
        .confirmationDialog("Actions", isPresented: $showActionsDialog, titleVisibility: .visible) {
            // Show/Hide Reference Model
            Button(showReferenceModel ? "Hide Reference Model" : "Show Reference Model") {
                showReferenceModel.toggle()
                if showReferenceModel { placeModelAtFrameOrigin() } else { removeReferenceModel() }
            }

            // Show/Hide Scanned Model
            Button(showScanModel ? "Hide Scanned Model" : "Show Scanned Model") {
                showScanModel.toggle()
                if showScanModel { placeScanModelAtFrameOrigin() } else { removeScanModel() }
            }

            // Drop FrameOrigin on floor
            Button("Drop FrameOrigin", role: .none) {
                dropFrameOriginOnFloor()
            }

            // Use saved scan
            Button("Use saved scan", role: .none) {
                Task { await useSavedScan() }
            }

            // Two Point setup
            if manualPlacementState == .inactive {
                Button("Manual Two Points") { enterManualTwoPointsMode() }
            } else {
                Button("Cancel Manual Placement", role: .destructive) { cancelManualTwoPointsMode() }
            }

            // Delete all markers
            Button("Delete All Markers", role: .destructive) {
                clearAllMarkersPersisted()
            }
        }
        .sheet(isPresented: $showScanView) {
            SessionScanView(
                session: session,
                captureSession: captureSession,
                onRegistrationComplete: { transform in
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("[🔧 TRANSFORM][REGISTRATION] ✅ Registration Complete!")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("[🔧 TRANSFORM][REGISTRATION] Computed transform matrix:")
                    print("[🔧 TRANSFORM][REGISTRATION]   [\(transform.columns.0)]")
                    print("[🔧 TRANSFORM][REGISTRATION]   [\(transform.columns.1)]")
                    print("[🔧 TRANSFORM][REGISTRATION]   [\(transform.columns.2)]")
                    print("[🔧 TRANSFORM][REGISTRATION]   [\(transform.columns.3)]")
                    print("[🔧 TRANSFORM][REGISTRATION] Translation: (\(transform.columns.3.x), \(transform.columns.3.y), \(transform.columns.3.z))")
                    print("[🔧 TRANSFORM][REGISTRATION] Setting frameOriginTransform...")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    
                    frameOriginTransform = transform
                    // Gizmo is automatically updated via frameOriginTransform didSet observer
                    // Update all existing markers to new coordinate system
                    updateMarkersForNewFrameOrigin()
                    // NOTE: Reference model and scan model positions are automatically
                    // updated via frameOriginTransform didSet observer
                }
            )
        }
        .navigationBarBackButtonHidden()
    }

    // MARK: - Manual Two-Point Placement
    private func enterManualTwoPointsMode() {
        // Clean any existing helper anchors from prior runs
        removeManualAnchors()

        // If we have preserved points from an earlier two-point setup, restore them
        if let p1 = preservedFirstPoint, let p2 = preservedSecondPoint {
            // Restore positions into current editing state
            manualFirstPoint = p1
            manualSecondPoint = p2
            manualFirstPreferredAlignment = preservedFirstPreferredAlignment ?? .horizontal
            manualSecondPreferredAlignment = preservedSecondPreferredAlignment ?? .horizontal

            // Recreate spheres at preserved positions for editing
            placeManualPoint(p1, color: .red, isFirst: true)
            placeManualPoint(p2, color: .blue, isFirst: false)
            manualPlacementState = .readyToApply
            print(String(format: "[ManualOrigin][Restore] Restored two points: p1=(%.3f, %.3f, %.3f) p2=(%.3f, %.3f, %.3f)", p1.x, p1.y, p1.z, p2.x, p2.y, p2.z))
        } else {
            // No preserved points: start fresh placement flow
            manualFirstPoint = nil
            manualSecondPoint = nil
            manualFirstPreferredAlignment = nil
            manualSecondPreferredAlignment = nil
            manualPlacementState = .placeFirst
        }
        // Hide markers and gizmo
        markerService.setMarkersVisible(false)
        frameOriginAnchor?.isEnabled = false
        selectedManualPointIndex = nil
        print("[ManualOrigin][State] Enter manual mode")
    }

    private func cancelManualTwoPointsMode() {
        manualPlacementState = .inactive
        // Remove helper anchors
        removeManualAnchors()
        // Show markers and gizmo again
        markerService.setMarkersVisible(true)
        frameOriginAnchor?.isEnabled = true
        selectedManualPointIndex = nil
        endManualPointMove()
        print("[ManualOrigin][State] Cancel manual mode")
    }

    private func manualPlacementButtonTitle() -> String {
        switch manualPlacementState {
        case .placeFirst: return "Place First Point"
        case .placeSecond: return "Place Second Point"
        case .readyToApply: return "Apply"
        case .inactive: return ""
        }
    }

    private func manualPlacementPrimaryAction() {
        switch manualPlacementState {
        case .placeFirst:
            if let (p, align) = prioritizedRaycastFromCenter() {
                placeManualPoint(p, color: .red, isFirst: true)
                manualFirstPoint = p
                manualFirstPreferredAlignment = align
                manualPlacementState = .placeSecond
                print(String(format: "[ManualOrigin][Place] First point %@ at (%.3f, %.3f, %.3f)", String(describing: align), p.x, p.y, p.z))
            }
        case .placeSecond:
            if let (p, align) = prioritizedRaycastFromCenter() {
                placeManualPoint(p, color: .blue, isFirst: false)
                manualSecondPoint = p
                manualSecondPreferredAlignment = align
                manualPlacementState = .readyToApply
                print(String(format: "[ManualOrigin][Place] Second point %@ at (%.3f, %.3f, %.3f)", String(describing: align), p.x, p.y, p.z))
            }
        case .readyToApply:
            applyManualTwoPointOrigin()
        case .inactive:
            break
        }
    }

    private func raycastFromScreenCenter() -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Prefer existing planes; fall back to estimated
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast] existing any -> (%.3f, %.3f, %.3f)", t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast] estimated any -> (%.3f, %.3f, %.3f)", t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        print("[ManualOrigin][Raycast] No hit (any)")
        return nil
    }

    /// Raycast helper with explicit alignment preference. Used by placement and as a fallback.
    private func raycastFromScreenCenter(preferredAlignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // Prefer existing plane geometry for stability
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast] existing %@ -> (%.3f, %.3f, %.3f)", String(describing: preferredAlignment), t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Then fall back to estimated plane with the same alignment
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast] estimated %@ -> (%.3f, %.3f, %.3f)", String(describing: preferredAlignment), t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Last resort: existing any, then estimated any
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast] existing any (fallback) -> (%.3f, %.3f, %.3f)", t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast] estimated any (fallback) -> (%.3f, %.3f, %.3f)", t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        print(String(format: "[ManualOrigin][Raycast] No hit (preferred=%@)", String(describing: preferredAlignment)))
        return nil
    }

    /// Movement-focused raycast: prefer existing plane geometry only; skip if no stable surface under crosshair.
    private func raycastFromCenterForMove(preferredAlignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast][Move] existing %@ -> (%.3f, %.3f, %.3f)", String(describing: preferredAlignment), t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // Optional: if needed, allow any alignment on existing planes
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .existingPlaneGeometry, alignment: .any) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast][Move] existing any -> (%.3f, %.3f, %.3f)", t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        // As a fallback, allow estimated plane with preferred alignment (comment out if too jittery)
        if let query = arView.makeRaycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: preferredAlignment) {
            let results = arView.session.raycast(query)
            if let first = results.first {
                let t = first.worldTransform
                print(String(format: "[ManualOrigin][Raycast][Move] estimated %@ -> (%.3f, %.3f, %.3f)", String(describing: preferredAlignment), t.columns.3.x, t.columns.3.y, t.columns.3.z))
                return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            }
        }
        print(String(format: "[ManualOrigin][Raycast][Move] No hit (preferred=%@)", String(describing: preferredAlignment)))
        return nil
    }

    // Try horizontal first (floors/tables), then vertical (walls), then any. Returns position and chosen alignment.
    private func prioritizedRaycastFromCenter() -> (SIMD3<Float>, ARRaycastQuery.TargetAlignment)? {
        if let p = raycastFromScreenCenter(preferredAlignment: .horizontal) { return (p, .horizontal) }
        if let p = raycastFromScreenCenter(preferredAlignment: .vertical) { return (p, .vertical) }
        if let p = raycastFromScreenCenter() { return (p, .any) }
        return nil
    }

    private func placeManualPoint(_ position: SIMD3<Float>, color: UIColor, isFirst: Bool) {
        guard let arView = arView else { return }
    var t = matrix_identity_float4x4
    t.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
    let anchor = AnchorEntity(world: t)
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [SimpleMaterial(color: color, isMetallic: false)])
        sphere.name = isFirst ? "manual_point_1" : "manual_point_2"
        // Enable hit-testing against the sphere to improve selection robustness
        sphere.generateCollisionShapes(recursive: true)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        if isFirst { manualFirstAnchor = anchor } else { manualSecondAnchor = anchor }
    }

    private func removeManualAnchors() {
        if let a = manualFirstAnchor { arView?.scene.removeAnchor(a) }
        if let a = manualSecondAnchor { arView?.scene.removeAnchor(a) }
        manualFirstAnchor = nil
        manualSecondAnchor = nil
    }

    private func applyManualTwoPointOrigin() {
        guard let p1 = manualFirstPoint, let p2 = manualSecondPoint else { return }
        // Compute yaw so +Z points toward p2 on XZ plane
        let dir = SIMD3<Float>(p2.x - p1.x, 0, p2.z - p1.z)
        var forward = dir
        let len = simd_length(forward)
        if len >= 1e-4 {
            forward /= len
        } else {
            forward = SIMD3<Float>(0, 0, 1)
        }
        let yaw = atan2(forward.x, forward.z)
        let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    var transform = float4x4(rotation)
    transform.columns.3 = SIMD4<Float>(p1.x, p1.y, p1.z, 1)
        print(String(format: "[ManualOrigin][Apply] p1=(%.3f, %.3f, %.3f) p2=(%.3f, %.3f, %.3f) yaw=%.3f", p1.x, p1.y, p1.z, p2.x, p2.y, p2.z, yaw))
        print("[ManualOrigin][Apply] Transform:")
        print("[ManualOrigin][Apply] [\(transform.columns.0)]")
        print("[ManualOrigin][Apply] [\(transform.columns.1)]")
        print("[ManualOrigin][Apply] [\(transform.columns.2)]")
        print("[ManualOrigin][Apply] [\(transform.columns.3)]")
        
        // Apply new FrameOrigin
        frameOriginTransform = transform
        placeFrameOriginGizmo(at: transform)
        updateMarkersForNewFrameOrigin()
        
        // Exit manual mode and restore UI
        cancelManualTwoPointsMode()

        // Persist the two points and their alignments for future edits
        preservedFirstPoint = p1
        preservedSecondPoint = p2
        preservedFirstPreferredAlignment = manualFirstPreferredAlignment
        preservedSecondPreferredAlignment = manualSecondPreferredAlignment
        print(String(format: "[ManualOrigin][Persist] Saved two points for future edit: p1=(%.3f, %.3f, %.3f) p2=(%.3f, %.3f, %.3f)", p1.x, p1.y, p1.z, p2.x, p2.y, p2.z))
    }

    /// Clear both points and restart Two Point placement from the first point
    private func clearTwoPointPlacement() {
        // Stop any movement
        endManualPointMove()
        selectedManualPointIndex = nil
        // Remove helper anchors (and spheres)
        removeManualAnchors()
        // Reset current and preserved state so re-entry starts fresh
        manualFirstPoint = nil
        manualSecondPoint = nil
        manualFirstPreferredAlignment = nil
        manualSecondPreferredAlignment = nil
        preservedFirstPoint = nil
        preservedSecondPoint = nil
        preservedFirstPreferredAlignment = nil
        preservedSecondPreferredAlignment = nil
        // Go back to placing the first point
        manualPlacementState = .placeFirst
        print("[ManualOrigin][Clear] Cleared two points; restarting placement at first point")
    }

    // MARK: - Manual point selection + moving
    private func updateManualPointSelection() {
        guard manualPlacementState != .inactive, let arView = arView, let frame = arView.session.currentFrame else { return }
        // First, try a precise hit-test at the screen center against our manual spheres
        if let hitIdx = manualPointIndexHitAtCenter(arView: arView) {
            if hitIdx != selectedManualPointIndex {
                selectedManualPointIndex = hitIdx
                updateManualPointColors()
                print("[ManualOrigin][Select] Hit center -> index = \(hitIdx)")
            }
            return
        }
        // Fallback: Determine which point (if any) is under crosshair by projecting to screen
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        let threshold: CGFloat = 36
        var nearestIndex: Int? = nil
        var nearestDist: CGFloat = .infinity
        if let a1 = manualFirstAnchor {
            let wp = a1.position(relativeTo: nil)
            if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                let d = hypot(sp.x - center.x, sp.y - center.y)
                print(String(format: "[ManualOrigin][Select] First dist=%.1f (th=%.1f)", d, threshold))
                if d < threshold && d < nearestDist { nearestDist = d; nearestIndex = 1 }
            }
        }
        if let a2 = manualSecondAnchor {
            let wp = a2.position(relativeTo: nil)
            if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                let d = hypot(sp.x - center.x, sp.y - center.y)
                print(String(format: "[ManualOrigin][Select] Second dist=%.1f (th=%.1f)", d, threshold))
                if d < threshold && d < nearestDist { nearestDist = d; nearestIndex = 2 }
            }
        }
        if nearestIndex != selectedManualPointIndex {
            selectedManualPointIndex = nearestIndex
            updateManualPointColors()
            print("[ManualOrigin][Select] Selected index = \(nearestIndex.map(String.init) ?? "nil")")
        }
    }

    private func manualPointIndexHitAtCenter(arView: ARView) -> Int? {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        // entity(at:) returns the topmost entity with collisions at that screen point
        if let entity = arView.entity(at: center) {
            if entity.name == "manual_point_1" { return 1 }
            if entity.name == "manual_point_2" { return 2 }
            // In case the returned entity is not the sphere but a child/parent, walk up one level
            if let parent = entity.parent {
                if parent.name == "manual_point_1" { return 1 }
                if parent.name == "manual_point_2" { return 2 }
            }
        }
        return nil
    }

    private func updateManualPointColors() {
        func setColor(anchor: AnchorEntity?, normalColor: UIColor, selected: Bool) {
            guard let anchor = anchor else { return }
            if let sphere = anchor.children.first(where: { $0.name.hasPrefix("manual_point_") }) as? ModelEntity {
                let color = selected ? UIColor.black : normalColor
                sphere.model?.materials = [SimpleMaterial(color: color, isMetallic: false)]
            }
        }
        setColor(anchor: manualFirstAnchor, normalColor: .red, selected: selectedManualPointIndex == 1)
        setColor(anchor: manualSecondAnchor, normalColor: .blue, selected: selectedManualPointIndex == 2)
    }

    private func startManualPointMove() {
        guard manualPointMoveTimer == nil else { return }
        // Capture FIXED screen point of the selected SPHERE (child), not the anchor
        // Anchor may still hold the original placement; the sphere is what we actually move
        if let arView, let frame = arView.session.currentFrame, let idx = selectedManualPointIndex {
            let anchor = (idx == 1) ? manualFirstAnchor : manualSecondAnchor
            let sphereName = (idx == 1) ? "manual_point_1" : "manual_point_2"
            if let a = anchor,
               let sphere = a.children.first(where: { $0.name == sphereName }) {
                let wp = sphere.position(relativeTo: nil)
                if let sp = projectWorldToScreen(worldPosition: SIMD3<Float>(wp.x, wp.y, wp.z), frame: frame, arView: arView) {
                    fixedManualMoveScreenPoint = sp
                    print("[ManualOrigin][Move] Fixed screen point set from sphere to: \(sp)")
                } else {
                    // Fallback to screen center
                    fixedManualMoveScreenPoint = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
                    print("[ManualOrigin][Move] Projection failed from sphere, using screen center as fixed point")
                }
            }
        }

        // Run at ~60 Hz for smooth movement
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            if fixedManualMoveScreenPoint != nil {
                moveSelectedPointUsingFixedScreenPoint()
            } else {
                moveSelectedPointToCrossRaycast()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualPointMoveTimer = timer
        print("[ManualOrigin][Move] Start move loop (60Hz)")
    }

    private func endManualPointMove() {
        manualPointMoveTimer?.invalidate()
        manualPointMoveTimer = nil
        fixedManualMoveScreenPoint = nil
        print("[ManualOrigin][Move] End move loop")
    }

    private func moveSelectedPointToCrossRaycast() {
        guard let idx = selectedManualPointIndex else { return }
        // Use per-point alignment chosen at placement; fallback to horizontal, then any.
        let preferred: ARRaycastQuery.TargetAlignment = {
            if idx == 1, let a = manualFirstPreferredAlignment { return a }
            if idx == 2, let a = manualSecondPreferredAlignment { return a }
            return .horizontal
        }()
        let newPos = raycastFromCenterForMove(preferredAlignment: preferred)
        guard let newPos else { return }
        // Optional: reject large jumps between discrete ticks
        if let old = (idx == 1 ? manualFirstPoint : manualSecondPoint) {
            let jump = simd_length(newPos - old)
            if jump > 0.5 { // 50 cm between 0.2s ticks is suspicious
                print(String(format: "[ManualOrigin][Move] Ignored jump=%.3f m", jump))
                return
            }
        }
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
        if idx == 1 {
            // Log before/after with [TwoPointMotion] prefix (measure on sphere child in world space)
            let before: SIMD3<Float> = {
                if let a = manualFirstAnchor,
                   let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                    let p = sphere.position(relativeTo: nil)
                    return SIMD3<Float>(p.x, p.y, p.z)
                }
                return manualFirstPoint ?? newPos
            }()
            if let old = manualFirstPoint {
                print(String(format: "[ManualOrigin][Move] First Δ=(%.3f, %.3f, %.3f) -> (%.3f, %.3f, %.3f)", newPos.x-old.x, newPos.y-old.y, newPos.z-old.z, newPos.x, newPos.y, newPos.z))
            } else {
                print(String(format: "[ManualOrigin][Move] First -> (%.3f, %.3f, %.3f)", newPos.x, newPos.y, newPos.z))
            }
            print(String(format: "[TwoPointMotion] idx=1 before=(%.3f, %.3f, %.3f) after=(%.3f, %.3f, %.3f) source=crosshair", before.x, before.y, before.z, newPos.x, newPos.y, newPos.z))
            manualFirstPoint = newPos
            if let a = manualFirstAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                // Set the sphere's world transform (avoid anchor composition)
                sphere.setTransformMatrix(t, relativeTo: nil)
                let ap = sphere.position(relativeTo: nil)
                let diff = SIMD3<Float>(ap.x - newPos.x, ap.y - newPos.y, ap.z - newPos.z)
                if simd_length(diff) > 1e-4 {
                    print(String(format: "[ManualOrigin][Move][Verify] Anchor-Target Δ=(%.4f, %.4f, %.4f)", diff.x, diff.y, diff.z))
                }
            }
        } else if idx == 2 {
            // Log before/after with [TwoPointMotion] prefix (measure on sphere child in world space)
            let before: SIMD3<Float> = {
                if let a = manualSecondAnchor,
                   let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                    let p = sphere.position(relativeTo: nil)
                    return SIMD3<Float>(p.x, p.y, p.z)
                }
                return manualSecondPoint ?? newPos
            }()
            if let old = manualSecondPoint {
                print(String(format: "[ManualOrigin][Move] Second Δ=(%.3f, %.3f, %.3f) -> (%.3f, %.3f, %.3f)", newPos.x-old.x, newPos.y-old.y, newPos.z-old.z, newPos.x, newPos.y, newPos.z))
            } else {
                print(String(format: "[ManualOrigin][Move] Second -> (%.3f, %.3f, %.3f)", newPos.x, newPos.y, newPos.z))
            }
            print(String(format: "[TwoPointMotion] idx=2 before=(%.3f, %.3f, %.3f) after=(%.3f, %.3f, %.3f) source=crosshair", before.x, before.y, before.z, newPos.x, newPos.y, newPos.z))
            manualSecondPoint = newPos
            if let a = manualSecondAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                // Set the sphere's world transform (avoid anchor composition)
                sphere.setTransformMatrix(t, relativeTo: nil)
                let ap = sphere.position(relativeTo: nil)
                let diff = SIMD3<Float>(ap.x - newPos.x, ap.y - newPos.y, ap.z - newPos.z)
                if simd_length(diff) > 1e-4 {
                    print(String(format: "[ManualOrigin][Move][Verify] Anchor-Target Δ=(%.4f, %.4f, %.4f)", diff.x, diff.y, diff.z))
                }
            }
        }
    }

    /// Move currently selected point using a FIXED screen point captured at movement start
    private func moveSelectedPointUsingFixedScreenPoint() {
        guard let arView, let idx = selectedManualPointIndex, let screenPoint = fixedManualMoveScreenPoint else { return }

        // Use per-point alignment chosen at placement; fallback to horizontal, then any.
        let preferred: ARRaycastQuery.TargetAlignment = {
            if idx == 1, let a = manualFirstPreferredAlignment { return a }
            if idx == 2, let a = manualSecondPreferredAlignment { return a }
            return .horizontal
        }()

        // Try existing plane with preferred alignment first
        func raycast(at p: CGPoint, allowing: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> SIMD3<Float>? {
            guard let q = arView.makeRaycastQuery(from: p, allowing: allowing, alignment: alignment) else { return nil }
            let results = arView.session.raycast(q)
            guard let first = results.first else { return nil }
            let t = first.worldTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }

        let newPos =
            raycast(at: screenPoint, allowing: .existingPlaneGeometry, alignment: preferred) ??
            raycast(at: screenPoint, allowing: .existingPlaneGeometry, alignment: .any) ??
            raycast(at: screenPoint, allowing: .estimatedPlane, alignment: preferred) ??
            raycast(at: screenPoint, allowing: .estimatedPlane, alignment: .any)

        guard let newPos else { return }

        // Optional: reject large jumps
        if let old = (idx == 1 ? manualFirstPoint : manualSecondPoint) {
            let jump = simd_length(newPos - old)
            if jump > 0.5 {
                print(String(format: "[ManualOrigin][Move][Fixed] Ignored jump=%.3f m", jump))
                return
            }
        }

        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(newPos.x, newPos.y, newPos.z, 1)
        if idx == 1 {
            let before: SIMD3<Float> = {
                if let a = manualFirstAnchor,
                   let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                    let p = sphere.position(relativeTo: nil)
                    return SIMD3<Float>(p.x, p.y, p.z)
                }
                return manualFirstPoint ?? newPos
            }()
            print(String(format: "[TwoPointMotion] idx=1 before=(%.3f, %.3f, %.3f) after=(%.3f, %.3f, %.3f) source=fixed", before.x, before.y, before.z, newPos.x, newPos.y, newPos.z))
            manualFirstPoint = newPos
            // Move the sphere child in world space (avoid anchor composition)
            if let a = manualFirstAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_1" }) {
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
            print(String(format: "[ManualOrigin][Move][Fixed] First -> (%.3f, %.3f, %.3f)", newPos.x, newPos.y, newPos.z))
        } else {
            let before: SIMD3<Float> = {
                if let a = manualSecondAnchor,
                   let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                    let p = sphere.position(relativeTo: nil)
                    return SIMD3<Float>(p.x, p.y, p.z)
                }
                return manualSecondPoint ?? newPos
            }()
            print(String(format: "[TwoPointMotion] idx=2 before=(%.3f, %.3f, %.3f) after=(%.3f, %.3f, %.3f) source=fixed", before.x, before.y, before.z, newPos.x, newPos.y, newPos.z))
            manualSecondPoint = newPos
            // Move the sphere child in world space (avoid anchor composition)
            if let a = manualSecondAnchor,
               let sphere = a.children.first(where: { $0.name == "manual_point_2" }) {
                sphere.setTransformMatrix(t, relativeTo: nil)
            }
            print(String(format: "[ManualOrigin][Move][Fixed] Second -> (%.3f, %.3f, %.3f)", newPos.x, newPos.y, newPos.z))
        }
    }

    private func projectWorldToScreen(worldPosition: SIMD3<Float>, frame: ARFrame, arView: ARView) -> CGPoint? {
        let camera = frame.camera
        // Use the current interface orientation instead of hard-coding portrait
        let orientation = arView.window?.windowScene?.interfaceOrientation ?? .portrait
        let viewMatrix = camera.viewMatrix(for: orientation)
        let projectionMatrix = camera.projectionMatrix(for: orientation, viewportSize: arView.bounds.size, zNear: 0.001, zFar: 1000)
        let worldPos4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        let viewPos = viewMatrix * worldPos4
        // Discard points behind the camera
        if viewPos.z > 0 { return nil }
        let projPos = projectionMatrix * viewPos
        guard projPos.w != 0 else { return nil }
        let ndcX = projPos.x / projPos.w
        let ndcY = projPos.y / projPos.w
        let screenX = (ndcX + 1.0) * 0.5 * Float(arView.bounds.width)
        let screenY = (1.0 - ndcY) * 0.5 * Float(arView.bounds.height)
        return CGPoint(x: CGFloat(screenX), y: CGFloat(screenY))
    }
    
    // MARK: - Registration Progress Overlay
    
    private var registrationProgressOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text(registrationProgress)
                .font(.subheadline)
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
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Model Loading Overlay
    
    private var modelLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text("Loading reference model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
    
    // MARK: - Scan Loading Overlay
    
    private var scanLoadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            
            Text("Loading scanned model...")
                .font(.subheadline)
                .foregroundColor(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(radius: 20)
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
                        CreateMarker(
                            workSessionId: session.id,
                            points: frameOriginPoints,
                            customProps: nil
                        )
                    )
                    markerService.linkSpatialMarker(localId: spatial.id, backendId: created.id)
                    print("[ARSession] [MarkerCreation] Created marker in FrameOrigin coordinates, id: \(created.id)")
                    
                    // Immediately refresh marker details for the newly created marker
                    Task {
                        print("[MarkerDetails] [NewMarker] Starting detail calculation for newly created marker \(created.id)")
                        await markerService.refreshMarkerDetails(backendId: created.id)
                        print("[MarkerDetails] [NewMarker] Completed detail calculation for marker \(created.id)")
                    }
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
    
    // Legacy single-finger move helpers replaced by ViewModel-driven movement
    
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
    
    // MARK: - Saved Scan Registration
    
    private func useSavedScan() async {
        let startTime = Date()
        isRegistering = true
        
        // Log registration settings
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[ARSession] SAVED SCAN REGISTRATION SETTINGS")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("Preset: \(settings.currentPreset.rawValue)")
        print("Model Points: \(settings.modelPointsSampleCount)")
        print("Scan Points: \(settings.scanPointsSampleCount)")
        print("Max Iterations: \(settings.maxICPIterations)")
        print("Convergence Threshold: \(settings.icpConvergenceThreshold)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        // Optionally pause AR session during registration
        if settings.pauseARDuringRegistration {
            await MainActor.run {
                captureSession.session.pause()
            }
        }
        
        defer {
            // Resume AR session if it was paused
            if settings.pauseARDuringRegistration {
                Task { @MainActor in
                    captureSession.session.run(captureSession.session.configuration!)
                    isRegistering = false
                }
            } else {
                Task { @MainActor in
                    isRegistering = false
                }
            }
        }
        
        do {
            // Step 1: Fetch the Space data
            let stepStart = Date()
            await MainActor.run {
                registrationProgress = "Loading space information..."
            }
            
            let space = try await spaceService.getSpace(id: session.spaceId)
            
            guard let usdcUrlString = space.modelUsdcUrl,
                  let usdcUrl = URL(string: usdcUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no USDC model"
                    errorMessage = "Space has no USDC model"
                }
                print("[ARSession] Error: Space has no USDC model")
                return
            }
            
            guard let scanUrlString = space.scanUrl,
                  let scanUrl = URL(string: scanUrlString) else {
                await MainActor.run {
                    registrationProgress = "Error: Space has no saved scan"
                    errorMessage = "Space has no saved scan"
                }
                print("[ARSession] Error: Space has no saved scan")
                return
            }
            
            if settings.showPerformanceLogs {
                print("[ARSession] Found space: \(space.name)")
                print("[ARSession] USDC URL: \(usdcUrlString)")
                print("[ARSession] Scan URL: \(scanUrlString)")
                print("[ARSession] ⏱️ Step 1 (Fetch space): \(Date().timeIntervalSince(stepStart))s")
            }
            
            // Step 2: Download USDC model
            let downloadStart = Date()
            await MainActor.run {
                registrationProgress = "Downloading space model..."
            }
            
            let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
            let tempDir = FileManager.default.temporaryDirectory
            let modelPath = tempDir.appendingPathComponent("space_model.usdc")
            try modelData.write(to: modelPath)
            
            if settings.showPerformanceLogs {
                print("[ARSession] Downloaded USDC model to: \(modelPath)")
                print("[ARSession] ⏱️ Step 2 (Download model): \(Date().timeIntervalSince(downloadStart))s")
            }
            
            // Step 3: Download saved scan
            let scanDownloadStart = Date()
            await MainActor.run {
                registrationProgress = "Downloading saved scan..."
            }
            
            let (scanData, _) = try await URLSession.shared.data(from: scanUrl)
            let scanPath = tempDir.appendingPathComponent("saved_scan.usdc")
            try scanData.write(to: scanPath)
            
            if settings.showPerformanceLogs {
                print("[ARSession] Downloaded saved scan to: \(scanPath)")
                print("[ARSession] ⏱️ Step 3 (Download scan): \(Date().timeIntervalSince(scanDownloadStart))s")
            }
            
            // Step 4: Load both models into SceneKit
            let loadStart = Date()
            await MainActor.run {
                registrationProgress = "Loading models..."
            }
            
            let loadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.convertUnitsToMeters: true,
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]
            
            let scanLoadOptions: [SCNSceneSource.LoadingOption: Any] = [
                SCNSceneSource.LoadingOption.flattenScene: true,
                SCNSceneSource.LoadingOption.checkConsistency: !settings.skipModelConsistencyChecks
            ]
            
            let (modelScene, scanScene): (SCNScene, SCNScene)
            if settings.useBackgroundLoading {
                (modelScene, scanScene) = await Task.detached(priority: .userInitiated) {
                    let modelScene = try SCNScene(url: modelPath, options: loadOptions)
                    let scanScene = try SCNScene(url: scanPath, options: scanLoadOptions)
                    return (modelScene, scanScene)
                }.value
            } else {
                modelScene = try SCNScene(url: modelPath, options: loadOptions)
                scanScene = try SCNScene(url: scanPath, options: scanLoadOptions)
            }
            
            let flattenedModelNode = SCNNode()
            flattenModelHierarchy(modelScene.rootNode, into: flattenedModelNode)
            
            let flattenedScanNode = SCNNode()
            flattenModelHierarchy(scanScene.rootNode, into: flattenedScanNode)
            
            if settings.showPerformanceLogs {
                print("[ARSession] Model node children: \(flattenedModelNode.childNodes.count)")
                print("[ARSession] Scan node children: \(flattenedScanNode.childNodes.count)")
                print("[ARSession] ⏱️ Step 4 (Load models): \(Date().timeIntervalSince(loadStart))s")
            }
            
            // Step 5: Extract point clouds
            let extractStart = Date()
            await MainActor.run {
                registrationProgress = "Extracting point clouds..."
            }
            
            let modelPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedModelNode,
                sampleCount: settings.modelPointsSampleCount
            )
            let scanPoints = ModelRegistrationService.extractPointCloud(
                from: flattenedScanNode,
                sampleCount: settings.scanPointsSampleCount
            )
            
            if settings.showPerformanceLogs {
                print("[ARSession] Model points: \(modelPoints.count) (target: \(settings.modelPointsSampleCount))")
                print("[ARSession] Scan points: \(scanPoints.count) (target: \(settings.scanPointsSampleCount))")
                print("[ARSession] ⏱️ Step 5 (Extract points): \(Date().timeIntervalSince(extractStart))s")
            }
            
            guard !modelPoints.isEmpty && !scanPoints.isEmpty else {
                await MainActor.run {
                    registrationProgress = "Error: Could not extract points"
                    errorMessage = "Could not extract points from models"
                }
                return
            }
            
            guard modelPoints.count > 100 && scanPoints.count > 100 else {
                await MainActor.run {
                    registrationProgress = "Error: Not enough points"
                    errorMessage = "Not enough points for registration"
                }
                return
            }
            
            // Step 6: Perform ICP registration
            let registrationStart = Date()
            await MainActor.run {
                registrationProgress = "Running registration algorithm..."
            }
            
            guard let result = await ModelRegistrationService.registerModels(
                modelPoints: modelPoints,
                scanPoints: scanPoints,
                maxIterations: settings.maxICPIterations,
                convergenceThreshold: Float(settings.icpConvergenceThreshold),
                progressHandler: { progress in
                    Task { @MainActor in
                        registrationProgress = progress
                    }
                }
            ) else {
                await MainActor.run {
                    registrationProgress = "Error: Registration failed"
                    errorMessage = "Registration failed"
                }
                return
            }
            
            if settings.showPerformanceLogs {
                print("[ARSession] Registration complete!")
                print("[ARSession] RMSE: \(result.rmse)")
                print("[ARSession] Inliers: \(result.inlierFraction)")
                print("[ARSession] Transform matrix: \(result.transformMatrix)")
                print("[ARSession] ⏱️ Step 6 (ICP registration): \(Date().timeIntervalSince(registrationStart))s")
                print("[ARSession] ⏱️ TOTAL TIME: \(Date().timeIntervalSince(startTime))s")
            }
            
            // Step 7: Apply transformation
            await MainActor.run {
                frameOriginTransform = result.transformMatrix
                placeFrameOriginGizmo(at: result.transformMatrix)
                updateMarkersForNewFrameOrigin()
                // NOTE: Reference model and scan model positions are automatically
                // updated via frameOriginTransform didSet observer
                
                registrationProgress = "Registration complete!"
                
                // Show brief success message
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isRegistering = false
                }
            }
            
        } catch {
            await MainActor.run {
                registrationProgress = "Error: \(error.localizedDescription)"
                errorMessage = "Registration failed: \(error.localizedDescription)"
            }
            print("[ARSession] Registration error: \(error)")
            
            // Auto-dismiss error after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isRegistering = false
            }
        }
    }
    
    // Helper function to flatten scene hierarchy
    private func flattenModelHierarchy(_ node: SCNNode, into container: SCNNode) {
        if let geometry = node.geometry {
            let clone = SCNNode(geometry: geometry)
            clone.transform = node.worldTransform
            container.addChildNode(clone)
        }
        for child in node.childNodes {
            flattenModelHierarchy(child, into: container)
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
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][GIZMO] 🎯 Placed FrameOrigin Gizmo")
        print("━���━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][GIZMO] Transform provided: \(transform)")
        print("[🔧 TRANSFORM][GIZMO] Gizmo position in world: \(anchor.position(relativeTo: nil))")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━��━━━━━━")
    }
    
    /// Drop FrameOrigin on the floor at screen center using raycast
    private func dropFrameOriginOnFloor() {
        guard let arView = arView else {
            print("[ARSession] ⚠️ Cannot drop FrameOrigin: arView is nil")
            return
        }
        
        // Raycast from screen center downward to find floor
        let screenCenter = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        
        // Try raycasting to existing horizontal planes (floor detection)
        if let query = arView.makeRaycastQuery(
            from: screenCenter,
            allowing: .existingPlaneGeometry,
            alignment: .horizontal
        ) {
            let results = arView.session.raycast(query)
            
            if let firstResult = results.first {
                // Found a horizontal plane (floor)
                let hitTransform = firstResult.worldTransform
                
                // Update the frame origin transform
                frameOriginTransform = hitTransform
                
                // Update the visual gizmo
                placeFrameOriginGizmo(at: hitTransform)
                
                // Update all existing markers to new coordinate system
                updateMarkersForNewFrameOrigin()
                
                // NOTE: Reference model anchor is automatically updated via frameOriginTransform didSet
                
                print("[ARSession] ✅ Dropped FrameOrigin on floor at: \(hitTransform.columns.3)")
                return
            }
        }
        
        // Fallback: raycast to estimated plane if no detected planes yet
        if let query = arView.makeRaycastQuery(
            from: screenCenter,
            allowing: .estimatedPlane,
            alignment: .horizontal
        ) {
            let results = arView.session.raycast(query)
            
            if let firstResult = results.first {
                let hitTransform = firstResult.worldTransform
                
                frameOriginTransform = hitTransform
                placeFrameOriginGizmo(at: hitTransform)
                updateMarkersForNewFrameOrigin()
                
                // NOTE: Reference model anchor is automatically updated via frameOriginTransform didSet
                
                print("[ARSession] ✅ Dropped FrameOrigin on estimated floor at: \(hitTransform.columns.3)")
                return
            }
        }
        
        // No floor found
        print("[ARSession] ⚠️ Could not find floor. Move device to scan horizontal surfaces.")
    }

    /// Start auto-dropping the FrameOrigin with retries until a plane is found or attempts are exhausted
    private func startAutoDropFrameOrigin(maxAttempts: Int = 15, interval: TimeInterval = 0.3) {
        // Prevent multiple timers
        autoDropTimer?.invalidate()
        autoDropAttempts = 0

        func attempt() {
            autoDropAttempts += 1
            let before = autoDropAttempts
            dropFrameOriginOnFloor()
            // Heuristic: if we have a non-identity transform on the gizmo anchor, consider it a success
            if let anchor = frameOriginAnchor {
                let t = anchor.transform.matrix
                let translation = t.columns.3
                let hasMoved = !(translation.x == 0 && translation.y == 0 && translation.z == 0)
                if hasMoved {
                    autoDropTimer?.invalidate()
                    autoDropTimer = nil
                    print("[ARSession] ✅ Auto-drop succeeded after \(before) attempt(s)")
                    return
                }
            }
            if before >= maxAttempts {
                autoDropTimer?.invalidate()
                autoDropTimer = nil
                print("[ARSession] ⚠️ Auto-drop attempts exhausted; keep FrameOrigin at current position")
            }
        }

        // First immediate attempt
        attempt()
        // Schedule subsequent attempts
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            attempt()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDropTimer = timer
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
                        customProps: marker.customProps,
                        createdAt: marker.createdAt,
                        updatedAt: marker.updatedAt,
                        details: marker.details
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
    
    // MARK: - Reference Model Management
    
    /// Place the reference model at FrameOrigin (the AR camera's initial position and orientation)
    private func placeModelAtFrameOrigin() {
        guard let arView = arView else {
            print("[ARSession] ARView not available")
            return
        }
        
        // Remove existing model if any
        removeReferenceModel()
        
        isLoadingModel = true
        
        Task {
            do {
                // Fetch space to get model URL
                let space = try await spaceService.getSpace(id: session.spaceId)
                
                guard let usdcUrlString = space.modelUsdcUrl,
                      let usdcUrl = URL(string: usdcUrlString) else {
                    await MainActor.run {
                        print("[ARSession] Space has no USDC model URL")
                        isLoadingModel = false
                        showReferenceModel = false
                    }
                    return
                }
                
                print("[ARSession] Loading reference model from: \(usdcUrlString)")
                
                // Download the model
                let (modelData, _) = try await URLSession.shared.data(from: usdcUrl)
                
                // Save to temporary file
                let tempDir = FileManager.default.temporaryDirectory
                let modelPath = tempDir.appendingPathComponent("reference_model.usdc")
                try modelData.write(to: modelPath)
                
                // Load the model entity
                let modelEntity = try await ModelEntity.loadModel(contentsOf: modelPath)
                
                await MainActor.run {
                    // In RealityKit, we need to apply the transform at the anchor level
                    // The anchor represents where this model should be in the world
                    let anchor = AnchorEntity(world: frameOriginTransform)
                    
                    // Model is at identity relative to the anchor
                    // This way, the model's authored (0,0,0) is at the anchor position
                    anchor.addChild(modelEntity)
                    
                    // Store reference and add to scene
                    referenceModelAnchor = anchor
                    arView.scene.addAnchor(anchor)
                    
                    isLoadingModel = false
                    
                    // Detailed logging
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("[🔧 TRANSFORM][REF_MODEL] 📦 Reference Model Loaded")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("[🔧 TRANSFORM][REF_MODEL] Current frameOriginTransform:")
                    print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.0)]")
                    print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.1)]")
                    print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.2)]")
                    print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.3)]")
                    print("[🔧 TRANSFORM][REF_MODEL] Anchor world position: \(anchor.position(relativeTo: nil))")
                    print("[🔧 TRANSFORM][REF_MODEL] Model local position: \(modelEntity.position)")
                    print("[🔧 TRANSFORM][REF_MODEL] Model local scale: \(modelEntity.scale)")
                    print("[🔧 TRANSFORM][REF_MODEL] Model bounds: \(modelEntity.visualBounds(relativeTo: nil))")
                    print("[🔧 TRANSFORM][REF_MODEL] Model world position: \(modelEntity.position(relativeTo: nil))")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                }
                
            } catch {
                await MainActor.run {
                    print("[ARSession] Failed to load reference model: \(error)")
                    isLoadingModel = false
                    showReferenceModel = false
                }
            }
        }
    }
    
    /// Remove the reference model from the scene
    private func removeReferenceModel() {
        guard let anchor = referenceModelAnchor else { return }
        
        arView?.scene.removeAnchor(anchor)
        referenceModelAnchor = nil
        
        print("[ARSession] Reference model removed")
        // Ensure the FrameOrigin gizmo remains present in the scene
        ensureFrameOriginGizmoPresent()
    }
    

    /// Ensure the FrameOrigin gizmo is present; if it's been detached from the scene, re-add it
    private func ensureFrameOriginGizmoPresent() {
        guard let arView, let anchor = frameOriginAnchor else { return }
        // Only re-add to the scene if it somehow got detached; do not change its transform
        if anchor.parent == nil {
            arView.scene.addAnchor(anchor)
        }
    }
    
    /// Update the FrameOrigin gizmo to match where the model is positioned
    /// Called automatically via frameOriginTransform didSet observer
    private func updateFrameOriginGizmoPosition() {
        guard let anchor = frameOriginAnchor else { return }
        
        // FrameOrigin represents the reference model's coordinate system
        // When we transform the model, we want FrameOrigin to show where (0,0,0) of the model is
        // Since the model entity gets frameOriginTransform applied, the gizmo should too
        anchor.transform = Transform(matrix: frameOriginTransform)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][GIZMO] 🎯 FrameOrigin Gizmo Updated")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][GIZMO] New frameOriginTransform:")
        print("[🔧 TRANSFORM][GIZMO]   [\(frameOriginTransform.columns.0)]")
        print("[🔧 TRANSFORM][GIZMO]   [\(frameOriginTransform.columns.1)]")
        print("[🔧 TRANSFORM][GIZMO]   [\(frameOriginTransform.columns.2)]")
        print("[🔧 TRANSFORM][GIZMO]   [\(frameOriginTransform.columns.3)]")
        print("[🔧 TRANSFORM][GIZMO] Gizmo world position: \(anchor.position(relativeTo: nil))")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    /// Update the reference model's anchor to the latest FrameOrigin transform
    /// Called automatically via frameOriginTransform didSet observer
    private func updateReferenceModelPosition() {
        guard let anchor = referenceModelAnchor else { return }
        
        // Update the anchor's transform to move the entire model
        // The model stays at identity relative to the anchor
        anchor.transform = Transform(matrix: frameOriginTransform)
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][REF_MODEL] 🔄 Reference Model Updated")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][REF_MODEL] New frameOriginTransform:")
        print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.0)]")
        print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.1)]")
        print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.2)]")
        print("[🔧 TRANSFORM][REF_MODEL]   [\(frameOriginTransform.columns.3)]")
        print("[🔧 TRANSFORM][REF_MODEL] Anchor world position: \(anchor.position(relativeTo: nil))")
        if let modelEntity = anchor.children.first as? ModelEntity {
            print("[🔧 TRANSFORM][REF_MODEL] Model local position: \(modelEntity.position)")
            print("[🔧 TRANSFORM][REF_MODEL] Model world position: \(modelEntity.position(relativeTo: nil))")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
    
    // MARK: - Scan Model Management
    
    /// Place the scanned model at FrameOrigin (the AR camera's initial position and orientation)
    private func placeScanModelAtFrameOrigin() {
        guard let arView = arView else {
            print("[ARSession] ARView not available")
            return
        }
        
        // Remove existing scan model if any
        removeScanModel()
        
        isLoadingScan = true
        
        Task {
            do {
                // Fetch space to get scan URL
                let space = try await spaceService.getSpace(id: session.spaceId)
                
                guard let scanUrlString = space.scanUrl,
                      let scanUrl = URL(string: scanUrlString) else {
                    await MainActor.run {
                        print("[ARSession] Space has no scan URL")
                        isLoadingScan = false
                        showScanModel = false
                    }
                    return
                }
                
                print("[ARSession] Loading scanned model from: \(scanUrlString)")
                
                // Download the scan
                let (scanData, _) = try await URLSession.shared.data(from: scanUrl)
                
                // Determine file extension from URL
                let fileExtension = scanUrl.pathExtension.lowercased()
                let fileName = "scanned_model.\(fileExtension.isEmpty ? "usdc" : fileExtension)"
                
                // Save to temporary file
                let tempDir = FileManager.default.temporaryDirectory
                let scanPath = tempDir.appendingPathComponent(fileName)
                try scanData.write(to: scanPath)
                
                // Load the model entity
                let scanEntity = try await ModelEntity.loadModel(contentsOf: scanPath)
                
                await MainActor.run {
                    // Scan stays at identity (it's the reference frame in registration)
                    // Place anchor at world origin with scan at identity
                    let anchor = AnchorEntity(world: matrix_identity_float4x4)
                    
                    // Scan entity has no additional transform (stays at world origin)
                    anchor.addChild(scanEntity)
                    
                    // Store reference and add to scene
                    scanModelAnchor = anchor
                    arView.scene.addAnchor(anchor)
                    
                    isLoadingScan = false
                    
                    // Detailed logging
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("[🔧 TRANSFORM][SCAN_MODEL] 🔍 Scan Model Loaded")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    print("[🔧 TRANSFORM][SCAN_MODEL] Current frameOriginTransform:")
                    print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.0)]")
                    print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.1)]")
                    print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.2)]")
                    print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.3)]")
                    print("[🔧 TRANSFORM][SCAN_MODEL] Anchor world position: \(anchor.position(relativeTo: nil))")
                    print("[🔧 TRANSFORM][SCAN_MODEL] Scan local position: \(scanEntity.position)")
                    print("[🔧 TRANSFORM][SCAN_MODEL] Scan local transform: \(scanEntity.transform)")
                    print("[🔧 TRANSFORM][SCAN_MODEL] Scan world position: \(scanEntity.position(relativeTo: nil))")
                    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                }
                
            } catch {
                await MainActor.run {
                    print("[ARSession] Failed to load scanned model: \(error)")
                    isLoadingScan = false
                    showScanModel = false
                }
            }
        }
    }
    
    /// Remove the scanned model from the scene
    private func removeScanModel() {
        guard let anchor = scanModelAnchor else { return }
        
        arView?.scene.removeAnchor(anchor)
        scanModelAnchor = nil
        
        print("[ARSession] Scanned model removed")
    }
    
    /// Update the scanned model's anchor to the latest FrameOrigin transform
    private func updateScanModelPosition() {
        guard let anchor = scanModelAnchor else { return }
        
        // Scan stays at identity (it's the reference frame)
        // No update needed - scan doesn't move when frameOriginTransform changes
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][SCAN_MODEL] 🔄 Scan Model Updated")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[🔧 TRANSFORM][SCAN_MODEL] New frameOriginTransform:")
        print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.0)]")
        print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.1)]")
        print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.2)]")
        print("[🔧 TRANSFORM][SCAN_MODEL]   [\(frameOriginTransform.columns.3)]")
        print("[🔧 TRANSFORM][SCAN_MODEL] Anchor world position: \(anchor.position(relativeTo: nil))")
        if let scanEntity = anchor.children.first as? ModelEntity {
            print("[🔧 TRANSFORM][SCAN_MODEL] Scan local position: \(scanEntity.position)")
            print("[🔧 TRANSFORM][SCAN_MODEL] Scan world position: \(scanEntity.position(relativeTo: nil))")
        }
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }
}



// MARK: - Preview

// Private overlay to detect two-finger contacts immediately and forward begin/end.
// Extracted TwoFingerTouchOverlay into Views/Components for reuse

// Extracted MarkerBadgeView and EdgeDistanceView into Views/Components for reuse

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