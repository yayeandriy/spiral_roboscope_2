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
import Combine
import QuartzCore

struct ARSessionView: View {
    let session: WorkSession
    @Environment(\.dismiss) private var dismiss
    @StateObject var captureSession: CaptureSession
    @StateObject var markerService: SpatialMarkerService
    @StateObject var workSessionService: WorkSessionService
    @StateObject var markerApi: MarkerService
    @StateObject var spaceService: SpaceService
    @StateObject var settings: AppSettings
    @StateObject var viewModel: ARSessionViewModel
    @StateObject var laserDetection = LaserDetectionService()

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

    @State var arView: ARView?
    @State private var isSessionActive = false
    @State var errorMessage: String?
    @State private var showScanView = false
    @State var isRegistering = false
    @State var registrationProgress: String = ""
    @State private var showActionsDialog: Bool = false
    @State var frameOriginTransform: simd_float4x4 = matrix_identity_float4x4 {
        didSet {
            // Automatically update all entities when FrameOrigin changes
            // FrameOrigin represents the reference model's coordinate system origin
            updateFrameOriginGizmoPosition()
            updateReferenceModelPosition()
            updateScanModelPosition()
        }
    }
    @State var frameOriginAnchor: AnchorEntity?
    
    // Manual Two-Point Origin placement
    enum ManualPlacementState { case inactive, placeFirst, placeSecond, readyToApply }
    @State var manualPlacementState: ManualPlacementState = .inactive
    @State var manualFirstPoint: SIMD3<Float>? = nil
    @State var manualSecondPoint: SIMD3<Float>? = nil
    // Persisted two-point positions (last applied) to restore on next entry into Two Point mode
    @State var preservedFirstPoint: SIMD3<Float>? = nil
    @State var preservedSecondPoint: SIMD3<Float>? = nil
    @State var manualFirstAnchor: AnchorEntity? = nil
    @State var manualSecondAnchor: AnchorEntity? = nil
    @State var manualFirstPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State var manualSecondPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    // Persisted preferred alignments to restore editing behavior
    @State var preservedFirstPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State var preservedSecondPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State var selectedManualPointIndex: Int? = nil // 1 or 2
    @State var manualPointMoveTimer: Timer? = nil
    @State var fixedManualMoveScreenPoint: CGPoint? = nil // Fixed screen point captured at movement start
    
    // Reference model state
    @State private var showReferenceModel = false
    @State var referenceModelAnchor: AnchorEntity?
    @State private var isLoadingModel = false
    @State var referenceModelEntity: ModelEntity?  // For RealityKit raycasting
    
    // Scan model state
    @State private var showScanModel = false
    @State var scanModelAnchor: AnchorEntity?
    @State private var isLoadingScan = false

    // Match scanning interactions
    @State var autoDropTimer: Timer?
    @State var autoDropAttempts: Int = 0
    @State var cancellables = Set<AnyCancellable>()
    @State private var imageToViewTransform: CGAffineTransform = .identity
    @State private var viewportSize: CGSize = .zero
    // one-finger edge move is now handled by the overlay's one-finger pan
    
    // MARK: - Computed Properties
    
    private var associatedSpaceName: String? {
        guard let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) else {
            return "Space: \(session.spaceId.uuidString.prefix(8))..."
        }
        return space.name
    }

    private var isLaserGuideSession: Bool {
        session.isLaserGuide
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // AR View
                ARViewContainer(
                    session: captureSession.session,
                    arView: $arView
                )
                .onAppear {
                    startARSession()

                    if isLaserGuideSession {
                        laserDetection.startDetection()
                    }
                    
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
                                calibratedData: marker.calibratedData,
                                color: marker.color,
                                version: marker.version,
                                meta: marker.meta,
                                customProps: marker.customProps,
                                createdAt: marker.createdAt,
                                updatedAt: marker.updatedAt,
                                details: marker.details
                            )
                        }
                        // Pass both world and frame-origin coordinates
                        markerService.loadPersistedMarkers(transformedMarkers, originalFrameOriginMarkers: persisted)
                        // Calculate details for any markers that don't have them yet
                        for marker in transformedMarkers {
                            if marker.details == nil {
                                Task {
                                    await markerService.refreshMarkerDetails(backendId: marker.id)
                                }
                            }
                        }
                    } catch {
                        // Silent
                    }
                }
            }
            .onDisappear {
                laserDetection.stopDetection()
                viewModel.cancelAllTimers()
                autoDropTimer?.invalidate()
                autoDropTimer = nil
                autoDropAttempts = 0
                endManualPointMove()
                endARSession()
                cancellables.removeAll()
            }
            .onChange(of: arView) { newValue in
                markerService.arView = newValue
                viewModel.bindARView(newValue)
                
                // Set up frame callback for laser detection
                if isLaserGuideSession, let arView = newValue {
                    arView.scene.subscribe(to: SceneEvents.Update.self) { event in
                        if let frame = arView.session.currentFrame {
                            self.laserDetection.processFrame(frame)

                            // Map normalized image coordinates -> normalized view coordinates.
                            // Use the same viewport size that the overlay will use for pixel conversion.
                            // We assume portrait UI; if you support rotation, this should track device orientation.
                            if self.viewportSize.width > 0 && self.viewportSize.height > 0 {
                                self.imageToViewTransform = frame.displayTransform(for: .portrait, viewportSize: self.viewportSize)
                            }
                        }
                    }.store(in: &cancellables)
                }
            }
            .onAppear {
                // Initialize viewport size to full screen (ignoring safe areas)
                self.viewportSize = UIScreen.main.bounds.size
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
                .padding(.top, 40)
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
                .padding(.top, 56)
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
            
            // Laser detection overlay (only in LaserGuide mode)
            if isLaserGuideSession {
                LaserDetectionOverlay(
                    detectedPoints: laserDetection.detectedPoints,
                    viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                    laserService: laserDetection,
                    imageToViewTransform: imageToViewTransform,
                    arView: arView,
                    onDotLineMeasurement: nil
                )
                .zIndex(2)
                .onAppear {
                    // Use full screen size (ignoring safe areas) for coordinate mapping
                    viewportSize = UIScreen.main.bounds.size
                }
            }
            }  // Close GeometryReader
        }
        .ignoresSafeArea(.all)
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage = errorMessage { Text(errorMessage) }
        }
        .confirmationDialog("Actions", isPresented: $showActionsDialog, titleVisibility: .visible) {
            if !isLaserGuideSession {
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
            }

            // Drop FrameOrigin on floor
            Button("Drop FrameOrigin", role: .none) {
                dropFrameOriginOnFloor()
            }

            if !isLaserGuideSession {
                // Use saved scan
                Button("Use saved scan", role: .none) {
                    Task { await useSavedScan() }
                }
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

    // MARK: - Manual Two-Point Placement moved to extension
    
    // MARK: - Actions
    
    private func startARSession() {
        captureSession.start()
        isSessionActive = true
    }
    
    private func endARSession() {
        // Realtime features disabled: no presence leave / lock release
        captureSession.stop()
        isSessionActive = false
    }
    
    // MARK: - Marker helpers moved to extension
    
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
    
    // MARK: - Saved Scan Registration moved to extension
    
    // MARK: - Frame Origin Gizmo moved to extension
    
    // MARK: - Coordinate System Transformation moved to extension
    
    // MARK: - Model Management moved to extension
}

// MARK: - LaserGuide AR Session View

/// Dedicated LaserGuide AR experience (forked from ARSessionView).
/// This is intentionally separate so LaserGuide workflow changes don't destabilize the default AR session flow.
struct LaserGuideARSessionView: View {
    let session: WorkSession
    @Environment(\.dismiss) private var dismiss
    @StateObject var captureSession: CaptureSession
    @StateObject var markerService: SpatialMarkerService
    @StateObject var workSessionService: WorkSessionService
    @StateObject var markerApi: MarkerService
    @StateObject var spaceService: SpaceService
    @StateObject var settings: AppSettings
    @StateObject var viewModel: ARSessionViewModel
    @StateObject var laserDetection = LaserDetectionService()
    @State private var laserGuide: LaserGuide? = nil
    @State private var laserGuideFetchError: String? = nil
    @State private var lastLaserGuideSnapTime: TimeInterval = 0
    @State private var latestLaserMeasurement: LaserDotLineMeasurement? = nil
    @State var hasAutoScoped: Bool = false
    @State private var autoScopeCandidateKey: String? = nil
    @State private var autoScopeSamples: [(t: TimeInterval, d: Float)] = []
    @State private var autoScopeLastSeenTime: TimeInterval = 0
    @State private var autoScopedDotWorld: SIMD3<Float>? = nil
    @State private var autoScopedAtTime: TimeInterval = 0
    @State private var autoScopedDotLocalZ: Float? = nil
    @State private var autoScopeRestartThresholdZMeters: Float? = nil
    @State private var autoScopedSegment: LaserGuideGridSegment? = nil
    @State private var debugDotAnchor: AnchorEntity? = nil
    @State private var debugLineAnchor: AnchorEntity? = nil
    @State private var showDetectionSettings = false

    private let laserGuideDistanceToleranceMeters: Float = 0.03
    private let laserGuideSnapCooldownSeconds: TimeInterval = 0.6
    private let autoScopeStableSeconds: TimeInterval = 1.0
    private let autoScopeAllowedJitterMeters: Float = 0.01
    private let autoScopeAllowedGapSeconds: TimeInterval = 0.25
    private let autoScopeMinSamples: Int = 8

    private var locatingDistanceText: String {
        if let d = latestLaserMeasurement?.distanceMeters {
            return String(format: "%.2f m", d)
        }
        if let d = autoScopeSamples.last?.d {
            return String(format: "%.2f m", d)
        }
        return "--"
    }

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

    @State var arView: ARView?
    @State private var isSessionActive = false
    @State var errorMessage: String?
    @State private var showScanView = false
    @State var isRegistering = false
    @State var registrationProgress: String = ""
    @State private var showActionsDialog: Bool = false
    @State var frameOriginTransform: simd_float4x4 = matrix_identity_float4x4 {
        didSet {
            // Automatically update all entities when FrameOrigin changes
            updateFrameOriginGizmoPosition()
            updateReferenceModelPosition()
            updateScanModelPosition()
        }
    }
    @State var frameOriginAnchor: AnchorEntity?

    // Manual Two-Point Origin placement
    enum ManualPlacementState { case inactive, placeFirst, placeSecond, readyToApply }
    @State var manualPlacementState: ManualPlacementState = .inactive
    @State var manualFirstPoint: SIMD3<Float>? = nil
    @State var manualSecondPoint: SIMD3<Float>? = nil
    // Persisted two-point positions (last applied) to restore on next entry into Two Point mode
    @State var preservedFirstPoint: SIMD3<Float>? = nil
    @State var preservedSecondPoint: SIMD3<Float>? = nil
    @State var manualFirstAnchor: AnchorEntity? = nil
    @State var manualSecondAnchor: AnchorEntity? = nil
    @State var manualFirstPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State var manualSecondPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    // Persisted preferred alignments to restore editing behavior
    @State var preservedFirstPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State var preservedSecondPreferredAlignment: ARRaycastQuery.TargetAlignment? = nil
    @State var selectedManualPointIndex: Int? = nil // 1 or 2
    @State var manualPointMoveTimer: Timer? = nil
    @State var fixedManualMoveScreenPoint: CGPoint? = nil // Fixed screen point captured at movement start

    // Reference model state
    @State private var showReferenceModel = false
    @State var referenceModelAnchor: AnchorEntity?
    @State private var isLoadingModel = false
    @State var referenceModelEntity: ModelEntity?  // For RealityKit raycasting

    // Scan model state
    @State private var showScanModel = false
    @State var scanModelAnchor: AnchorEntity?
    @State private var isLoadingScan = false

    // Match scanning interactions
    @State var autoDropTimer: Timer?
    @State var autoDropAttempts: Int = 0
    @State var cancellables = Set<AnyCancellable>()
    @State private var imageToViewTransform: CGAffineTransform = .identity
    @State private var viewportSize: CGSize = .zero

    // MARK: - Computed Properties

    private var associatedSpaceName: String? {
        guard let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) else {
            return "Space: \(session.spaceId.uuidString.prefix(8))..."
        }
        return space.name
    }

    private var isLaserGuideSession: Bool {
        true
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // AR View
                ARViewContainer(
                    session: captureSession.session,
                    arView: $arView
                )
                .onAppear {
                    print("[LaserGuideSnap] ARViewContainer appeared, starting session")
                    startARSession()
                    laserDetection.startDetection()

                    Task {
                        print("[LaserGuideSnap] Launching fetchLaserGuideIfNeeded task")
                        await fetchLaserGuideIfNeeded()
                    }

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
                                    calibratedData: marker.calibratedData,
                                    color: marker.color,
                                    version: marker.version,
                                    meta: marker.meta,
                                    customProps: marker.customProps,
                                    createdAt: marker.createdAt,
                                    updatedAt: marker.updatedAt,
                                    details: marker.details
                                )
                            }
                            // Pass both world and frame-origin coordinates
                            markerService.loadPersistedMarkers(transformedMarkers, originalFrameOriginMarkers: persisted)
                            // Calculate details for any markers that don't have them yet
                            for marker in transformedMarkers {
                                if marker.details == nil {
                                    Task {
                                        await markerService.refreshMarkerDetails(backendId: marker.id)
                                    }
                                }
                            }
                        } catch {
                            // Silent
                        }
                    }
                }
                .onDisappear {
                    laserDetection.stopDetection()
                    viewModel.cancelAllTimers()
                    autoDropTimer?.invalidate()
                    autoDropTimer = nil
                    autoDropAttempts = 0
                    endManualPointMove()
                    endARSession()
                    cancellables.removeAll()
                }
                .onChange(of: arView) { newValue in
                    markerService.arView = newValue
                    viewModel.bindARView(newValue)

                    // Keep marker visibility consistent with the current mode.
                    Task { @MainActor in
                        markerService.setMarkersVisible(hasAutoScoped)
                    }

                    // Hide origin + debug detections while locating.
                    frameOriginAnchor?.isEnabled = hasAutoScoped
                    debugDotAnchor?.isEnabled = hasAutoScoped
                    debugLineAnchor?.isEnabled = hasAutoScoped

                    // Set up frame callback for laser detection
                    if let arView = newValue {
                        arView.scene.subscribe(to: SceneEvents.Update.self) { _ in
                            if let frame = arView.session.currentFrame {
                                self.laserDetection.processFrame(frame)

                                // After auto-scope, monitor how far the user moves away from the scoped dot.
                                self.maybeReturnToDetectionIfUserMovedAway(frame)

                                // Map normalized image coordinates -> normalized view coordinates.
                                if self.viewportSize.width > 0 && self.viewportSize.height > 0 {
                                    self.imageToViewTransform = frame.displayTransform(for: .portrait, viewportSize: self.viewportSize)
                                }
                            }
                        }.store(in: &cancellables)
                    }
                }
                .onAppear {
                    // Initialize viewport size to full screen (ignoring safe areas)
                    self.viewportSize = UIScreen.main.bounds.size
                }

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
                    .padding(.top, 40)
                    .allowsHitTesting(false)
                    .zIndex(1)

                // Top controls
                VStack {
                    HStack(spacing: 12) {
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
                    .padding(.top, 56)
                    Spacer()
                }
                .zIndex(2)

                // Detection Settings Panel (top-left)
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            // Toggle button
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    showDetectionSettings.toggle()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Detection")
                                        .font(.system(size: 14, weight: .semibold))
                                    Image(systemName: showDetectionSettings ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
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
                            
                            // Settings panel
                            if showDetectionSettings {
                                VStack(alignment: .leading, spacing: 12) {
                                    // Hue Mode toggle
                                    Toggle(isOn: $laserDetection.useHueDetection) {
                                        Text("Hue Mode")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white.opacity(0.9))
                                    }
                                    .toggleStyle(.switch)
                                    .tint(.yellow)

                                    // Hue (only used in Hue Mode)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Hue")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.9))
                                            Spacer()
                                            Text(String(format: "%.2f", laserDetection.targetHue))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.yellow)
                                        }
                                        Slider(value: $laserDetection.targetHue, in: 0.00...1.00, step: 0.01)
                                            .tint(.yellow)
                                    }
                                    .disabled(!laserDetection.useHueDetection)
                                    .opacity(laserDetection.useHueDetection ? 1.0 : 0.5)

                                    // Brightness Threshold
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Brightness")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.9))
                                            Spacer()
                                            Text(String(format: "%.2f", laserDetection.brightnessThreshold))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.yellow)
                                        }
                                        Slider(value: $laserDetection.brightnessThreshold, in: 0.30...0.98, step: 0.01)
                                            .tint(.yellow)
                                    }
                                    .disabled(laserDetection.useHueDetection)
                                    .opacity(laserDetection.useHueDetection ? 0.5 : 1.0)
                                    
                                    // Line Ratio (Anisotropy)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Line Ratio")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.9))
                                            Spacer()
                                            Text(String(format: "%.1f", laserDetection.lineAnisotropyThreshold))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.yellow)
                                        }
                                        Slider(value: $laserDetection.lineAnisotropyThreshold, in: 2.0...12.0, step: 0.5)
                                            .tint(.yellow)
                                    }
                                    
                                    // Min Size
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Min Size")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.9))
                                            Spacer()
                                            Text(String(format: "%.3f", laserDetection.minBlobSize))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.yellow)
                                        }
                                        Slider(value: Binding(
                                            get: { Double(laserDetection.minBlobSize) },
                                            set: { laserDetection.minBlobSize = CGFloat($0) }
                                        ), in: 0.001...0.010, step: 0.001)
                                            .tint(.yellow)
                                    }
                                    
                                    // Max Y Delta
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text("Max Y Delta")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white.opacity(0.9))
                                            Spacer()
                                            Text(String(format: "%.2fm", laserDetection.maxDotLineYDeltaMeters))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.yellow)
                                        }
                                        Slider(value: $laserDetection.maxDotLineYDeltaMeters, in: 0.05...0.50, step: 0.05)
                                            .tint(.yellow)
                                    }
                                }
                                .padding(12)
                                .frame(width: 220)
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
                                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                                .padding(.top, 4)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.top, 120)
                    
                    Spacer()
                }
                .zIndex(4)

                if isRegistering {
                    registrationProgressOverlay
                        .zIndex(3)
                }
                if isLoadingModel {
                    modelLoadingOverlay
                        .zIndex(3)
                }
                if isLoadingScan {
                    scanLoadingOverlay
                        .zIndex(3)
                }

                VStack {
                    Spacer()

                    if hasAutoScoped, let info = markerService.selectedMarkerInfo {
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

                    HStack {
                        Spacer()
                        if manualPlacementState == .inactive {
                            HStack(spacing: 20) {
                                if hasAutoScoped {
                                    // Add marker button (only after origin has auto-scoped)
                                    Button { createAndPersistMarker() } label: {
                                        Image(systemName: viewModel.isTwoFingers ? "hand.tap.fill" : (viewModel.isHoldingScreen ? "hand.point.up.fill" : "plus"))
                                            .font(.system(size: 36))
                                            .frame(width: 80, height: 80)
                                    }
                                    .buttonStyle(.plain)
                                    .lgCircle(tint: .white)
                                } else {
                                    // Locating badge (replaces plus button until auto-scope)
                                    VStack(spacing: 2) {
                                        Text("Locating...")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text(locatingDistanceText)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.yellow)
                                    }
                                    .frame(width: 120, height: 80)
                                    .lgCapsule(tint: .white)
                                }
                            }
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 50)
                }
                .animation(.easeInOut(duration: 0.2), value: markerService.selectedMarkerID)

                // Restart detection button (moved to bottom-left corner; replaces the old distance badge position)
                if hasAutoScoped {
                    VStack {
                        Spacer()
                        HStack {
                            Button {
                                enterDetectionMode()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 36)
                            }
                            .buttonStyle(.plain)
                            .lgCapsule(tint: .white)

                            Spacer()
                        }
                        .padding(.leading, 16)
                        .padding(.bottom, 50)
                    }
                    .zIndex(3)
                }

                // Snapped segment (x/z) display (bottom-right, only after auto-scope)
                if hasAutoScoped, let seg = autoScopedSegment {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("x: \(String(format: "%.2f", seg.x))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("z: \(String(format: "%.2f", seg.z))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .lgCapsule(tint: .white)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 50)
                    }
                    .zIndex(3)
                }

                LaserDetectionOverlay(
                    detectedPoints: laserDetection.detectedPoints,
                    viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                    laserService: laserDetection,
                    imageToViewTransform: imageToViewTransform,
                    arView: arView,
                    onDotLineMeasurement: { measurement in
                        latestLaserMeasurement = measurement

                        // Auto-scope (debounced): require a stable match for ~1s to reduce accidental jumps.
                        maybeAutoScope(measurement)
                    }
                )
                .zIndex(2)
                .onAppear {
                    viewportSize = UIScreen.main.bounds.size
                }
            }
        }
        .ignoresSafeArea(.all)
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage = errorMessage { Text(errorMessage) }
        }
        .confirmationDialog("Actions", isPresented: $showActionsDialog, titleVisibility: .visible) {
            Button("Drop FrameOrigin", role: .none) {
                dropFrameOriginOnFloor()
            }

            if manualPlacementState == .inactive {
                Button("Manual Two Points") { enterManualTwoPointsMode() }
            } else {
                Button("Cancel Manual Placement", role: .destructive) { cancelManualTwoPointsMode() }
            }

            Button("Delete All Markers", role: .destructive) {
                clearAllMarkersPersisted()
            }
        }
        .sheet(isPresented: $showScanView) {
            SessionScanView(
                session: session,
                captureSession: captureSession,
                onRegistrationComplete: { transform in
                    frameOriginTransform = transform
                    updateMarkersForNewFrameOrigin()
                }
            )
        }
        .navigationBarBackButtonHidden()
    }

    private func startARSession() {
        captureSession.start()
        isSessionActive = true
    }

    @MainActor
    private func fetchLaserGuideIfNeeded() async {
        guard laserGuide == nil else { return }
        do {
            laserGuideFetchError = nil
            laserGuide = try await LaserGuideService.shared.fetchLaserGuide(spaceId: session.spaceId)
            print("[LaserGuideSnap] Fetched guide with \(laserGuide?.grid.count ?? 0) segments")
            laserGuide?.grid.forEach { seg in
                print("[LaserGuideSnap]   Segment: x=\(seg.x), z=\(seg.z), length=\(seg.segmentLength)")
            }
        } catch {
            print("[LaserGuideSnap] Fetch failed: \(error)")
            laserGuideFetchError = error.localizedDescription
            laserGuide = nil
        }
    }

    @discardableResult
    private func applyLaserGuideIfPossible(_ measurement: LaserDotLineMeasurement?) -> LaserGuideGridSegment? {
        guard let measurement else {
            print("[LaserGuideSnap] No measurement")
            return nil
        }
        guard let laserGuide else {
            print("[LaserGuideSnap] No laser guide loaded")
            return nil
        }
        guard !laserGuide.grid.isEmpty else {
            print("[LaserGuideSnap] Grid is empty")
            return nil
        }

        let now = CACurrentMediaTime()
        guard now - lastLaserGuideSnapTime >= laserGuideSnapCooldownSeconds else {
            print("[LaserGuideSnap] Cooldown active (last snap \(now - lastLaserGuideSnapTime)s ago)")
            return nil
        }

        print("[LaserGuideSnap] Measurement: dot=\(measurement.dotWorld), line=\(measurement.lineWorld), dist=\(measurement.distanceMeters)m")

        // Match distance to any segment length.
        if let best = laserGuide.grid.min(by: {
            abs(Float($0.segmentLength) - measurement.distanceMeters) < abs(Float($1.segmentLength) - measurement.distanceMeters)
        }) {
            let delta = abs(Float(best.segmentLength) - measurement.distanceMeters)
            print("[LaserGuideSnap] Best match: segment(x=\(best.x), z=\(best.z), len=\(best.segmentLength)), delta=\(delta)m, tolerance=\(laserGuideDistanceToleranceMeters)m")
            
            guard delta <= laserGuideDistanceToleranceMeters else {
                print("[LaserGuideSnap] Delta exceeds tolerance, skipping snap")
                return nil
            }

            print("[LaserGuideSnap] ✓ Snapping origin to align dot at segment (x=\(best.x), z=\(best.z))")
            snapFrameOriginToAlignDot(dotWorld: measurement.dotWorld, lineWorld: measurement.lineWorld, segment: best)
            lastLaserGuideSnapTime = now
            return best
        } else {
            print("[LaserGuideSnap] No segments to match")
            return nil
        }
    }

    private func resetAutoScopeStability() {
        autoScopeCandidateKey = nil
        autoScopeSamples = []
        autoScopeLastSeenTime = 0
    }

    private func enterDetectionMode() {
        // Restart AR tracking so detection restarts in a fresh AR world.
        captureSession.restart()

        hasAutoScoped = false
        latestLaserMeasurement = nil
        lastLaserGuideSnapTime = 0
        autoScopedDotWorld = nil
        autoScopedAtTime = 0
        autoScopedDotLocalZ = nil
        autoScopeRestartThresholdZMeters = nil
        autoScopedSegment = nil
        resetAutoScopeStability()

        // In detection mode we hide the origin gizmo + any debug detection spheres.
        frameOriginAnchor?.isEnabled = false
        debugDotAnchor?.isEnabled = false
        debugLineAnchor?.isEnabled = false

        Task { @MainActor in
            markerService.setMarkersVisible(false)
        }

        laserDetection.startDetection()
    }

    private func computeAutoRestartThresholdZ(for segment: LaserGuideGridSegment) -> Float? {
        guard let laserGuide, laserGuide.grid.count >= 2 else { return nil }

        // Prefer neighbors with the same X (typical “column” alignment), but fall back to any segment.
        let xEpsilon: Double = 1e-4
        let sameX = laserGuide.grid.filter { abs($0.x - segment.x) <= xEpsilon }
        let pool = (sameX.count >= 2) ? sameX : laserGuide.grid

        let z0 = segment.z
        let deltas = pool
            .map { abs($0.z - z0) }
            .filter { $0 > 1e-6 }

        guard let minDelta = deltas.min() else { return nil }
        return 0.5 * Float(minDelta)
    }

    private func candidateSegment(for distanceMeters: Float) -> (key: String, segment: LaserGuideGridSegment, delta: Float)? {
        guard let laserGuide, !laserGuide.grid.isEmpty else { return nil }
        guard let best = laserGuide.grid.min(by: {
            abs(Float($0.segmentLength) - distanceMeters) < abs(Float($1.segmentLength) - distanceMeters)
        }) else {
            return nil
        }
        let delta = abs(Float(best.segmentLength) - distanceMeters)
        let key = "x=\(best.x),z=\(best.z),len=\(best.segmentLength)"
        return (key: key, segment: best, delta: delta)
    }

    private func maybeAutoScope(_ measurement: LaserDotLineMeasurement?) {
        guard !hasAutoScoped else { return }

        let now = CACurrentMediaTime()

        // Allow occasional missed frames without resetting immediately.
        if measurement == nil {
            if autoScopeLastSeenTime > 0, now - autoScopeLastSeenTime > autoScopeAllowedGapSeconds {
                resetAutoScopeStability()
            }
            return
        }

        guard let measurement else { return }
        autoScopeLastSeenTime = now

        // Must match a segment within tolerance; otherwise reset stability window.
        guard let candidate = candidateSegment(for: measurement.distanceMeters), candidate.delta <= laserGuideDistanceToleranceMeters else {
            resetAutoScopeStability()
            return
        }

        // Segment must remain consistent during the stability window.
        if autoScopeCandidateKey != candidate.key {
            autoScopeCandidateKey = candidate.key
            autoScopeSamples = []
        }

        autoScopeSamples.append((t: now, d: measurement.distanceMeters))
        autoScopeSamples = autoScopeSamples.filter { now - $0.t <= autoScopeStableSeconds }

        // Need enough coverage across the window.
        guard autoScopeSamples.count >= autoScopeMinSamples else { return }
        guard let first = autoScopeSamples.first, let last = autoScopeSamples.last else { return }
        guard last.t - first.t >= autoScopeStableSeconds * 0.9 else { return }

        // Require distances to be stable (within a small jitter band).
        let distances = autoScopeSamples.map { $0.d }
        let minD = distances.min() ?? measurement.distanceMeters
        let maxD = distances.max() ?? measurement.distanceMeters
        guard (maxD - minD) <= (autoScopeAllowedJitterMeters * 2) else { return }

        // If stable, snap (subject to cooldown) and stop detection.
        if let snappedSegment = applyLaserGuideIfPossible(measurement) {
            autoScopedDotWorld = measurement.dotWorld
            autoScopedAtTime = now
            autoScopedSegment = snappedSegment

            // Store dot Z in FrameOrigin coordinates (after snap).
            let inv = frameOriginTransform.inverse
            let dotLocal = inv * SIMD4<Float>(measurement.dotWorld.x, measurement.dotWorld.y, measurement.dotWorld.z, 1)
            autoScopedDotLocalZ = dotLocal.z

            // Dynamic restart threshold: half of the Z spacing to the nearest neighbor segment.
            autoScopeRestartThresholdZMeters = computeAutoRestartThresholdZ(for: snappedSegment)

            hasAutoScoped = true

            // After auto-scope, show origin gizmo again.
            frameOriginAnchor?.isEnabled = true

            // After auto-scope, show debug spheres again.
            debugDotAnchor?.isEnabled = true
            debugLineAnchor?.isEnabled = true

            Task { @MainActor in
                markerService.setMarkersVisible(true)
            }

            laserDetection.stopDetection()
            resetAutoScopeStability()
        }
    }

    private func maybeReturnToDetectionIfUserMovedAway(_ frame: ARFrame) {
        guard hasAutoScoped, let dotLocalZ = autoScopedDotLocalZ else { return }

        // Compute camera Z in FrameOrigin coordinates.
        let cameraTransform = frame.camera.transform
        let cameraWorld = SIMD4<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z,
            1
        )
        let inv = frameOriginTransform.inverse
        let cameraLocal = inv * cameraWorld

        let dz = abs(cameraLocal.z - dotLocalZ)
        let thresholdZ = autoScopeRestartThresholdZMeters ?? Float(settings.laserGuideAutoRestartDistanceMeters)
        guard dz > thresholdZ else { return }

        let now = CACurrentMediaTime()
        let secondsSinceScope = autoScopedAtTime > 0 ? (now - autoScopedAtTime) : 0
        print("[LaserGuideSnap] Auto-return to detection: |ΔZ|=\(String(format: "%.2f", dz))m after \(String(format: "%.2f", secondsSinceScope))s (thresholdZ \(String(format: "%.2f", thresholdZ))m)")

        DispatchQueue.main.async {
            self.enterDetectionMode()
        }
    }

    private func snapFrameOriginToAlignDot(dotWorld: SIMD3<Float>, lineWorld: SIMD3<Float>, segment: LaserGuideGridSegment) {
        print("[LaserGuideSnap] snapFrameOriginToAlignDot called")
        print("[LaserGuideSnap]   dotWorld: \(dotWorld)")
        print("[LaserGuideSnap]   lineWorld: \(lineWorld)")
        print("[LaserGuideSnap]   segment: x=\(segment.x), z=\(segment.z)")

        // Place debug spheres at raycast hit positions
        placeDebugSphere(at: dotWorld, color: .red, anchorState: $debugDotAnchor)
        placeDebugSphere(at: lineWorld, color: .green, anchorState: $debugLineAnchor)

        // 1. Direction vector R = N - D (from dot to line)
        let R = lineWorld - dotWorld
        let R_xz = SIMD2<Float>(R.x, R.z)
        let r = normalize(R_xz)  // normalized direction in XZ plane
        
        print("[LaserGuideSnap]   R (dot→line): \(R)")
        print("[LaserGuideSnap]   r (normalized XZ): \(r)")

        // 2. Distance d = |S| = magnitude of segment position
        let S = SIMD2<Float>(Float(segment.x), Float(segment.z))
        let d = length(S)
        
        print("[LaserGuideSnap]   S (segment XZ): \(S)")
        print("[LaserGuideSnap]   d (|S|): \(d)")

        // 3. Origin position: O = D - r*d (origin is behind the dot, so dot is at +Z in local)
        let offset_xz = r * d
        let O = SIMD3<Float>(dotWorld.x - offset_xz.x, dotWorld.y, dotWorld.z - offset_xz.y)
        
        print("[LaserGuideSnap]   offset (r*d): \(offset_xz)")
        print("[LaserGuideSnap]   O (origin pos): \(O)")

        // 4. Rotation: Z-axis aligned with R (dot→line direction)
        let newZ = SIMD3<Float>(r.x, 0, r.y)  // direction from dot to line
        let newX = SIMD3<Float>(r.y, 0, -r.x)  // perpendicular in XZ plane
        let newY = SIMD3<Float>(0, 1, 0)  // Y is up
        
        print("[LaserGuideSnap]   rotation: X=\(newX), Y=\(newY), Z=\(newZ)")

        // 5. Build transform
        var newTransform = matrix_identity_float4x4
        newTransform.columns.0 = SIMD4<Float>(newX.x, newX.y, newX.z, 0)
        newTransform.columns.1 = SIMD4<Float>(newY.x, newY.y, newY.z, 0)
        newTransform.columns.2 = SIMD4<Float>(newZ.x, newZ.y, newZ.z, 0)
        newTransform.columns.3 = SIMD4<Float>(O.x, O.y, O.z, 1)

        // Apply
        frameOriginTransform = newTransform
        print("[LaserGuideSnap]   ✓ frameOriginTransform updated")
        
        // Verification: transform dot back to local coords and check if it matches segment
        let inverseTransform = newTransform.inverse
        let dotHomogeneous = SIMD4<Float>(dotWorld.x, dotWorld.y, dotWorld.z, 1)
        let dotLocal = inverseTransform * dotHomogeneous
        let dotLocalXZ = SIMD2<Float>(dotLocal.x, dotLocal.z)
        let segmentXZ = SIMD2<Float>(Float(segment.x), Float(segment.z))
        let error = length(dotLocalXZ - segmentXZ)
        
        print("[LaserGuideSnap]   VERIFICATION:")
        print("[LaserGuideSnap]     dotLocal: x=\(dotLocal.x), z=\(dotLocal.z)")
        print("[LaserGuideSnap]     segment:  x=\(segment.x), z=\(segment.z)")
        print("[LaserGuideSnap]     error (XZ distance): \(error)m")
        
        if frameOriginAnchor == nil {
            print("[LaserGuideSnap]   placing gizmo (was nil)")
            placeFrameOriginGizmo(at: frameOriginTransform)
        } else {
            print("[LaserGuideSnap]   recreating gizmo at new position")
            placeFrameOriginGizmo(at: frameOriginTransform)
        }
        updateMarkersForNewFrameOrigin()
        print("[LaserGuideSnap]   snap complete")
    }

    private func placeDebugSphere(at position: SIMD3<Float>, color: UIColor, anchorState: Binding<AnchorEntity?>) {
        // These spheres are only useful for debugging the snap; hide them during detection mode.
        guard let arView = arView else { return }
        
        // Remove existing debug sphere
        if let existing = anchorState.wrappedValue {
            arView.scene.removeAnchor(existing)
        }
        
        // Create new sphere at position
        let anchor = AnchorEntity(world: position)
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.03),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchorState.wrappedValue = anchor

        // Only show debug spheres once we have auto-scoped.
        anchor.isEnabled = hasAutoScoped
        
        print("[LaserGuideSnap] Debug sphere (\(color == .red ? "RED/dot" : "GREEN/line")) placed at \(position)")
    }

    private func endARSession() {
        captureSession.stop()
        isSessionActive = false
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

#Preview {
    LaserGuideARSessionView(
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