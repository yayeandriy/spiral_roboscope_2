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
    @StateObject private var spaceService = SpaceService.shared

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
    @State private var showHistoryPanel = false
    @State var detectionHistory: [DetectionFrameRecord] = []

    // Accumulator: ring buffer of last N frames of raw detections, merged for measurement.
    @State var frameAccumulator: [[LaserMLDetection]] = []
    @State var accumulatedDetections: [LaserMLDetection] = []

    // ML model loading state
    @State private var modelLoadError: String? = nil
    @State private var isLoadingModel: Bool = false

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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                } else {
                    Color.black
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
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
                    detections: filterLineOverDot(settings.showAccumulatedOverlay ? accumulatedDetections : mlDetection.detections),
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

                        // History toggle button
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showHistoryPanel.toggle()
                            }
                        } label: {
                            Image(systemName: showHistoryPanel ? "clock.fill" : "clock")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .lgCircle(tint: showHistoryPanel ? .green : .white)
                        .padding(.trailing, 8)
                        .padding(.top, 56)

                        // Done button (top-right)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .lgCircle(tint: .white)
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

                // —— History panel ——
                if showHistoryPanel {
                    VStack {
                        Spacer().frame(height: 120)
                        VideoDetectionHistoryPanel(
                            records: detectionHistory,
                            onClose: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    showHistoryPanel = false
                                }
                            }
                        )
                        .padding(.horizontal, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        Spacer()
                    }
                    .zIndex(5)
                }

                // ML model loading / error HUD
                if isLoadingModel || modelLoadError != nil {
                    VStack(spacing: 12) {
                        if isLoadingModel {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                            Text("Loading ML model…")
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
                    .zIndex(6)
                }
            }
        }
        .ignoresSafeArea(.all)
        .navigationBarBackButtonHidden()
        .onChange(of: mlDetection.detections) { _, newDetections in
            // Apply "line over dot" filter before any calculations.
            let newDetections = filterLineOverDot(newDetections)

            // --- Accumulator update (always, to age out stale frames) ---
            let maxFrames = max(1, settings.videoModeAccumulatorFrames)
            var acc = frameAccumulator
            acc.append(newDetections)
            if acc.count > maxFrames { acc.removeFirst(acc.count - maxFrames) }
            frameAccumulator = acc
            let merged = laserDetectionMergeFrames(acc)
            accumulatedDetections = merged

            // --- History record (only when this frame has detections) ---
            guard !newDetections.isEmpty else { return }
            let dotDetections  = newDetections.filter { $0.label == "dot"  || $0.classIndex == 0 }
            let lineDetections = newDetections.filter { $0.label == "line" || $0.classIndex == 1 }
            let bestDot  = dotDetections.max(by:  { $0.confidence < $1.confidence })
            let bestLine = lineDetections.max(by: { $0.confidence < $1.confidence })
            // Capture these so the closures below don't implicitly capture self.
            let t = videoImageToViewTransform
            let vp = viewportSize.width > 0 ? viewportSize : CGSize(width: 390, height: 844)
            let lineToDotRatio: Float? = {
                guard let d = bestDot, let l = bestLine else { return nil }
                let dotLong  = laserDetectionLongestSidePixels(d.boundingBox, transform: t, viewport: vp)
                let lineLong = laserDetectionLongestSidePixels(l.boundingBox, transform: t, viewport: vp)
                guard dotLong > 0 else { return nil }
                return lineLong / dotLong
            }()
            let mergedDots  = merged.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }.count
            let mergedLines = merged.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }.count
            let accumulatedRatio: Float? = {
                // Use the union-merged LINE box (full accumulated extent across frames) as numerator.
                // For the dot denominator, prefer the current frame's dot (avoids jitter inflation).
                // Fall back to the merged dot when the current frame has none — the whole point of
                // accumulation is to bridge frames where one class is temporarily missing.
                let mLine = merged.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") }
                    .max(by: { $0.confidence < $1.confidence })
                let mDot  = merged.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
                    .max(by: { $0.confidence < $1.confidence })
                let dot = bestDot ?? mDot
                guard let d = dot, let l = mLine else { return nil }
                let dotLong  = laserDetectionLongestSidePixels(d.boundingBox, transform: t, viewport: vp)
                let lineLong = laserDetectionLongestSidePixels(l.boundingBox, transform: t, viewport: vp)
                guard dotLong > 0 else { return nil }
                return lineLong / dotLong
            }()
            let record = DetectionFrameRecord(
                timestamp: Date(),
                dots: dotDetections.count,
                lines: lineDetections.count,
                otherCount: newDetections.filter { ($0.classIndex ?? -1) > 1 }.count,
                distanceMeters: latestMeasurement?.distanceMeters,
                lineToDotSizeRatio: lineToDotRatio,
                accumulatedDots: mergedDots,
                accumulatedLines: mergedLines,
                accumulatorFramesUsed: acc.filter { !$0.isEmpty }.count,
                accumulatedLineToDotRatio: accumulatedRatio
            )
            detectionHistory.append(record)
            if detectionHistory.count > 50 { detectionHistory.removeFirst(detectionHistory.count - 50) }
        }
        .onAppear {
            setupVideoMode()
            Task { await fetchLaserGuide() }
            Task { await loadModelForSession() }
        }
        .onDisappear {
            teardownVideoMode()
        }
    }

    // MARK: - Setup / teardown

    @MainActor
    private func loadModelForSession() async {
        guard let space = spaceService.spaces.first(where: { $0.id == session.spaceId }) else {
            modelLoadError = "Space not found for this session."
            return
        }
        isLoadingModel = true
        modelLoadError = nil
        do {
            let url = try await MLModelDownloadService.shared.ensureModelForSpace(space)
            mlDetection.setModelURL(url)
        } catch {
            modelLoadError = error.localizedDescription
        }
        isLoadingModel = false
    }

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

    // MARK: - Detection helpers (accumulator / filter)

    /// Removes line detections that overlap any dot detection when `lineOverDotFilter` is enabled.
    private func filterLineOverDot(_ detections: [LaserMLDetection]) -> [LaserMLDetection] {
        guard settings.lineOverDotFilter else { return detections }
        let dots = detections.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") }
        guard !dots.isEmpty else { return detections }
        return detections.filter { det in
            let isLine = det.classIndex == 1 || det.label.lowercased().contains("line")
            guard isLine else { return true }
            return !dots.contains { dot in det.boundingBox.intersects(dot.boundingBox) }
        }
    }

    /// Merges detections from multiple frames into a unified set.
    /// Boxes of the same class that overlap (CGRect.intersects) are union-merged into one box,
    /// taking the highest-confidence detection's metadata.
    static func mergeDetections(from frames: [[LaserMLDetection]]) -> [LaserMLDetection] {
        let all = frames.flatMap { $0 }
        guard !all.isEmpty else { return [] }
        let dots   = unionMerge(all.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") })
        let lines  = unionMerge(all.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") })
        let others = unionMerge(all.filter {
            guard let idx = $0.classIndex else { return false }
            return idx > 1
        })
        return dots + lines + others
    }

    private static func unionMerge(_ detections: [LaserMLDetection]) -> [LaserMLDetection] {
        guard !detections.isEmpty else { return [] }

        // Phase 1 — greedy seed clustering on direct bbox intersection.
        var clusters: [[LaserMLDetection]] = []
        for det in detections {
            if let (idx, _) = clusters.enumerated().first(where: { (_, cluster) in
                cluster.contains(where: { $0.boundingBox.intersects(det.boundingBox) })
            }) {
                clusters[idx].append(det)
            } else {
                clusters.append([det])
            }
        }

        // Phase 2 — transitive closure: merge clusters whose union boxes are within
        // 10 % of the longer box’s longest side of each other (handles gapped segments).
        var changed = true
        while changed {
            changed = false
            var merged: [[LaserMLDetection]] = []
            var used = [Bool](repeating: false, count: clusters.count)
            for i in clusters.indices {
                guard !used[i] else { continue }
                var group = clusters[i]
                var box = group.reduce(group[0].boundingBox) { $0.union($1.boundingBox) }
                for j in (i + 1)..<clusters.count {
                    guard !used[j] else { continue }
                    let other = clusters[j].reduce(clusters[j][0].boundingBox) {
                        $0.union($1.boundingBox)
                    }
                    // Gap tolerance = 10 % of the longer box’s longest side.
                    let longestSide = max(
                        max(box.width, box.height),
                        max(other.width, other.height)
                    )
                    let tol = longestSide * 0.10
                    let expanded = box.insetBy(dx: -tol, dy: -tol)
                    if expanded.intersects(other) {
                        group += clusters[j]
                        box = box.union(other)
                        used[j] = true
                        changed = true
                    }
                }
                merged.append(group)
                used[i] = true
            }
            clusters = merged
        }

        return clusters.compactMap { cluster -> LaserMLDetection? in
            guard let best = cluster.max(by: { $0.confidence < $1.confidence }) else { return nil }
            let unionBox = cluster.dropFirst().reduce(cluster[0].boundingBox) { $0.union($1.boundingBox) }
            return LaserMLDetection(
                boundingBox: unionBox,
                orientedQuad: nil,
                classIndex: best.classIndex,
                label: best.label,
                confidence: best.confidence,
                timestamp: best.timestamp
            )
        }
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
