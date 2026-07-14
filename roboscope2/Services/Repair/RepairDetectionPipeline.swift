//
//  RepairDetectionPipeline.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied from Services/Detection/DetectionPipeline.swift (READ-ONLY reference) per
//  05-ios-repair.md §5.2. Wraps RepairMLDetectionService and routes raw pixel buffers to it;
//  keeps the objectWillChange forwarding + processPixelBuffer passthrough.
//

import Foundation
import ARKit
import Combine
import CoreVideo

final class RepairDetectionPipeline: ObservableObject {

    // MARK: - Child service (accessible for settings panel bindings)

    let ml: RepairMLDetectionService

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// Default init: creates a fresh RepairMLDetectionService instance.
    init() {
        self.ml = RepairMLDetectionService.make()
        forwardChildChanges()
    }

    /// Dependency-injection init — pass a pre-configured instance (useful for sharing
    /// the same instance with a parent view that holds SwiftUI bindings to it).
    init(ml: RepairMLDetectionService) {
        self.ml = ml
        forwardChildChanges()
    }

    private func forwardChildChanges() {
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
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) {
        ml.processPixelBuffer(pixelBuffer, orientation: orientation)
    }
}
