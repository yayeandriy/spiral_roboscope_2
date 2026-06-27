//
//  LaserGuideARSessionView.swift
//  roboscope2
//
//  Dedicated LaserGuide AR experience (forked from ARSessionView).
//  Stored properties live here; body is in +Body.swift; logic in +Logic.swift / +Scoping.swift.
//

import SwiftUI
import RealityKit
import ARKit
import UIKit
import SceneKit
import Combine
import QuartzCore

// MARK: - LaserGuide AR Session View

/// Dedicated LaserGuide AR experience (forked from ARSessionView).
/// This is intentionally separate so LaserGuide workflow changes don't destabilize the default AR session flow.
struct LaserGuideARSessionView: View {
    let session: WorkSession
    @Environment(\.dismiss) var dismiss
    @StateObject var captureSession: CaptureSession
    @StateObject var markerService: SpatialMarkerService
    @StateObject var workSessionService: WorkSessionService
    @StateObject var markerApi: MarkerService
    @StateObject var spaceService: SpaceService
    @StateObject var settings: AppSettings
    @StateObject var viewModel: ARSessionViewModel
    // mlDetection is declared explicitly so all $-bindings in the settings panel work.
    // It is wired into DetectionPipeline via its DI init.
    @StateObject var mlDetection: LaserMLDetectionService
    /// Reusable detection pipeline — routes raw pixel-buffers to LaserMLDetectionService.
    /// Plug this into Video Mode by feeding CVPixelBuffers from AVPlayerItemVideoOutput.
    @StateObject var pipeline: DetectionPipeline
    /// Current AR session run index (1-based). Determined on appear by fetching the
    /// existing max run for this session and adding 1. All anchors placed in this
    /// view instance are tagged with this run so they form a coherent world-coordinate set.
    @State var currentRun: Int = 1
    @State var laserGuide: LaserGuide? = nil
    @State var laserGuideFetchError: String? = nil
    @State var lastLaserGuideSnapTime: TimeInterval = 0
    @State var latestLaserMeasurement: LaserDotLineMeasurement? = nil
    @State var hasAutoScoped: Bool = false
    @State var autoScopedDotWorld: SIMD3<Float>? = nil
    @State var autoScopedAtTime: TimeInterval = 0
    @State var autoScopedDotLocalZ: Float? = nil
    @State var autoScopeRestartThresholdZMeters: Float? = nil
    @State var autoScopedSegment: LaserGuideGridSegment? = nil
    @State var debugDotAnchor: AnchorEntity? = nil
    /// Live red cone placed at the detected dot's 3-D raycast position.
    /// Updated every frame a dot is detected; removed when placement ends.
    @State var dotConeAnchor: AnchorEntity? = nil
    @State var debugLineAnchor: AnchorEntity? = nil
    @State var showDetectionSettings = false
    @State var detectionHistory: [DetectionFrameRecord] = []
    // Accumulator: ring buffer of last N frames, merged for overlay + measurement.
    @State var frameAccumulator: [[LaserMLDetection]] = []
    @State var accumulatedDetections: [LaserMLDetection] = []
    /// Consecutive frames (post-filter) that lacked both a dot AND a line.
    @State var emptyDetectionFrames: Int = 0
    /// Two-phase lock: once a dot is raycast to 3-D, its world position is frozen here.
    /// Subsequent frames only look for the line; when found, measurement + origin placement fires.
    @State var lockedDotWorld: SIMD3<Float>? = nil
    // Origin placement stability delay (Normal Mode).
    /// `CACurrentMediaTime()` timestamp of when the current in-tolerance stable match began; 0 = not tracking.
    @State var originStabilityStartTime: TimeInterval = 0
    /// Progress 0…1 toward the required 1-second stability window. Drives the badge progress arc.
    @State var originStabilityProgress: Double = 0
    // ML model loading state for the current session's Space.
    @State var mlModelLoadError: String? = nil
    @State var isLoadingMLModel: Bool = false

    // Hold-to-place origin button state
    @State var isPlacementButtonHeld: Bool = false
    @State var savedHasAutoScoped: Bool = false
    @State var savedFrameOriginTransform: simd_float4x4 = matrix_identity_float4x4

    static func cgImageOrientation(for interfaceOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        // Back camera (not mirrored). This mapping keeps Vision's orientation consistent with
        // ARFrame.displayTransform(for: interfaceOrientation, ...).
        switch interfaceOrientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        default:
            return .right
        }
    }

    var laserGuideDistanceToleranceMeters: Float { settings.laserGuideDistanceToleranceMeters }
    let laserGuideSnapCooldownSeconds: TimeInterval = 0.6

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
        // Create mlDetection service and share with DetectionPipeline so $-bindings
        // in the settings panel and the pipeline's routing both use the same instance.
        let mlDet = LaserMLDetectionService.make()
        _mlDetection = StateObject(wrappedValue: mlDet)
        _pipeline = StateObject(wrappedValue: DetectionPipeline(ml: mlDet))
    }

    @State var arView: ARView?
    @State var isSessionActive = false
    @State var errorMessage: String?
    @State var showScanView = false
    @State var showMinimap = false
    @State var isRegistering = false
    @State var registrationProgress: String = ""
    @State var showActionsDialog: Bool = false
    @State var showSpaceInfo = false
    @State var showGridDetails = false
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

    // Reticle + measurement visuals for two-point placement
    @State var reticleAnchor: AnchorEntity? = nil
    @State var reticleTimer: Timer? = nil
    @State var firstVerticalAnchor: AnchorEntity? = nil
    @State var secondVerticalAnchor: AnchorEntity? = nil
    @State var measurementLineAnchor: AnchorEntity? = nil
    @State var measurementBadgeAnchor: AnchorEntity? = nil
    @State var measurementDistanceText: String? = nil
    @State var measurementBadgeScreenPoint: CGPoint? = nil
    @State var lastEdgeCheckTime: TimeInterval = 0
    @State var originZBadgeText: String? = nil
    @State var originZBadgeScreenPoint: CGPoint? = nil
    @State var refZBadgeText: String? = nil
    @State var refZBadgeScreenPoint: CGPoint? = nil
    @State var refTipBadgeText: String? = nil
    @State var refTipBadgeScreenPoint: CGPoint? = nil

    // Reference model state
    @State var showReferenceModel = false
    @State var referenceModelAnchor: AnchorEntity?
    @State var isLoadingModel = false
    @State var referenceModelEntity: ModelEntity?  // For RealityKit raycasting

    // Scan model state
    @State var showScanModel = false
    @State var scanModelAnchor: AnchorEntity?
    @State var isLoadingScan = false

    // Match scanning interactions
    @State var autoDropTimer: Timer?
    @State var autoDropAttempts: Int = 0
    @State var cancellables = Set<AnyCancellable>()
    @State var imageToViewTransform: CGAffineTransform = .identity
    @State var viewportSize: CGSize = .zero

    // MARK: - Computed Properties

    var associatedSpaceName: String? {
        guard let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) else {
            return "Space: \(session.spaceId.uuidString.prefix(8))..."
        }
        return space.name
    }

    var isLaserGuideSession: Bool {
        true
    }

    // MARK: - Measurement Badge Overlay

    @ViewBuilder
    func measurementBadgeLabel(text: String, position: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.75), in: Capsule())
            .position(position)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    func originZBadgeLabel(text: String, position: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.85), in: Capsule())
            .position(position)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    func refZBadgeLabel(text: String, position: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.red.opacity(0.85), in: Capsule())
            .position(position)
            .allowsHitTesting(false)
    }

    func refreshBadgePositions() {
        guard let arView, let frame = arView.session.currentFrame else { return }

        // Refresh ref Z badge (red, at dot reference cross)
        if refZBadgeText != nil, let dotAnchor = debugDotAnchor {
            let dotWorld = dotAnchor.position(relativeTo: nil)
            let badgeWorld = SIMD3<Float>(dotWorld.x, dotWorld.y + 0.15, dotWorld.z)
            if let sp = projectWorldToScreen(worldPosition: badgeWorld, frame: frame, arView: arView) {
                refZBadgeScreenPoint = sp
            }
        }

        // Refresh origin Z badge (green, at frame origin)
        if originZBadgeText != nil, let originAnchor = frameOriginAnchor {
            let originWorld = originAnchor.position(relativeTo: nil)
            let badgeWorld = SIMD3<Float>(originWorld.x, originWorld.y + 0.08, originWorld.z)
            if let sp = projectWorldToScreen(worldPosition: badgeWorld, frame: frame, arView: arView) {
                originZBadgeScreenPoint = sp
            }
        }

        // Refresh TIP badge (at Z-arrow tip of red cross)
        if refTipBadgeText != nil, let dotAnchor = debugDotAnchor {
            let anchorMatrix = dotAnchor.transformMatrix(relativeTo: nil)
            let tipLocal = SIMD4<Float>(0, 0.005, 0.25 + 0.04, 1)
            let tipWorld4 = anchorMatrix * tipLocal
            let tipWorld = SIMD3<Float>(tipWorld4.x, tipWorld4.y, tipWorld4.z)
            if let sp = projectWorldToScreen(worldPosition: tipWorld, frame: frame, arView: arView) {
                refTipBadgeScreenPoint = sp
            }
        }
    }

    // MARK: - Hold-to-place origin button

    @ViewBuilder
    var placementButton: some View {
        Button {
            // Action handled by simultaneous gesture below
        } label: {
            ZStack {
                if isPlacementButtonHeld {
                    // Held state — filled rounded square (like recording)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green)
                        .frame(width: 68, height: 68)
                    Image(systemName: "scale.3d")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundColor(.white)
                } else {
                    // Idle state — circle with outline (like record ready)
                    Circle()
                        .fill(.white)
                        .frame(width: 80, height: 80)
                    Circle()
                        .strokeBorder(Color.green, lineWidth: 4)
                        .frame(width: 72, height: 72)
                    Image(systemName: "scale.3d")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(.green)
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPlacementButtonHeld {
                        isPlacementButtonHeld = true
                        startPlacement()
                    }
                }
                .onEnded { _ in
                    isPlacementButtonHeld = false
                    stopPlacement()
                }
        )
    }

    // MARK: - Instruction info block (shown before first placement)

    @ViewBuilder
    var instructionInfoBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hold the button")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text("to start origin placement")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Space Info

    var spaceInfoModelName: String {
        mlDetection.assignedModelURL?.lastPathComponent ?? "—"
    }

    var spaceInfoModelSize: String {
        if let size = mlDetection.modelInputSize {
            return "\(Int(size.width))×\(Int(size.height))"
        }
        return "—"
    }

    var spaceInfoClasses: String {
        "dot, line"
    }

    var spaceInfoModelDate: String {
        guard let url = mlDetection.assignedModelURL else { return "—" }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let date = attrs[.modificationDate] as? Date {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .short
                return fmt.string(from: date)
            }
        } catch { }
        return "—"
    }

    var spaceInfoUpdatedAt: String {
        let space = spaceService.spaces.first(where: { $0.id == session.spaceId })
        guard let date = space?.updatedAt ?? space?.createdAt else { return "—" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    @ViewBuilder
    var spaceInfoContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Space Info")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    showSpaceInfo = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.bottom, 16)

            // Content rows
            VStack(spacing: 12) {
                infoRow(label: "Space", value: associatedSpaceName ?? "—")
                Divider().background(.white.opacity(0.15))
                infoRow(label: "ML Model", value: spaceInfoModelName)
                Divider().background(.white.opacity(0.15))
                infoRow(label: "Input Size", value: spaceInfoModelSize)
                Divider().background(.white.opacity(0.15))
                infoRow(label: "Classes", value: spaceInfoClasses)
                Divider().background(.white.opacity(0.15))
                infoRow(label: "Updated", value: spaceInfoUpdatedAt)
                Divider().background(.white.opacity(0.15))
                infoRow(label: "Model Date", value: spaceInfoModelDate)
                if let guide = laserGuide {
                    Divider().background(.white.opacity(0.15))

                    // Collapsible grid details
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showGridDetails.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Laser Grid")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Text("\(guide.grid.count) segments")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                            Image(systemName: showGridDetails ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(width: 16)
                        }
                    }
                    .buttonStyle(.plain)

                    if showGridDetails {
                        VStack(spacing: 6) {
                            // Column header
                            HStack {
                                Text("#").frame(width: 28, alignment: .leading)
                                Text("X").frame(maxWidth: .infinity, alignment: .trailing)
                                Text("Z").frame(maxWidth: .infinity, alignment: .trailing)
                                Text("Len").frame(width: 56, alignment: .trailing)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.top, 4)

                            Divider().background(.white.opacity(0.1))

                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(Array(guide.grid.enumerated()), id: \.offset) { idx, seg in
                                        HStack {
                                            Text("\(idx + 1)")
                                                .frame(width: 28, alignment: .leading)
                                                .foregroundColor(.white.opacity(0.4))
                                            Text(String(format: "%.3f", seg.x))
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                            Text(String(format: "%.3f", seg.z))
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                            Text(String(format: "%.3f", seg.segmentLength))
                                                .frame(width: 56, alignment: .trailing)
                                        }
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                    }
                                }
                            }
                            .frame(maxHeight: 160)
                        }
                        .padding(.top, 6)
                    }
                }
            }

            Spacer().frame(height: 24)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.horizontal, 24)
        .zIndex(10)
    }

    func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
        }
    }

    // MARK: - Placement lifecycle

    func startPlacement() {
        // Save current origin state so we can restore on failure
        savedHasAutoScoped = hasAutoScoped
        savedFrameOriginTransform = frameOriginTransform

        // Hide existing origin gizmo, markers, debug visuals
        frameOriginAnchor?.isEnabled = false
        debugDotAnchor?.isEnabled = false
        debugLineAnchor?.isEnabled = false
        removeDotCone()
        markerService.setMarkersVisible(false)

        // Enter detection mode (without restarting AR tracking)
        hasAutoScoped = false
        latestLaserMeasurement = nil
        frameAccumulator = []
        accumulatedDetections = []
        emptyDetectionFrames = 0
        lockedDotWorld = nil
        originStabilityStartTime = 0
        originStabilityProgress = 0
        originZBadgeText = nil
        originZBadgeScreenPoint = nil
        refZBadgeText = nil
        refZBadgeScreenPoint = nil
        refTipBadgeText = nil
        refTipBadgeScreenPoint = nil

        // Start detection pipeline
        pipeline.start()
    }

    func stopPlacement() {
        pipeline.stop()
        removeDotCone()

        if hasAutoScoped {
            // Placement succeeded during hold — keep the new origin, show everything
            frameOriginAnchor?.isEnabled = true
            debugDotAnchor?.isEnabled = true
            debugLineAnchor?.isEnabled = true
            markerService.setMarkersVisible(true)

            // Persist the anchor — use the segment's canonical z value (exact Double from the
            // laser guide table) rather than the computed dotLocalZ (Float with precision drift)
            // so that ON CONFLICT correctly deduplicates re-placements at the same level.
            if let dotWorld = autoScopedDotWorld, let segment = autoScopedSegment {
                Task {
                    try? await AnchorService.shared.placeAnchor(
                        sessionId: session.id,
                        run: currentRun,
                        localZ: segment.z,
                        position: dotWorld
                    )
                }
            }
        } else if savedHasAutoScoped {
            // Placement did not complete — restore previous origin and anchor
            frameOriginTransform = savedFrameOriginTransform
            hasAutoScoped = true
            frameOriginAnchor?.isEnabled = true
            debugDotAnchor?.isEnabled = true
            debugLineAnchor?.isEnabled = true
            markerService.setMarkersVisible(true)
        } else {
            // No previous origin and placement didn't succeed — stay idle
            // Nothing to restore; user can hold again to retry
        }
    }

    /// Determines the run index for this AR session launch.
    /// Fetches existing anchors for the session; if any exist, uses max(run) + 1,
    /// otherwise starts at run 1.
    func initCurrentRun() async {
        do {
            let existing = try await AnchorService.shared.listAnchors(sessionId: session.id)
            let maxRun = existing.map(\.run).max() ?? 0
            await MainActor.run { currentRun = maxRun + 1 }
            print("[AnchorRun] Session \(session.id) — starting run \(maxRun + 1)")
        } catch {
            print("[AnchorRun] Failed to fetch existing anchors; defaulting to run 1: \(error)")
            await MainActor.run { currentRun = 1 }
        }
    }
}
