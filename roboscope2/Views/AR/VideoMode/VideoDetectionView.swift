//
//  VideoDetectionView.swift
//  roboscope2
//
//  LaserGuide detection run against stored video footage.
//  Reuses the same ML pipeline and auto-scope algorithm as the live AR session,
//  but shows a video player instead of the AR camera feed.
//  When detection criteria are satisfied, shows "Origin Would Be Placed" banner.
//

import SwiftUI
import ARKit   // for LaserMLDetectionOverlay types

struct VideoDetectionView: View {

    let session: WorkSession

    @Environment(\.dismiss) private var dismiss

    @StateObject private var videoService = VideoModeService.shared
    @StateObject var settings = AppSettings.shared

    // Detection pipeline (fresh per instance)
    @StateObject private var mlDetection = LaserMLDetectionService()
    @StateObject var pipeline: DetectionPipeline

    // Scope state (mirrors LaserGuideARSessionView)
    @State var hasFoundOrigin = false
    @State var foundSegment: LaserGuideGridSegment? = nil
    @State var latestMeasurement: LaserDotLineMeasurement? = nil
    @State var autoScopeCandidateKey: String? = nil
    @State var autoScopeSamples: [(t: TimeInterval, d: Float)] = []
    @State var autoScopeLastSeenTime: TimeInterval = 0

    // Laser guide (same data as AR mode)
    @State var laserGuide: LaserGuide? = nil
    @State private var laserGuideFetchError: String? = nil

    // Display
    @State private var viewportSize: CGSize = .zero
    @State private var showDetectionSettings = false
    @State private var isPlaying = true

    init(session: WorkSession) {
        self.session = session
        let det = LaserMLDetectionService()
        _mlDetection = StateObject(wrappedValue: det)
        _pipeline = StateObject(wrappedValue: DetectionPipeline(ml: det))
    }

    /// Transform from raw-buffer-normalized coords (output by the decode pipeline)
    /// to view-normalized coords, based on the video track's physical orientation.
    private var videoImageToViewTransform: CGAffineTransform {
        switch videoService.imageOrientation {
        case .right:
            // Portrait video (landscape buffer, 90° CW display rotation).
            // (x,y) → (1−y, x)
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        case .left:
            // Portrait upside-down (landscape buffer, 90° CCW display rotation).
            // (x,y) → (y, 1−x)
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        case .down:
            // Landscape flipped 180°.
            // (x,y) → (1−x, 1−y)
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        default:
            return .identity
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {

                // —— Video layer ——
                if videoService.player != nil {
                    VideoPlayerView(player: videoService.player)
                        .ignoresSafeArea()
                } else {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.5))
                        Text("No video loaded")
                            .foregroundColor(.white.opacity(0.7))
                        Text("Upload a video in Settings → Video Mode")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                // —— ML Detection boxes ——
                LaserMLDetectionOverlay(
                    detections: mlDetection.detections,
                    viewSize: viewportSize.width > 0 ? viewportSize : geometry.size,
                    imageToViewTransform: videoImageToViewTransform,
                    arView: nil,
                    maxDotLineYDeltaMeters: mlDetection.maxDotLineYDeltaMeters,
                    onDotLineMeasurement: { measurement in
                        latestMeasurement = measurement
                        maybeScope(measurement)
                    },
                    videoModeDistanceScale: settings.videoModeDistanceScale
                )
                .zIndex(2)
                .onAppear { viewportSize = geometry.size }
                .onChange(of: geometry.size) { _, v in viewportSize = v }

                // —— Top bar ——
                VStack {
                    HStack(alignment: .top) {
                        // Detection settings panel (top-left)
                        DetectionSettingsPanel(
                            mlDetection: mlDetection,
                            settings: settings,
                            isExpanded: $showDetectionSettings
                        )
                        .padding(.leading, 16)
                        .padding(.top, 56)

                        Spacer()

                        // Done button (top-right)
                        Button("Done") { dismiss() }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .lgCapsule(tint: .white)
                            .padding(.trailing, 16)
                            .padding(.top, 56)
                    }

                    Spacer()
                }
                .zIndex(4)

                // —— Bottom status ——
                VStack {
                    Spacer()

                    if hasFoundOrigin, let seg = foundSegment {
                        originFoundBanner(segment: seg)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 50)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if videoService.player != nil {
                        locatingBadge
                            .padding(.bottom, 50)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: hasFoundOrigin)
                .zIndex(3)

                // —— Video controls (bottom-right, if video loaded) ——
                if videoService.player != nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                if isPlaying { videoService.pause() } else { videoService.play() }
                                isPlaying.toggle()
                            } label: {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .lgCircle(tint: .white)
                            .padding(.trailing, 16)
                            .padding(.bottom, 50)
                        }
                    }
                    .zIndex(3)
                }
            }
        }
        .ignoresSafeArea(.all)
        .navigationBarBackButtonHidden()
        .onAppear {
            setupVideoMode()
            Task { await fetchLaserGuide() }
        }
        .onDisappear {
            teardownVideoMode()
        }
    }

    // MARK: - Setup / teardown

    private func setupVideoMode() {
        videoService.setupPlayer()
        videoService.play()
        isPlaying = true

        if let mlSaved = SpaceMLDetectionSettingsStore.shared.load(spaceId: session.spaceId) {
            mlDetection.confidenceThreshold = mlSaved.confidenceThreshold
            mlDetection.useROI = mlSaved.useROI
            mlDetection.roiSize = mlSaved.roiSize
            mlDetection.maxDetections = mlSaved.maxDetections
        }

        pipeline.start()

        let p = pipeline
        let orientation = videoService.imageOrientation
        videoService.startFramePump(fps: 15) { pixelBuffer in
            p.processPixelBuffer(pixelBuffer, orientation: orientation)
        }
    }

    private func teardownVideoMode() {
        videoService.stopFramePump()
        videoService.pause()
        pipeline.stop()
    }

    @MainActor
    private func fetchLaserGuide() async {
        guard laserGuide == nil else { return }
        do {
            laserGuideFetchError = nil
            laserGuide = try await LaserGuideService.shared.fetchLaserGuide(spaceId: session.spaceId)
        } catch {
            laserGuideFetchError = error.localizedDescription
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func originFoundBanner(segment: LaserGuideGridSegment) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.green)
                Text("Origin Would Be Placed Here")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            HStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text("Segment")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                    Text("x: \(String(format: "%.2f", segment.x))  z: \(String(format: "%.2f", segment.z))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                if let dist = latestMeasurement?.distanceMeters {
                    VStack(spacing: 2) {
                        Text("Distance")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                        Text(String(format: "%.2f m", dist))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
            }
            Button("Reset Detection") { resetDetection() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .lgCapsule(tint: .white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.green.opacity(0.6), lineWidth: 1.5)
                )
        )
    }

    private var locatingBadge: some View {
        VStack(spacing: 4) {
            Text("Locating...")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            if let dist = latestMeasurement?.distanceMeters {
                Text(String(format: "%.2f m (scaled)", dist))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.yellow)
            } else {
                Text("Point laser at a guide segment")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}
