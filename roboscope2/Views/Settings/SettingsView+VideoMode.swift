//
//  SettingsView+VideoMode.swift
//  roboscope2
//
//  Video Mode management row and document picker for SettingsView.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Video Mode UI

extension SettingsView {

    /// Inline row shown when Video Mode is toggled on.
    @ViewBuilder
    var videoModeRow: some View {
        // Stored video info
        if let url = videoService.savedVideoURL {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("Video ready")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Spacer()
                Button(role: .destructive) {
                    videoService.deleteVideo()
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("No video uploaded yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }

        // Upload button
        Button {
            showVideoModePicker = true
        } label: {
            Label(
                videoService.savedVideoURL == nil ? "Upload Video" : "Replace Video",
                systemImage: "square.and.arrow.up"
            )
        }

        // Distance scale calibration
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Distance Scale")
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.1f", settings.videoModeDistanceScale))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.videoModeDistanceScale, in: 0.5...20.0, step: 0.5)
            Text("Scales image-space detection distance into approximate world metres. Adjust until detected values match your laser guide segments.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        // Accumulator frame count
        Stepper(
            value: $settings.videoModeAccumulatorFrames,
            in: 1...10
        ) {
            HStack {
                Text("Accumulation Frames")
                    .font(.subheadline)
                Spacer()
                Text("\(settings.videoModeAccumulatorFrames)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        Text("Detections from the last N frames are merged before measurement, recovering laser lines drawn across multiple frames.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

// MARK: - Video Document Picker

struct VideoDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let first = urls.first else { onCancel(); return }
            onPick(first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
