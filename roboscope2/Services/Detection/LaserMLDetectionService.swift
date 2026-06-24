//
//  LaserMLDetectionService.swift
//  roboscope2
//
//  ML-based laser detection via CoreML + Vision (YOLO/segmentation models).
//  Core service: types, lifecycle, Vision request dispatch.
//  Heavy algorithms live in focused extensions:
//    +Decode.swift         — YOLO tensor decoding
//    +Segmentation.swift   — oriented quad via proto mask
//    +CoordinateMapping.swift — normalized coord transforms
//

import Foundation
import ARKit
import Combine
import CoreML
import Vision
import QuartzCore
import CoreGraphics
import CoreVideo

// MARK: - Output types

/// A matched dot+line pair with a 3-D distance measurement, produced by the detection overlay.
struct LaserDotLineMeasurement {
    let dotWorld: SIMD3<Float>
    let lineWorld: SIMD3<Float>
    let distanceMeters: Float
}

struct LaserMLOrientedQuad: Equatable {
    /// Points are in normalized image coordinates (0..1) with origin at top-left.
    /// Order is clockwise starting from top-left-ish corner (not guaranteed perfectly).
    let p1: CGPoint
    let p2: CGPoint
    let p3: CGPoint
    let p4: CGPoint
}

struct LaserMLDetection: Identifiable, Equatable {
    /// Stable identity derived from label + normalized bounding box, so SwiftUI can diff ForEach.
    var id: String { "\(label):\(String(format: "%.3f", boundingBox.origin.x)),\(String(format: "%.3f", boundingBox.origin.y)),\(String(format: "%.3f", boundingBox.size.width)),\(String(format: "%.3f", boundingBox.size.height))" }
    /// Bounding box in normalized image coordinates (0..1), origin at top-left.
    let boundingBox: CGRect
    /// Optional rotated quad in normalized image coordinates.
    let orientedQuad: LaserMLOrientedQuad?
    /// Sampled mask-positive points in raw normalized image coordinates (0..1).
    /// Used by the multi-frame accumulator to refit an oriented quad after merging clusters.
    let maskPoints: [CGPoint]?
    /// Raw class index from the model output (when available).
    let classIndex: Int?
    let label: String
    let confidence: Float
    let timestamp: Date

    init(
        boundingBox: CGRect,
        orientedQuad: LaserMLOrientedQuad? = nil,
        maskPoints: [CGPoint]? = nil,
        classIndex: Int? = nil,
        label: String,
        confidence: Float,
        timestamp: Date
    ) {
        self.boundingBox = boundingBox
        self.orientedQuad = orientedQuad
        self.maskPoints = maskPoints
        self.classIndex = classIndex
        self.label = label
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

// MARK: - Service

final class LaserMLDetectionService: ObservableObject {
    @Published var detections: [LaserMLDetection] = []
    @Published var isDetecting: Bool = false
    @Published var lastError: String? = nil

    // ML tuning (driven by the in-session settings panel)
    @Published var confidenceThreshold: Float = 0.50
    @Published var useROI: Bool = false
    /// Centered square ROI size (0..1), applied when `useROI == true`.
    @Published var roiSize: Float = 0.60
    /// Max world-space Y delta (metres) between dot and line for a valid pair.
    /// Forwarded to LaserMLDetectionOverlay for filtering.
    @Published var maxDotLineYDeltaMeters: Float = 0.20

    /// Max number of boxes to publish.
    var maxDetections: Int = 20

    let processingQueue = DispatchQueue(label: "LaserGuide.LaserMLDetection", qos: .userInitiated)
    let stateLock = NSLock()
    var isProcessingFrame: Bool = false

    var lastProcessTime: TimeInterval = 0
    let processingInterval: TimeInterval = 1.0 / 15.0
    var detectionGeneration: UInt64 = 0

    var didLogModelLoad: Bool = false
    var lastStatsLogTime: TimeInterval = 0
    var lastResultsTypeLogTime: TimeInterval = 0

    @Published var modelInputSize: CGSize? = nil

    var request: VNCoreMLRequest? = nil
    /// The currently loaded model path (compiled .mlmodelc) used to build `request`.
    var requestModelPath: String? = nil

    /// The model URL assigned for the current session's Space.
    /// Must be set by the session host before detection starts.
    var assignedModelURL: URL? = nil

    /// Assign a new model URL and reload the internal Vision request on the next frame.
    func setModelURL(_ url: URL) {
        log("setModelURL: \(url.lastPathComponent)")
        assignedModelURL = url
        reloadModel()
        // Eagerly infer input size so it's available in the UI without waiting for first detection frame.
        processingQueue.async { [weak self] in
            guard let self else { return }
            if let (mlModel, _) = try? Self.loadLaserPensModel(overrideURL: url) {
                let size = Self.inferModelInputSize(from: mlModel)
                self.log("setModelURL: inferredSize=\(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")
                DispatchQueue.main.async { self.modelInputSize = size }
            }
        }
    }

    func log(_ message: String) {
        print("[LaserGuideML] \(message)")
    }

    func reloadModel() {
        log("reloadModel called")
        request = nil
        requestModelPath = nil
        didLogModelLoad = false
        modelInputSize = nil
        lastError = nil
    }

    func ensureRequest() -> VNCoreMLRequest? {
        let overrideURL = assignedModelURL
        let desiredPath = overrideURL?.path

        if let request, requestModelPath == desiredPath {
            return request  // cache hit — intentionally silent
        }

        log("ensureRequest: cache miss, loading model overrideURL=\(overrideURL?.lastPathComponent ?? "nil") desiredPath=\(desiredPath ?? "nil")")

        do {
            let (mlModel, modelURL) = try Self.loadLaserPensModel(overrideURL: overrideURL)
            log("ensureRequest: MLModel loaded, modelURL=\(modelURL?.lastPathComponent ?? "nil")")
            let vnModel = try VNCoreMLModel(for: mlModel)
            let request = VNCoreMLRequest(model: vnModel)
            // YOLO models are typically trained with letterbox (scaleFit) preprocessing.
            // Using scaleFit ensures the inverse coordinate mapping matches training.
            request.imageCropAndScaleOption = .scaleFit

            self.request = request
            self.requestModelPath = modelURL?.path

            if !self.didLogModelLoad {
                self.didLogModelLoad = true
                let inferredSize = Self.inferModelInputSize(from: mlModel)
                log("ensureRequest: inferredSize=\(inferredSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")
                DispatchQueue.main.async {
                    self.modelInputSize = inferredSize
                }
                if let modelURL {
                    if let inferredSize {
                        self.log("Model loaded (\(modelURL.lastPathComponent)) input=\(Int(inferredSize.width))x\(Int(inferredSize.height)) and VNCoreMLRequest created")
                    } else {
                        self.log("Model loaded (\(modelURL.lastPathComponent)) and VNCoreMLRequest created")
                    }
                } else {
                    self.log("Model loaded and VNCoreMLRequest created")
                }
            }
            return request
        } catch {
            log("ensureRequest: FAILED \(error)")
            DispatchQueue.main.async {
                self.lastError = "Failed to load ML model: \(error.localizedDescription)"
            }
            return nil
        }
    }

    // MARK: - Lifecycle

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

    // MARK: - Frame input

    /// Process an AR frame. Delegates to `processPixelBuffer` — prefer calling that directly
    /// when an ARFrame is not available (e.g. in Video Mode).
    func processFrame(_ frame: ARFrame, orientation: CGImagePropertyOrientation = .right) {
        processPixelBuffer(frame.capturedImage, orientation: orientation)
    }

    /// Feed a raw CVPixelBuffer for ML detection.
    /// Works in both AR and Video Mode (no ARFrame dependency).
    func processPixelBuffer(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) {
        guard isDetecting else { return }
        guard let request = ensureRequest() else {
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
        let modelInputSize = self.modelInputSize

        // Pass pixel buffer across the DispatchQueue boundary via an unmanaged pointer to avoid
        // Swift 6 Sendable warnings/errors for CVPixelBuffer in @Sendable closures.
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
                orientation: orientation,
                options: [:]
            )

            do {
                // Apply ROI (Vision uses normalized coordinates with origin at bottom-left).
                // Keep an equivalent top-left normalized rect for mapping decoded tensor outputs.
                let roiRectTopLeft: CGRect
                if useROI {
                    let size = CGFloat(roiSize)
                    let x = (1.0 - size) / 2.0
                    let yTopLeft = (1.0 - size) / 2.0
                    let yBottomLeft = 1.0 - yTopLeft - size
                    request.regionOfInterest = CGRect(x: x, y: yBottomLeft, width: size, height: size)
                    roiRectTopLeft = CGRect(x: x, y: yTopLeft, width: size, height: size)
                } else {
                    request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
                    roiRectTopLeft = CGRect(x: 0, y: 0, width: 1, height: 1)
                }

                try handler.perform([request])
                let results = request.results ?? []

                // Some models produce VNRecognizedObjectObservation; others only produce VNDetectedObjectObservation.
                // Handle both, so "detections=0" doesn't silently hide valid boxes.
                let recognized = results.compactMap { $0 as? VNRecognizedObjectObservation }
                let detected = results.compactMap { $0 as? VNDetectedObjectObservation }

                let recognizedMapped: [LaserMLDetection] = recognized
                    .sorted(by: { ($0.labels.first?.confidence ?? $0.confidence) > ($1.labels.first?.confidence ?? $1.confidence) })
                    .filter { obs in
                        let labelConf = obs.labels.first?.confidence ?? obs.confidence
                        return labelConf >= confidenceThreshold
                    }
                    .prefix(maxDetections)
                    .map { obs in
                        let topLabel = obs.labels.first
                        let label = topLabel?.identifier ?? "object"
                        let conf = topLabel?.confidence ?? obs.confidence
                        return LaserMLDetection(
                            boundingBox: Self.toTopLeftBoundingBox(obs.boundingBox),
                            orientedQuad: nil,
                            classIndex: nil,
                            label: label,
                            confidence: conf,
                            timestamp: Date()
                        )
                    }

                let detectedMapped: [LaserMLDetection] = detected
                    .filter { !($0 is VNRecognizedObjectObservation) }
                    .sorted(by: { $0.confidence > $1.confidence })
                    .filter { $0.confidence >= confidenceThreshold }
                    .prefix(max(0, maxDetections - recognizedMapped.count))
                    .map { obs in
                        return LaserMLDetection(
                            boundingBox: Self.toTopLeftBoundingBox(obs.boundingBox),
                            orientedQuad: nil,
                            classIndex: nil,
                            label: "object",
                            confidence: obs.confidence,
                            timestamp: Date()
                        )
                    }

                let mapped = recognizedMapped + detectedMapped

                let coreMLFeatures = results.compactMap { $0 as? VNCoreMLFeatureValueObservation }
                let decodedFromFeatures: [LaserMLDetection]
                if mapped.isEmpty, !coreMLFeatures.isEmpty {
                    decodedFromFeatures = self.decodeYOLOLikeDetections(
                        from: coreMLFeatures,
                        modelInputSize: modelInputSize,
                        orientedImageSize: Self.orientedImageSize(for: pixelBuffer, orientation: orientation),
                        roiRectTopLeftNormalized: roiRectTopLeft,
                        orientation: orientation,
                        cropAndScaleOption: request.imageCropAndScaleOption,
                        confidenceThreshold: confidenceThreshold,
                        maxDetections: maxDetections
                    )
                } else {
                    decodedFromFeatures = []
                }

                let allMapped = mapped.isEmpty ? decodedFromFeatures : mapped

                // Occasionally log what Vision is returning to help diagnose mismatches.
                let now = CACurrentMediaTime()
                if now - self.lastResultsTypeLogTime >= 3.0 {
                    self.lastResultsTypeLogTime = now
                    let classificationCount = results.filter { $0 is VNClassificationObservation }.count
                    let featureCount = results.filter { $0 is VNCoreMLFeatureValueObservation }.count
                    self.log(
                        "Vision results: total=\(results.count) recognized=\(recognized.count) detected=\(detected.count) class=\(classificationCount) feature=\(featureCount) crop=\(request.imageCropAndScaleOption) orientation=\(orientation.rawValue)"
                    )
                }

                DispatchQueue.main.async {
                    guard self.isDetecting, self.detectionGeneration == generation else { return }
                    self.detections = allMapped

                    let now = CACurrentMediaTime()
                    if now - self.lastStatsLogTime >= 1.5 {
                        self.lastStatsLogTime = now
                        self.log("Detections=\(allMapped.count) threshold=\(String(format: "%.2f", confidenceThreshold)) ROI=\(useROI ? String(format: "%.2f", roiSize) : "off")")
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

    // MARK: - Model loading

    static func loadLaserPensModel(overrideURL: URL?) throws -> (MLModel, URL?) {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let overrideURL {
            return (try MLModel(contentsOf: overrideURL, configuration: config), overrideURL)
        }

        throw NSError(
            domain: "LaserMLDetectionService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No ML model assigned for this Space. The session cannot start without a configured model URL."]
        )
    }

    // MARK: - Small coordinate/size utilities (used in processPixelBuffer)

    static func toTopLeftBoundingBox(_ visionBottomLeftBox: CGRect) -> CGRect {
        // Vision bounding boxes are normalized with origin at bottom-left.
        // Convert to normalized image coords with origin at top-left to match ARFrame.displayTransform.
        CGRect(
            x: visionBottomLeftBox.origin.x,
            y: 1.0 - visionBottomLeftBox.origin.y - visionBottomLeftBox.size.height,
            width: visionBottomLeftBox.size.width,
            height: visionBottomLeftBox.size.height
        )
    }

    static func inferModelInputSize(from model: MLModel) -> CGSize? {
        let inputs = model.modelDescription.inputDescriptionsByName
        print("[LaserGuideML] inferModelInputSize: \(inputs.count) input(s)")
        for (name, input) in inputs {
            print("[LaserGuideML]   input '\(name)' type=\(input.type.rawValue)")
            // Image input (explicit CoreML image type)
            if let constraint = input.imageConstraint {
                print("[LaserGuideML]     imageConstraint: \(constraint.pixelsWide)x\(constraint.pixelsHigh)")
                let w = CGFloat(constraint.pixelsWide)
                let h = CGFloat(constraint.pixelsHigh)
                if w > 0, h > 0 {
                    return CGSize(width: w, height: h)
                }
            }
            // MultiArray input — YOLO typically exports as [1, 3, H, W]
            if let constraint = input.multiArrayConstraint {
                let shape = constraint.shape
                print("[LaserGuideML]     multiArrayConstraint shape=\(shape) dataType=\(constraint.dataType.rawValue)")
                if shape.count == 4 {
                    let h = CGFloat(truncating: shape[2])
                    let w = CGFloat(truncating: shape[3])
                    if w > 0, h > 0 {
                        return CGSize(width: w, height: h)
                    }
                } else if shape.count == 3 {
                    let h = CGFloat(truncating: shape[1])
                    let w = CGFloat(truncating: shape[2])
                    if w > 0, h > 0 {
                        return CGSize(width: w, height: h)
                    }
                }
            }
            if input.imageConstraint == nil && input.multiArrayConstraint == nil {
                print("[LaserGuideML]     (no imageConstraint or multiArrayConstraint)")
            }
        }
        print("[LaserGuideML] inferModelInputSize: returning nil")
        return nil
    }

    static func orientedImageSize(for pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGSize {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: h, height: w)
        default:
            return CGSize(width: w, height: h)
        }
    }
}
