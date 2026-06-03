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
    @State var debugLineAnchor: AnchorEntity? = nil
    @State var showDetectionSettings = false
    @State var detectionHistory: [DetectionFrameRecord] = []
    // Accumulator: ring buffer of last N frames, merged for overlay + measurement.
    @State var frameAccumulator: [[LaserMLDetection]] = []
    @State var accumulatedDetections: [LaserMLDetection] = []
    /// Consecutive frames (post-filter) that lacked both a dot AND a line.
    @State var emptyDetectionFrames: Int = 0
    // Origin placement stability delay (Normal Mode).
    /// `CACurrentMediaTime()` timestamp of when the current in-tolerance stable match began; 0 = not tracking.
    @State var originStabilityStartTime: TimeInterval = 0
    /// Progress 0…1 toward the required 1-second stability window. Drives the badge progress arc.
    @State var originStabilityProgress: Double = 0
    // ML model loading state for the current session's Space.
    @State var mlModelLoadError: String? = nil
    @State var isLoadingMLModel: Bool = false

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

    let laserGuideDistanceToleranceMeters: Float = 0.03
    let laserGuideSnapCooldownSeconds: TimeInterval = 0.6

    var locatingDistanceText: String {
        if let d = latestLaserMeasurement?.distanceMeters {
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
        // Create mlDetection service and share with DetectionPipeline so $-bindings
        // in the settings panel and the pipeline's routing both use the same instance.
        let mlDet = LaserMLDetectionService()
        _mlDetection = StateObject(wrappedValue: mlDet)
        _pipeline = StateObject(wrappedValue: DetectionPipeline(ml: mlDet))
    }

    @State var arView: ARView?
    @State var isSessionActive = false
    @State var errorMessage: String?
    @State var showScanView = false
    @State var isRegistering = false
    @State var registrationProgress: String = ""
    @State var showActionsDialog: Bool = false
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
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
            .position(position)
            .allowsHitTesting(false)
    }
}
