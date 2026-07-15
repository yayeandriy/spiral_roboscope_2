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

    /// Manual session-photo captures still needing an upload to
    /// `POST /repair-sessions/{id}/photos` (already saved to local disk regardless of upload
    /// outcome — see RepairPhotoStore). Retried on the same timer as `flushPendingPins`.
    @State var pendingSessionPhotoUploads: [PendingSessionPhotoUpload] = []

    /// The model actually driving live detection right now. Starts as the session's launch
    /// model but can be swapped in-session from RepairSessionSettingsView; the server-side
    /// session record's coreml_model_id is NOT updated (no endpoint for that).
    @State var activeModel: CoremlModel
    @State var showSettingsSheet = false
    @State var isSwappingModel = false

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

    @State var cancellables = Set<AnyCancellable>()

    init(session: RepairSession, model: CoremlModel) {
        self.session = session
        self.model = model
        self._activeModel = State(initialValue: model)

        let capture = CaptureSession()
        _captureSession = StateObject(wrappedValue: capture)

        let mlDet = RepairMLDetectionService.make()
        mlDet.confidenceThreshold = RepairSettings.shared.repairConfidenceThreshold
        _mlDetection = StateObject(wrappedValue: mlDet)
        _pipeline = StateObject(wrappedValue: RepairDetectionPipeline(ml: mlDet))

        _pinRenderer = StateObject(wrappedValue: RepairPinRenderer())
        _settings = StateObject(wrappedValue: RepairSettings.shared)
        _sessionService = StateObject(wrappedValue: RepairSessionService.shared)
        _pinServiceObj = StateObject(wrappedValue: PinService.shared)

        let s = RepairSettings.shared
        self.autoPlacer = RepairAutoPlacer(
            windowSize: s.repairTemporalWindowFrames,
            confirmThreshold: s.repairConfirmThreshold,
            dedupRadiusMeters: s.repairDedupRadiusMeters,
            iouThreshold: s.repairAssocIoUThreshold
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                arViewLayer(geometry: geometry)

                if settings.repairShowDetectionOverlay {
                    RepairDetectionOverlay(
                        detections: mlDetection.detections,
                        viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                        imageToViewTransform: imageToViewTransform
                    )
                    .allowsHitTesting(false)
                }

                RepairMaturingOverlay(
                    candidates: maturingCandidates,
                    viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                    imageToViewTransform: imageToViewTransform
                )

                topBar

                if isLoadingModel || modelLoadError != nil {
                    modelStatusHUD
                }

                if isSwappingModel {
                    modelSwapHUD
                }

                if selectedPinId != nil {
                    deleteConfirmBar
                }

                if photoFlash {
                    Color.white
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea(.all)
        .navigationBarBackButtonHidden()
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .onChange(of: mlDetection.detections) { _, rawDetections in
            processDetections(rawDetections)
        }
        .onChange(of: settings.repairConfidenceThreshold) { _, newValue in
            mlDetection.confidenceThreshold = newValue
        }
        .onChange(of: settings.repairDedupRadiusMeters) { _, newValue in
            autoPlacer.dedupRadiusMeters = newValue
        }
        .onChange(of: settings.repairPinRadiusMeters) { _, newValue in
            pinRenderer.updateAllPinSizes(to: newValue)
        }
        .sheet(isPresented: $showSettingsSheet) {
            RepairSessionSettingsView(
                settings: settings,
                activeModel: activeModel,
                onSelectModel: { newModel in
                    Task { await swapActiveModel(to: newModel) }
                },
                onClearScene: {
                    Task { await clearScene() }
                }
            )
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
            Spacer()
        }
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
}
