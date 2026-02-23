//
//  DetectionPipeline.swift
//  roboscope2
//
//  Reusable detection pipeline that owns both Classic (brightness/hue) and ML (CoreML/YOLO)
//  detection services and routes raw pixel buffers to whichever is active.
//
//  Plug this into AR Mode (feed from ARFrame.capturedImage) or Video Mode (feed from
//  AVPlayerItemVideoOutput) — the pipeline itself has no ARFrame dependency.
//

import Foundation
import ARKit
import Combine
import CoreVideo

final class DetectionPipeline: ObservableObject {

    // MARK: - Child services (accessible for settings panel bindings)

    let classic: LaserDetectionService
    let ml: LaserMLDetectionService

    // MARK: - Mode

    /// Which backend is currently active. Updated by `start(useML:)` and `switchMode(useML:)`.
    @Published private(set) var useML: Bool = false

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// Default init: creates fresh service instances.
    init() {
        self.classic = LaserDetectionService()
        self.ml = LaserMLDetectionService()
        forwardChildChanges()
    }

    /// Dependency-injection init — pass pre-configured instances (useful for testing or
    /// sharing instances with a parent that already holds references for SwiftUI bindings).
    init(classic: LaserDetectionService, ml: LaserMLDetectionService) {
        self.classic = classic
        self.ml = ml
        forwardChildChanges()
    }

    private func forwardChildChanges() {
        // Forward objectWillChange from each child so SwiftUI views that observe
        // DetectionPipeline re-render when any child @Published property changes.
        classic.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ml.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Start detection in the requested mode, stopping the other service.
    func start(useML: Bool) {
        self.useML = useML
        if useML {
            classic.stopDetection()
            ml.startDetection()
        } else {
            ml.stopDetection()
            classic.startDetection()
        }
    }

    /// Switch mode while detection is already running.
    func switchMode(useML: Bool) {
        guard useML != self.useML else { return }
        start(useML: useML)
    }

    /// Stop all detection.
    func stop() {
        classic.stopDetection()
        ml.stopDetection()
    }

    // MARK: - Frame processing

    /// Feed a raw pixel buffer — works in both AR and Video Mode (no ARFrame dependency).
    /// `orientation` describes how the image data is physically oriented relative to
    /// portrait-up; for the back camera in portrait this is `.right`.
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) {
        if useML {
            ml.processPixelBuffer(pixelBuffer, orientation: orientation)
        } else {
            classic.processPixelBuffer(pixelBuffer)
        }
    }
}
