//
//  RepairARSessionView.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Repair's AR experience. Mirrors the Laser Guide ARView wiring pattern (ARViewContainer +
//  CaptureSession composition) WITHOUT any of its scoping/anchor/frameOriginTransform logic
//  (00-rules-and-boundaries.md §0.6 — raw ARKit world used directly, no absolute frame).
//  Stored properties + init + body live here; frame/raycast/placement logic lives in
//  +Logic.swift (05-ios-repair.md §5.7).
//
//  Reuses (compose, not edit) `Views/Common/ARViewContainer.swift` and
//  `Services/AR/CaptureSession.swift` as-is per the §5.2 copy map ("Reuse as-is" row) —
//  those are generic ARView/session setup with no Laser Guide coupling.
//

import SwiftUI
import RealityKit
import ARKit
import Combine

struct RepairARSessionView: View {
    let session: RepairSession
    let model: CoremlModel

    @Environment(\.dismiss) var dismiss

    @StateObject var captureSession: CaptureSession
    @StateObject var mlDetection: RepairMLDetectionService
    @StateObject var pipeline: RepairDetectionPipeline
    @StateObject var pinRenderer: RepairPinRenderer
    @StateObject var settings: RepairSettings
    @StateObject var sessionService: RepairSessionService
    @StateObject var pinServiceObj: PinService

    /// The core placement algorithm. Not @StateObject (it's a plain class, not observed by
    /// SwiftUI directly) — its output drives @State mutations below instead.
    let autoPlacer: RepairAutoPlacer

    // MARK: - View state

    @State var arView: ARView?
    @State var isSessionActive = false
    @State var imageToViewTransform: CGAffineTransform = .identity
    @State var viewportSize: CGSize = .zero

    @State var isLoadingModel = false
    @State var modelLoadError: String? = nil
    @State var errorMessage: String? = nil

    @State var placedPinCount: Int = 0
    /// Pins confirmed locally but not yet flushed to the API, paired with the client-local id
    /// (RepairPlacedPin.id) used by pinRenderer/autoPlacer, so the server-assigned id can be
    /// correlated back to it once the flush succeeds (see `serverIdByLocalId`).
    @State var pendingPinsBuffer: [(localId: UUID, pin: CreatePin)] = []
    /// Server-assigned Pin.id for each locally-tracked pin, populated once its bulk-create flush
    /// succeeds. Required for delete: `DELETE /pins/{id}` needs the server's id, which is NOT
    /// the same as the client-generated id used for on-screen tracking (the create endpoint
    /// does not accept/echo a client-supplied id).
    @State var serverIdByLocalId: [UUID: UUID] = [:]
    @State var flushTimer: Timer? = nil
    @State var isClosing = false

    /// Pins whose server id is known but whose locally-cached snapshot (RepairPhotoStore)
    /// hasn't been uploaded to `POST /pins/{id}/photo` yet, keyed by server id -> local id
    /// (the snapshot file on disk is keyed by local id, not server id). Retried on the same
    /// timer as `flushPendingPins`.
    @State var pinsAwaitingPhotoUpload: [UUID: UUID] = [:]
    @State var pinPhotoUploadAttempts: [UUID: Int] = [:]
    /// Reentrancy guard for `flushPendingPinPhotoUploads` — it's invoked both immediately and
    /// from the periodic timer, and without this a second call could race the first while it's
    /// suspended on a network `await`, uploading the same photo twice.
    @State var isFlushingPinPhotos = false

    /// Manual session-photo captures still needing an upload to
    /// `POST /repair-sessions/{id}/photos` (already saved to local disk regardless of upload
    /// outcome — see RepairPhotoStore). Retried on the same timer as `flushPendingPins`.
    @State var pendingSessionPhotoUploads: [PendingSessionPhotoUpload] = []
    /// Reentrancy guard for `flushPendingSessionPhotoUploads` — see `isFlushingPinPhotos`.
    @State var isFlushingSessionPhotos = false

    /// The model actually driving live detection right now. Starts as the session's launch
    /// model but can be swapped in-session from RepairSessionSettingsView; the server-side
    /// session record's coreml_model_id is NOT updated (no endpoint for that).
    @State var activeModel: CoremlModel
    @State var showSettingsSheet = false
    @State var isSwappingModel = false

    /// v0.4 — Planning/Validation sub-mode split. Always starts in Planning; Validation is a
    /// live in-session switch (see the topBar mode control), never a launch-time choice.
    @State var sessionMode: RepairSessionMode = .planning
    /// The Validation-mode detector model, resolved lazily the first time the operator switches
    /// into Validation (see `resolveValidationModel()`) — nil until then. Independent of
    /// `activeModel`, which is Planning's model.
    @State var validationModel: CoremlModel? = nil

    /// Manual "take picture" capture (session-level, not tied to a specific pin).
    @State var isCapturingPhoto = false
    /// Brief white flash shown over the AR view as capture feedback.
    @State var photoFlash = false

    /// Candidates currently accumulating hits toward confirmation (not yet a pin) — drives the
    /// always-visible "maturing" progress ring, independent of the debug overlay toggle.
    @State var maturingCandidates: [(id: UUID, bbox: CGRect, progress: Float)] = []

    /// Tap-to-select-then-delete: selecting a pin highlights it and shows a confirm bar instead
    /// of deleting immediately.
    @State var selectedPinId: UUID? = nil

    /// "Clear All Pins" now lives on the main viewport as a recycle-bin button (moved out of the
    /// settings sheet — it's used often enough to want a single tap + one confirmation, not a
    /// trip through Settings). Planning-only, same as the pins it clears.
    @State var showClearConfirm = false

    /// Every distinct `detectionClass` confirmed as a pin so far this session (e.g. "l1", "r2"
    /// for the corners2 model) — used only to drive `hasLeftAndRightMarkers` below. Deliberately
    /// never removed on delete/re-placement: once a left+right reference pair has been seen for
    /// this session, the defect badge stays put rather than flickering in/out as individual pins
    /// are tidied up. Reset on `clearScene()`.
    @State var placedClasses: Set<String> = []
    /// Placeholder "defect record" panel (see RepairDefectPanelView) — surfaced once a full
    /// left+right reference frame has been detected, since that's presumably the moment a
    /// known defect location becomes identifiable in this session.
    @State var showDefectPanel = false

    /// Full pin data (position + class + bounding box) for every pin currently placed this
    /// session, kept in sync as pins are added/deleted/cleared — unlike `placedClasses`, this
    /// DOES shrink on delete, since the minimap should reflect what's actually still there.
    /// Feeds RepairMiniMapView (map button in the top bar).
    @State var allPins: [RepairMiniMapPin] = []
    @State var showMiniMap = false

    @State var cancellables = Set<AnyCancellable>()

    init(session: RepairSession, model: CoremlModel) {
        self.session = session
        self.model = model
        self._activeModel = State(initialValue: model)

        let capture = CaptureSession()
        _captureSession = StateObject(wrappedValue: capture)

        let mlDet = RepairMLDetectionService.make()
        mlDet.confidenceThreshold = RepairSettings.shared.repairPlanningConfidenceThreshold
        _mlDetection = StateObject(wrappedValue: mlDet)
        _pipeline = StateObject(wrappedValue: RepairDetectionPipeline(ml: mlDet))

        _pinRenderer = StateObject(wrappedValue: RepairPinRenderer())
        _settings = StateObject(wrappedValue: RepairSettings.shared)
        _sessionService = StateObject(wrappedValue: RepairSessionService.shared)
        _pinServiceObj = StateObject(wrappedValue: PinService.shared)

        let s = RepairSettings.shared
        let initialAccumulator = Self.resolvedAccumulatorParams(useAccumulator: s.repairUseAccumulator, windowFrames: s.repairTemporalWindowFrames, confirmThreshold: s.repairConfirmThreshold)
        self.autoPlacer = RepairAutoPlacer(
            windowSize: initialAccumulator.window,
            confirmThreshold: initialAccumulator.confirm,
            dedupRadiusMeters: s.repairDedupRadiusMeters,
            iouThreshold: s.repairAssocIoUThreshold
        )
    }

    /// Maps the accumulator toggle + its two sliders down to the actual RepairAutoPlacer
    /// parameters: OFF collapses to window=1/confirm=1 (a pin drops on the very first
    /// detection), independent of whatever window/threshold the operator last dialed in — so
    /// flipping the toggle back ON restores their prior tuning rather than resetting it.
    static func resolvedAccumulatorParams(useAccumulator: Bool, windowFrames: Int, confirmThreshold: Int) -> (window: Int, confirm: Int) {
        guard useAccumulator else { return (1, 1) }
        let window = max(1, windowFrames)
        let confirm = max(1, min(confirmThreshold, window))
        return (window, confirm)
    }

    /// True once at least one "left" and one "right" reference-marker class have both been
    /// confirmed as pins this session. Heuristic tied to the corners2 model's naming convention
    /// (classes "l1"/"l2" = left, "r1"/"r2" = right) — a class simply starting with "l"/"r"
    /// (case-insensitive). Good enough for a placeholder signal; would need to move to an
    /// explicit per-class "side" attribute (mirroring RepairClassStyle.corner) if this needs to
    /// generalize beyond corners-style models.
    var hasLeftAndRightMarkers: Bool {
        let hasLeft = placedClasses.contains { $0.lowercased().hasPrefix("l") }
        let hasRight = placedClasses.contains { $0.lowercased().hasPrefix("r") }
        return hasLeft && hasRight
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                arViewLayer(geometry: geometry)

                if sessionMode == .validation {
                    // Validation is passive-only: always show the live box+class+confidence
                    // overlay (that's the entire point of this mode), independent of the
                    // Planning debug-overlay toggle in settings.
                    RepairDetectionOverlay(
                        detections: mlDetection.detections,
                        viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                        imageToViewTransform: imageToViewTransform,
                        classStyles: validationModel?.classStyles,
                        showMaskPolygon: true,
                        autoColorByClass: true
                    )
                    .allowsHitTesting(false)
                } else if settings.repairShowDetectionOverlay {
                    RepairDetectionOverlay(
                        detections: mlDetection.detections,
                        viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                        imageToViewTransform: imageToViewTransform,
                        classStyles: activeModel.classStyles
                    )
                    .allowsHitTesting(false)
                }

                if sessionMode == .planning {
                    RepairMaturingOverlay(
                        candidates: maturingCandidates,
                        viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                        imageToViewTransform: imageToViewTransform
                    )
                }

                topBar

                if isLoadingModel || modelLoadError != nil {
                    modelStatusHUD
                }

                if isSwappingModel {
                    modelSwapHUD
                }

                if selectedPinId != nil {
                    deleteConfirmBar
                } else if sessionMode == .planning && hasLeftAndRightMarkers {
                    defectBadge
                }

                if photoFlash {
                    Color.white
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: hasLeftAndRightMarkers)
        }
        .ignoresSafeArea(.all)
        .navigationBarBackButtonHidden()
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .alert("Clear this space?", isPresented: $showClearConfirm) {
            Button("Clear All Pins", role: .destructive) {
                Task { await clearScene() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes every pin in this session, on this device and on the server. This action cannot be undone.")
        }
        .onChange(of: mlDetection.detections) { _, rawDetections in
            // Validation mode is passive — it reads mlDetection.detections directly for its
            // overlay above, and never runs the auto-placer (no pins in Validation).
            if sessionMode == .planning {
                processDetections(rawDetections)
            }
        }
        .onChange(of: settings.repairPlanningConfidenceThreshold) { _, newValue in
            if sessionMode == .planning { mlDetection.confidenceThreshold = newValue }
        }
        .onChange(of: settings.repairValidationConfidenceThreshold) { _, newValue in
            if sessionMode == .validation { mlDetection.confidenceThreshold = newValue }
        }
        .onChange(of: settings.repairDedupRadiusMeters) { _, newValue in
            autoPlacer.dedupRadiusMeters = newValue
        }
        .onChange(of: settings.repairUseAccumulator) { _, _ in applyAccumulatorSettings() }
        .onChange(of: settings.repairTemporalWindowFrames) { _, _ in applyAccumulatorSettings() }
        .onChange(of: settings.repairConfirmThreshold) { _, _ in applyAccumulatorSettings() }
        .onChange(of: settings.repairPinRadiusMeters) { _, newValue in
            pinRenderer.updateAllPinSizes(to: newValue)
        }
        .sheet(isPresented: $showSettingsSheet) {
            RepairSessionSettingsView(
                settings: settings,
                sessionMode: sessionMode,
                currentModel: sessionMode == .planning ? activeModel : validationModel,
                onSelectModel: { newModel in
                    Task {
                        if sessionMode == .planning {
                            await swapActiveModel(to: newModel)
                        } else {
                            await swapValidationModel(to: newModel)
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showDefectPanel) {
            RepairDefectPanelView()
        }
        .sheet(isPresented: $showMiniMap) {
            RepairMiniMapView(pins: allPins, classStyles: activeModel.classStyles)
        }
    }

    @ViewBuilder
    private func arViewLayer(geometry: GeometryProxy) -> some View {
        ARViewContainer(session: captureSession.session, arView: $arView)
            .onAppear {
                startARSession()
                Task { await loadModelForSession() }
                startFlushTimer()
                self.viewportSize = geometry.size
            }
            .onDisappear {
                pipeline.stop()
                stopFlushTimer()
                cancellables.removeAll()
                endARSession()
            }
            .onChange(of: arView) { _, newValue in
                if let newValue {
                    pinRenderer.attach(to: newValue)
                    newValue.scene.subscribe(to: SceneEvents.Update.self) { _ in
                        self.processFrameUpdate()
                    }.store(in: &cancellables)
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    handleTap(at: value.location)
                }
            )
    }

    @ViewBuilder
    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    Task { await closeAndDismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .disabled(isClosing)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.white)
                    Text("\(placedPinCount)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.35)))

                Spacer()

                if sessionMode == .planning {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(allPins.isEmpty ? .white.opacity(0.4) : .white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    .disabled(allPins.isEmpty)

                    Button {
                        showMiniMap = true
                    } label: {
                        Image(systemName: "map.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(allPins.isEmpty ? .white.opacity(0.4) : .white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    .disabled(allPins.isEmpty)
                }

                Button {
                    Task { await captureSessionPhoto() }
                } label: {
                    Group {
                        if isCapturingPhoto {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.35)))
                }
                .disabled(isCapturingPhoto)

                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)

            modeSwitcher
                .padding(.top, 10)

            Spacer()
        }
    }

    /// Planning <-> Validation switch (v0.4). Lives in the viewport, right below the icon row,
    /// so it's reachable alongside settings/snapshot without a trip out of AR.
    @ViewBuilder
    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(RepairSessionMode.allCases, id: \.self) { mode in
                Button {
                    guard !isSwappingModel else { return }
                    Task { await switchMode(to: mode) }
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(sessionMode == mode ? .black : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(sessionMode == mode ? Color.orange : Color.clear)
                        )
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(.black.opacity(0.35)))
        .disabled(isSwappingModel)
    }

    @ViewBuilder
    private var modelStatusHUD: some View {
        VStack(spacing: 12) {
            if isLoadingModel {
                ProgressView().progressViewStyle(.circular).tint(.white)
                Text("Loading detector model…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            } else if let err = modelLoadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.yellow)
                Text(err)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var modelSwapHUD: some View {
        VStack(spacing: 12) {
            ProgressView().progressViewStyle(.circular).tint(.white)
            Text("Switching detector model…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var deleteConfirmBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text("Delete this pin?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Button("Cancel") {
                    deselectPin()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

                Button("Delete") {
                    confirmDeleteSelectedPin()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
    }

    /// Beige "Defect" badge — appears at the bottom of the viewport once
    /// `hasLeftAndRightMarkers` goes true, and opens the placeholder `RepairDefectPanelView`.
    @ViewBuilder
    private var defectBadge: some View {
        VStack {
            Spacer()
            Button {
                showDefectPanel = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(red: 0.55, green: 0.38, blue: 0.12))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Defect")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black.opacity(0.85))
                        Text("QCRID 032QN028705")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.black.opacity(0.6))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(red: 0.93, green: 0.85, blue: 0.68))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
