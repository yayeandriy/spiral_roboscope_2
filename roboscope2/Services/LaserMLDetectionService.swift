//
//  LaserMLDetectionService.swift
//  roboscope2
//
//  Optional laser detection via CoreML + Vision.
//  First milestone: run the model and publish bounding boxes for all detections.
//

import Foundation
import ARKit
import Combine
import CoreML
import Vision
import QuartzCore

struct LaserMLDetection: Identifiable, Equatable {
    let id = UUID()
    /// Bounding box in normalized image coordinates (0..1), origin at top-left.
    let boundingBox: CGRect
    let label: String
    let confidence: Float
    let timestamp: Date
}

final class LaserMLDetectionService: ObservableObject {
    @Published var detections: [LaserMLDetection] = []
    @Published var isDetecting: Bool = false
    @Published var lastError: String? = nil

    // ML tuning (driven by the in-session settings panel)
    @Published var confidenceThreshold: Float = 0.50
    @Published var useROI: Bool = false
    /// Centered square ROI size (0..1), applied when `useROI == true`.
    @Published var roiSize: Float = 0.60

    /// Max number of boxes to publish.
    var maxDetections: Int = 20

    private let processingQueue = DispatchQueue(label: "LaserGuide.LaserMLDetection", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isProcessingFrame: Bool = false

    private var lastProcessTime: TimeInterval = 0
    private let processingInterval: TimeInterval = 1.0 / 15.0
    private var detectionGeneration: UInt64 = 0

    private var didLogModelLoad: Bool = false
    private var lastStatsLogTime: TimeInterval = 0

    private func log(_ message: String) {
        print("[LaserGuideML] \(message)")
    }

    private lazy var request: VNCoreMLRequest? = {
        do {
            let mlModel = try Self.loadLaserPensModel()
            let vnModel = try VNCoreMLModel(for: mlModel)
            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFit
            if !self.didLogModelLoad {
                self.didLogModelLoad = true
                self.log("Model loaded and VNCoreMLRequest created")
            }
            return request
        } catch {
            DispatchQueue.main.async {
                self.lastError = "Failed to load ML model: \(error.localizedDescription)"
            }
            return nil
        }
    }()

    func startDetection() {
        detectionGeneration &+= 1
        isDetecting = true
        detections = []
        lastProcessTime = 0
        lastError = nil
        log("Detection started")
    }

    func stopDetection() {
        detectionGeneration &+= 1
        isDetecting = false
        detections = []
        log("Detection stopped")
    }

    func processFrame(_ frame: ARFrame) {
        guard isDetecting else { return }
        guard let request else {
            if lastError == nil {
                lastError = "ML request not available (model failed to load)"
                log("Skipping frames: ML request unavailable")
            }
            return
        }

        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessTime >= processingInterval else { return }
        lastProcessTime = currentTime

        stateLock.lock()
        if isProcessingFrame {
            stateLock.unlock()
            return
        }
        isProcessingFrame = true
        stateLock.unlock()

        let generation = detectionGeneration
        let maxDetections = self.maxDetections
        let confidenceThreshold = self.confidenceThreshold
        let useROI = self.useROI
        let roiSize = max(0.05, min(1.0, self.roiSize))

        let pixelBuffer = frame.capturedImage
        let pixelBufferOpaque = Unmanaged.passRetained(pixelBuffer).toOpaque()

        processingQueue.async { [weak self] in
            defer {
                self?.stateLock.lock()
                self?.isProcessingFrame = false
                self?.stateLock.unlock()
            }
            guard let self else { return }

            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBufferOpaque).takeRetainedValue()

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .right,
                options: [:]
            )

            do {
                // Apply ROI (Vision uses normalized coordinates with origin at bottom-left).
                if useROI {
                    let size = CGFloat(roiSize)
                    let x = (1.0 - size) / 2.0
                    let yTopLeft = (1.0 - size) / 2.0
                    let yBottomLeft = 1.0 - yTopLeft - size
                    request.regionOfInterest = CGRect(x: x, y: yBottomLeft, width: size, height: size)
                } else {
                    request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
                }

                try handler.perform([request])
                let results = request.results ?? []

                let objectObservations = results.compactMap { $0 as? VNRecognizedObjectObservation }

                let mapped: [LaserMLDetection] = objectObservations
                    .sorted(by: { $0.confidence > $1.confidence })
                    .filter { obs in
                        let labelConf = obs.labels.first?.confidence ?? obs.confidence
                        return labelConf >= confidenceThreshold
                    }
                    .prefix(maxDetections)
                    .map { obs in
                        let topLabel = obs.labels.first
                        let label = topLabel?.identifier ?? "object"
                        let conf = topLabel?.confidence ?? obs.confidence

                        // Vision bounding boxes are normalized with origin at bottom-left.
                        // Convert to normalized image coords with origin at top-left to match ARFrame.displayTransform.
                        let bb = obs.boundingBox
                        let topLeftBox = CGRect(
                            x: bb.origin.x,
                            y: 1.0 - bb.origin.y - bb.size.height,
                            width: bb.size.width,
                            height: bb.size.height
                        )

                        return LaserMLDetection(
                            boundingBox: topLeftBox,
                            label: label,
                            confidence: conf,
                            timestamp: Date()
                        )
                    }

                DispatchQueue.main.async {
                    guard self.isDetecting, self.detectionGeneration == generation else { return }
                    self.detections = mapped

                    let now = CACurrentMediaTime()
                    if now - self.lastStatsLogTime >= 1.5 {
                        self.lastStatsLogTime = now
                        self.log("Detections=\(mapped.count) threshold=\(String(format: "%.2f", confidenceThreshold)) ROI=\(useROI ? String(format: "%.2f", roiSize) : "off")")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.isDetecting, self.detectionGeneration == generation else { return }
                    self.lastError = error.localizedDescription
                    self.detections = []
                    self.log("Vision/CoreML error: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func loadLaserPensModel() throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let direct = Bundle.main.url(forResource: "laser-pens", withExtension: "mlmodelc") {
            return try MLModel(contentsOf: direct, configuration: config)
        }

        // Be resilient to filename sanitization (e.g. laser_pens.mlmodelc) and subdirectory placement.
        let candidates = (Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? [])
        if let match = candidates.first(where: {
            let name = $0.lastPathComponent.lowercased()
            return name.contains("laser") && name.contains("pens")
        }) {
            return try MLModel(contentsOf: match, configuration: config)
        }

        throw NSError(
            domain: "LaserMLDetectionService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No compiled model (.mlmodelc) found in app bundle. Ensure laser-pens.mlpackage is included in the app target."]
        )
    }
}
