//
//  RecordViewModel.swift
//  roboscope2
//
//  Manages AVCaptureSession + AVCaptureMovieFileOutput for video recording.
//

import AVFoundation
import Combine
import SwiftUI

@MainActor
final class RecordViewModel: NSObject, ObservableObject {

    // MARK: - States

    enum State: Equatable {
        case ready
        case recording
        case preview(url: URL)
    }

    @Published var state: State = .ready
    @Published var elapsedSeconds: Double = 0
    @Published var settings = RecorderSettings.load()
    @Published var isCameraReady = false
    @Published var frameCount = 0
    @Published var noFramesWarning = false

    // Camera
    nonisolated(unsafe) let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "recorder.session")
    private nonisolated(unsafe) var videoDeviceInput: AVCaptureDeviceInput?
    private nonisolated(unsafe) let movieOutput = AVCaptureMovieFileOutput()
    private var recordingTimer: Timer?
    private let maxDuration: Double = 20.0
    /// Capture device format dimensions (width × height in pixels) — used to match the preview crop.
    nonisolated(unsafe) var captureFormatDimensions: CGSize = .zero

    // MARK: - Public API

    func startRecording() {
        guard state == .ready,
              let connection = movieOutput.connection(with: .video) else { return }

        // Disable stabilization — it crops the video and causes preview mismatch
        connection.preferredVideoStabilizationMode = .off

        // Match video orientation to device so preview and recording align
        let rotationAngle: CGFloat
        switch UIDevice.current.orientation {
        case .portrait:           rotationAngle = 90
        case .portraitUpsideDown: rotationAngle = 270
        case .landscapeLeft:      rotationAngle = 0
        case .landscapeRight:     rotationAngle = 180
        default:                  rotationAngle = 90
        }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        // Re-read format at record time — the session may have changed it
        if let device = videoDeviceInput?.device {
            let fd = device.activeFormat.formatDescription
            let d = CMVideoFormatDescriptionGetDimensions(fd)
            captureFormatDimensions = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
        }

        let url = tempVideoURL()
        elapsedSeconds = 0
        frameCount = 0
        noFramesWarning = false
        state = .recording
        movieOutput.startRecording(to: url, recordingDelegate: self)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        recordingTimer?.invalidate()
        recordingTimer = nil
        movieOutput.stopRecording()
    }

    func deleteRecording() {
        if case .preview(let url) = state {
            try? FileManager.default.removeItem(at: url)
        }
        state = .ready
        elapsedSeconds = 0
    }

    func restartRecording() {
        deleteRecording()
        startRecording()
    }

    // MARK: - Camera Setup

    func setupCamera() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { Task { @MainActor [weak self] in self?.configureSession() } }
            }
        default:
            print("[RecordVM] Camera not authorized: \(status)")
        }
    }

    private func configureSession() {
        let cameraSetting = settings.camera
        sessionQueue.async { [weak self] in
            guard let self, !captureSession.isRunning else { return }
            captureSession.beginConfiguration()
            captureSession.sessionPreset = .high

            if let device = Self.preferredCamera(cameraSetting) {
                let fd = device.activeFormat.formatDescription
                let d = CMVideoFormatDescriptionGetDimensions(fd)
                self.captureFormatDimensions = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if captureSession.canAddInput(input) {
                        captureSession.addInput(input)
                        videoDeviceInput = input
                    }
                } catch {
                    print("[RecordVM] Camera input error: \(error)")
                }
            }

            // Movie file output — writes directly, no delegate needed
            if captureSession.canAddOutput(movieOutput) {
                captureSession.addOutput(movieOutput)
            }

            captureSession.commitConfiguration()

            Task { @MainActor [captureSession] in
                captureSession.startRunning()
                self.isCameraReady = true
            }
        }
    }

    func stopCamera() {
        captureSession.stopRunning()
    }

    func switchCamera() {
        let cameraSetting = settings.camera
        sessionQueue.async { [weak self] in
            guard let self, captureSession.isRunning else { return }
            captureSession.beginConfiguration()
            if let oldInput = videoDeviceInput {
                captureSession.removeInput(oldInput)
                videoDeviceInput = nil
            }
            if let device = Self.preferredCamera(cameraSetting) {
                let fd = device.activeFormat.formatDescription
                let d = CMVideoFormatDescriptionGetDimensions(fd)
                self.captureFormatDimensions = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if captureSession.canAddInput(input) {
                        captureSession.addInput(input)
                        videoDeviceInput = input
                    }
                } catch {
                    print("[RecordVM] Camera switch error: \(error)")
                }
            }
            captureSession.commitConfiguration()
        }
    }

    // MARK: - Private

    private func tick() {
        elapsedSeconds += 0.1
        frameCount += 1  // rough frame counter via timer ticks
        if elapsedSeconds >= maxDuration {
            stopRecording()
        }
    }

    private func tempVideoURL() -> URL {
        let dir = NSTemporaryDirectory()
        let name = "recording-\(UUID().uuidString).mp4"
        return URL(fileURLWithPath: dir).appendingPathComponent(name)
    }

    private static nonisolated func preferredCamera(_ camera: RecorderSettings.CameraPosition) -> AVCaptureDevice? {
        switch camera {
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .back:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .backUltraWide:
            if let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
                return ultra
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension RecordViewModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        Task { @MainActor in
            if let error {
                print("[RecordVM] Recording failed: \(error.localizedDescription)")
                noFramesWarning = true
                state = .preview(url: outputFileURL)
                return
            }

            // Post-process: crop to square if needed
            let finalURL: URL
            if settings.proportion.isSquare {
                finalURL = await cropToSquare(sourceURL: outputFileURL)
            } else {
                finalURL = outputFileURL
            }

            if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
               let size = attrs[.size] as? Int64 {
                print("[RecordVM] Recording complete — \(size) bytes")
                noFramesWarning = size < 1000
            }
            state = .preview(url: finalURL)
        }
    }

    /// Center-crop to square with NO scaling — 1:1 pixel mapping from source.
    /// Because the preview layer (.resizeAspectFill) and this crop both
    /// take the center square of the source frame, they match by definition.
    private func cropToSquare(sourceURL: URL) async -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return sourceURL
        }

        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        do {
            naturalSize = try await track.load(.naturalSize)
            preferredTransform = try await track.load(.preferredTransform)
        } catch {
            return sourceURL
        }

        // Center crop: take the smaller dimension as the square side
        let squareSize = min(naturalSize.width, naturalSize.height)
        let xOffset = (naturalSize.width - squareSize) / 2
        let yOffset = (naturalSize.height - squareSize) / 2

        // Rotate first, then translate to crop origin
        let transform = preferredTransform.translatedBy(x: -xOffset, y: -yOffset)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: squareSize, height: squareSize)
        composition.frameDuration = (try? await track.load(.minFrameDuration)) ?? CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        let duration = (try? await asset.load(.duration)) ?? CMTime(value: 1, timescale: 30)
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        let outputURL = tempVideoURL()
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return sourceURL
        }
        exporter.videoComposition = composition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4

        if #available(iOS 18, *) {
            try? await exporter.export(to: outputURL, as: .mp4)
        } else {
            await exporter.export()
        }

        try? FileManager.default.removeItem(at: sourceURL)
        return outputURL
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            print("[RecordVM] Recording started")
        }
    }
}
