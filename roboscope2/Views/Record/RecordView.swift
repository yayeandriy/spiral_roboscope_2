//
//  RecordView.swift
//  roboscope2
//
//  Video recording view with ready / recording / preview states.
//

import SwiftUI
import AVKit

struct RecordView: View {
    @StateObject private var viewModel = RecordViewModel()
    @State private var showingSettings = false
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var uploadError: String?
    @State private var currentUploadKey: String?
    @State private var currentUploadURL: String?
    @State private var copiedVideoID: UUID?

    private let storageService = SpiralStorageService.shared
    private let videoBasePath = "class-balance/roboscope/video"

    var body: some View {
        ZStack {
            // Full-screen camera background (ignores all safe areas)
            if viewModel.isCameraReady {
                CameraPreview(session: viewModel.captureSession)
                    .ignoresSafeArea(.all)
                    .frame(
                        maxHeight: viewModel.settings.proportion.isSquare
                            ? UIScreen.main.bounds.width
                            : .infinity
                    )
                    .clipped()
            } else {
                Color.black.ignoresSafeArea(.all)
                    .overlay(ProgressView().tint(.white))
            }

            // Overlaid controls
            switch viewModel.state {
            case .ready:
                readyOverlay
            case .recording:
                recordingOverlay
            case .preview(let url):
                previewView(url: url)
            }
        }
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if viewModel.state == .ready {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            CameraSettingsView(settings: $viewModel.settings)
        }
        .onChange(of: viewModel.settings.camera) { _, _ in
            viewModel.switchCamera()
        }
        .onAppear {
            viewModel.setupCamera()
        }
        .onDisappear {
            if viewModel.state == .recording {
                viewModel.stopRecording()
            }
            viewModel.stopCamera()
            viewModel.deleteRecording()
        }
    }

    // MARK: - Ready Overlay

    private var readyOverlay: some View {
        VStack {
            // Settings info badge
            HStack(spacing: 6) {
                Text(viewModel.settings.proportion.label)
                Text("•")
                Text("\(viewModel.settings.frameRate.rawValue)fps")
                Text("•")
                Text(viewModel.settings.quality.rawValue.capitalized)
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.top, 100)

            Spacer()

            // Record button
            Button {
                viewModel.startRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 80, height: 80)
                    Circle()
                        .strokeBorder(.red, lineWidth: 4)
                        .frame(width: 72, height: 72)
                }
            }
            .padding(.bottom, 20)

            // Latest upload card
            uploadedVideosList
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
        }
    }

    // MARK: - Recording Overlay

    private var recordingOverlay: some View {
        VStack {
            // Timer at top
            HStack(spacing: 12) {
                Text(formatTime(viewModel.elapsedSeconds))
                    .font(.title3.monospacedDigit())
                    .foregroundColor(viewModel.elapsedSeconds > 17 ? .red : .white)
                Text("·")
                    .foregroundColor(.white.opacity(0.5))
                Text("\(viewModel.frameCount)f")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(viewModel.frameCount > 0 ? .green : .red)
            }
            .padding(.top, 100)

            Spacer()

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.3))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.red)
                        .frame(width: geo.size.width * (viewModel.elapsedSeconds / 20.0), height: 6)
                        .animation(.linear(duration: 0.1), value: viewModel.elapsedSeconds)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 40)

            // Stop button
            Button {
                viewModel.stopRecording()
            } label: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.red)
                    .frame(width: 60, height: 60)
            }
            .padding(.top, 20)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Preview State

    private func previewView(url: URL) -> some View {
        VStack(spacing: 24) {
            Spacer()

            // Video player (clear background)
            ClearVideoPlayer(url: url)
                .aspectRatio(viewModel.settings.proportion.aspectRatio, contentMode: .fit)

            // Duration label
            Text(formatTime(viewModel.elapsedSeconds))
                .font(.title3.monospacedDigit())
                .foregroundColor(.white)

            // Recording error warning
            if viewModel.noFramesWarning {
                Text("Recording may be empty — check console")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Actions
            HStack(spacing: 24) {
                // Restart
                Button {
                    viewModel.restartRecording()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(Circle())

                // Upload
                if isUploading {
                    VStack(spacing: 8) {
                        ProgressView(value: uploadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                        Text("Uploading…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button {
                        uploadVideo(url: url)
                    } label: {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.title2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .background(.blue)
                    .foregroundColor(.white)
                    .clipShape(Circle())
                }

                // Delete
                Button {
                    viewModel.deleteRecording()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(12)
                .background(.ultraThinMaterial)
                .foregroundColor(.red)
                .clipShape(Circle())
            }

            // Error
            if let error = uploadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Upload

    private func uploadVideo(url: URL) {
        isUploading = true
        uploadProgress = 0
        uploadError = nil

        let videoID = UUID().uuidString
        let destinationPath = "\(videoBasePath)/\(videoID).mp4"

        Task {
            do {
                let uploadedURL = try await storageService.uploadFile(
                    fileURL: url,
                    destinationPath: destinationPath,
                    contentType: "video/mp4",
                    progress: { progress in
                        Task { @MainActor in
                            uploadProgress = progress
                        }
                    }
                )
                // Save to local history
                saveToHistory(key: destinationPath, url: uploadedURL)
                currentUploadKey = destinationPath
                currentUploadURL = uploadedURL
                isUploading = false
                viewModel.deleteRecording()
            } catch {
                isUploading = false
                uploadError = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Local History

    private func saveToHistory(key: String, url: String) {
        // Persist to UserDefaults for future reference (not shown in UI)
        var videos = UploadedVideo.loadAll()
        let video = UploadedVideo(
            id: UUID(),
            key: key,
            url: url,
            uploadedAt: Date()
        )
        videos.insert(video, at: 0)
        videos = Array(videos.prefix(50))
        UploadedVideo.saveAll(videos)
    }

    private var uploadedVideosList: some View {
        Group {
            if let key = currentUploadKey, let url = currentUploadURL {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if copiedVideoID != nil {
                            Text("Copied!")
                                .font(.body.weight(.medium))
                                .foregroundColor(.green)
                        } else {
                            Text(key)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "checkmark.icloud")
                        .font(.title3)
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onLongPressGesture {
                    UIPasteboard.general.string = url
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    withAnimation {
                        copiedVideoID = UUID()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            copiedVideoID = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 10)
        return String(format: "%d:%02d.%01d", m, s, ms)
    }
}

// MARK: - Camera Preview (UIViewControllerRepresentable)

private struct CameraPreview: UIViewControllerRepresentable {
    let session: AVCaptureSession

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        vc.view.layer.addSublayer(layer)
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard let layer = vc.view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer else { return }
        layer.frame = vc.view.bounds
        if layer.session != session {
            layer.session = session
        }
    }
}

// MARK: - Uploaded Video Model

struct UploadedVideo: Codable, Identifiable {
    let id: UUID
    let key: String
    let url: String
    let uploadedAt: Date

    private static let defaultsKey = "uploadedVideos"

    static func loadAll() -> [UploadedVideo] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let videos = try? JSONDecoder().decode([UploadedVideo].self, from: data)
        else { return [] }
        return videos
    }

    static func saveAll(_ videos: [UploadedVideo]) {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Clear Video Player (no dark background)

private struct ClearVideoPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.showsPlaybackControls = false
        vc.view.backgroundColor = .clear
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
}
