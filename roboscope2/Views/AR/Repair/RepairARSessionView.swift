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

    init(session: RepairSession, model: CoremlModel) {
        self.session = session
        self.model = model

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

    // MARK: - View state

    @State var arView: ARView?
    @State var isSessionActive = false
    @State var imageToViewTransform: CGAffineTransform = .identity
    @State var viewportSize: CGSize = .zero

    @State var isLoadingModel = false
    @State var modelLoadError: String? = nil
    @State var errorMessage: String? = nil

    @State var placedPinCount: Int = 0
    /// Pins confirmed locally but not yet flushed to the API. Flushed on a timer and on close.
    @State var pendingPinsBuffer: [CreatePin] = []
    @State var flushTimer: Timer? = nil
    @State var isClosing = false
    @State var showDebugOverlay = false

    @State var cancellables = Set<AnyCancellable>()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                arViewLayer(geometry: geometry)

                if showDebugOverlay {
                    RepairDetectionOverlay(
                        detections: mlDetection.detections,
                        viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                        imageToViewTransform: imageToViewTransform
                    )
                    .allowsHitTesting(false)
                }

                topBar

                if isLoadingModel || modelLoadError != nil {
                    modelStatusHUD
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
                    showDebugOverlay.toggle()
                } label: {
                    Image(systemName: showDebugOverlay ? "eye.fill" : "eye.slash.fill")
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
}
