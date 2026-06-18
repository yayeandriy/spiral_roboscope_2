//
//  DetectionPipeline.swift
//  roboscope2
//
//  Reusable ML detection pipeline that owns a LaserMLDetectionService and routes raw
//  pixel buffers to it.  Frame sources — AR camera (ARFrame.capturedImage) or Video
//  Mode (AVPlayerItemVideoOutput) — feed into processPixelBuffer; the pipeline itself
//  has no ARFrame dependency.
//

import Foundation
import ARKit
import Combine
import CoreVideo

final class DetectionPipeline: ObservableObject {

    // MARK: - Child service (accessible for settings panel bindings)

    let ml: LaserMLDetectionService

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// Default init: creates a fresh LaserMLDetectionService instance.
    init() {
        self.ml = LaserMLDetectionService.make()
        forwardChildChanges()
    }

    /// Dependency-injection init — pass a pre-configured instance (useful for sharing
    /// the same instance with a parent view that holds SwiftUI bindings to it).
    init(ml: LaserMLDetectionService) {
        self.ml = ml
        forwardChildChanges()
    }

    private func forwardChildChanges() {
        // Forward objectWillChange from the child so SwiftUI views that observe
        // DetectionPipeline re-render when any @Published property on ml changes.
        ml.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        ml.startDetection()
    }

    func stop() {
        ml.stopDetection()
    }

    // MARK: - Frame processing

    /// Feed a raw pixel buffer — works in both AR and Video Mode (no ARFrame dependency).
    /// `orientation` describes how the image data is physically oriented relative to
    /// portrait-up; for the back camera in portrait this is `.right`.
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) {
        ml.processPixelBuffer(pixelBuffer, orientation: orientation)
    }
}
