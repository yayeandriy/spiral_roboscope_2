//
//  VideoModeService.swift
//  roboscope2
//
//  Manages a stored video file and provides an AVPlayer + frame-pump for Video Mode.
//  Frame extraction feeds CVPixelBuffers into DetectionPipeline.processPixelBuffer,
//  reusing the same ML pipeline as the live AR camera path.
//

import Foundation
import AVFoundation
import ImageIO
import Combine
import QuartzCore

final class VideoModeService: ObservableObject {

    static let shared = VideoModeService()

    // MARK: - Published state

    /// URL of the persisted video file on device (nil when no video saved).
    @Published var savedVideoURL: URL? = nil

    /// The orientation that should be passed to Vision / processPixelBuffer for this video.
    /// Derived from the first video track's preferredTransform when the player is set up.
    private(set) var imageOrientation: CGImagePropertyOrientation = .up

    // MARK: - Player (read-only by consumers)

    private(set) var player: AVPlayer? = nil

    // MARK: - Private

    private let storageDir: URL
    private var playerItem: AVPlayerItem? = nil
    private var videoOutput: AVPlayerItemVideoOutput? = nil
    private var frameTimerSource: DispatchSourceTimer? = nil
    private var loopObserver: Any? = nil

    // MARK: - Init

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        storageDir = docs.appendingPathComponent("VideoMode", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        refreshSavedVideoURL()
    }

    // MARK: - File management

    func refreshSavedVideoURL() {
        let extensions = ["mp4", "mov", "m4v"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        savedVideoURL = files.first(where: { extensions.contains($0.pathExtension.lowercased()) })
    }

    /// Copies a video from a (possibly security-scoped) URL to the app's VideoMode storage folder.
    func saveVideo(from sourceURL: URL) throws {
        let fm = FileManager.default

        // Clean up existing
        if let existing = savedVideoURL {
            try? fm.removeItem(at: existing)
        }

        let dest = storageDir.appendingPathComponent(sourceURL.lastPathComponent)
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
        try fm.copyItem(at: sourceURL, to: dest)

        DispatchQueue.main.async { self.savedVideoURL = dest }
    }

    func deleteVideo() {
        if let url = savedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        savedVideoURL = nil
        teardownPlayer()
    }

    // MARK: - Player lifecycle

    /// Creates an AVPlayer for the saved video with pixel-buffer output attached.
    /// Must be called before `startFramePump`. Safe to call multiple times (tears down and recreates).
    func setupPlayer() {
        guard let url = savedVideoURL else { return }
        teardownPlayer()

        let outputSettings: [String: Any] = [
            (kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        let item = AVPlayerItem(url: url)
        item.add(output)

        playerItem = item
        videoOutput = output
        player = AVPlayer(playerItem: item)
        player?.actionAtItemEnd = .none   // handle looping manually

        // Derive the correct Vision orientation from the video track's preferredTransform so
        // that pixel buffers (stored in raw/landscape layout by AVFoundation) are correctly
        // described to VNImageRequestHandler and coordinate mapping works properly.
        imageOrientation = Self.orientationFromAsset(AVAsset(url: url))

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero) { _ in
                self?.player?.play()
            }
        }
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func teardownPlayer() {
        stopFramePump()
        player?.pause()
        if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
        loopObserver = nil
        player = nil
        playerItem = nil
        videoOutput = nil
        imageOrientation = .up
    }

    // MARK: - Frame pump

    /// Starts a background timer that extracts pixel buffers from the current video frame
    /// and calls `onFrame` on a background queue.
    /// Caller is responsible for feeding buffers into `DetectionPipeline.processPixelBuffer`.
    func startFramePump(fps: Double = 15, onFrame: @escaping (CVPixelBuffer) -> Void) {
        stopFramePump()
        let interval = 1.0 / fps
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let buffer = self.currentPixelBuffer() {
                let retained = Unmanaged.passRetained(buffer).toOpaque()
                let released = Unmanaged<CVPixelBuffer>.fromOpaque(retained).takeRetainedValue()
                onFrame(released)
            }
        }
        timer.resume()
        frameTimerSource = timer
    }

    func stopFramePump() {
        frameTimerSource?.cancel()
        frameTimerSource = nil
    }

    /// Derives a CGImagePropertyOrientation from the first video track's preferredTransform.
    /// AVFoundation stores pixel buffers in the sensor's raw (typically landscape) orientation;
    /// preferredTransform describes the rotation needed to display them correctly.
    /// We invert that to tell Vision how the buffer is physically oriented.
    private static func orientationFromAsset(_ asset: AVAsset) -> CGImagePropertyOrientation {
        guard let track = asset.tracks(withMediaType: .video).first else { return .up }
        let t = track.preferredTransform
        // atan2(b, a) gives the CCW rotation angle of the transform.
        let degrees = atan2(t.b, t.a) * (180.0 / .pi)
        switch Int(degrees.rounded()) {
        case 90, 91, 89:   return .right   // portrait: landscape buffer, rotate 90° CCW to display
        case -90, -91, -89, 270: return .left    // portrait upside-down
        case 180, -180:    return .down    // landscape upside-down
        default:           return .up      // natural landscape
        }
    }

    private func currentPixelBuffer() -> CVPixelBuffer? {
        guard let output = videoOutput else { return nil }
        // Map wall-clock host time to item time so the output stays in sync with
        // the player regardless of startup latency (consistent with LaserDetectionService).
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard CMTimeCompare(itemTime, CMTime.zero) >= 0 else { return nil }
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        return output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
    }
}
