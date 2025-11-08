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
    @StateObject var captureSession: CaptureSession
    @StateObject var markerService: SpatialMarkerService
    @StateObject var workSessionService: WorkSessionService
    @StateObject var markerApi: MarkerService
    @StateObject var spaceService: SpaceService
    @StateObject var settings: AppSettings
    @StateObject var viewModel: ARSessionViewModel

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
                        markerService.loadPersistedMarkers(transformedMarkers)
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