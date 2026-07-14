//
//  RepairMLDetectionService.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied from Services/Detection/LaserMLDetectionService.swift (READ-ONLY reference) per
//  05-ios-repair.md §5.2. Renamed LaserMLDetection -> RepairDetection, service ->
//  RepairMLDetectionService. Keeps VNCoreMLRequest setup, processPixelBuffer(_:orientation:),
//  and YOLO tensor decode verbatim in spirit. The +Segmentation.swift half (oriented quads /
//  mask points) is DROPPED — Repair places single-point pins, not quads, so RepairDetection
//  carries only a bounding box (no orientedQuad / maskPoints fields).
//

import Foundation
import ARKit
import Combine
import CoreML
import Vision
import QuartzCore
import CoreGraphics
import CoreVideo

// MARK: - Output type

struct RepairDetection: Identifiable, Equatable {
    /// Stable identity derived from label + normalized bounding box, so SwiftUI can diff ForEach.
    var id: String { "\(label):\(String(format: "%.3f", boundingBox.origin.x)),\(String(format: "%.3f", boundingBox.origin.y)),\(String(format: "%.3f", boundingBox.size.width)),\(String(format: "%.3f", boundingBox.size.height))" }
    /// Bounding box in normalized image coordinates (0..1), origin at top-left.
    let boundingBox: CGRect
    /// Raw class index from the model output (when available).
    let classIndex: Int?
    let label: String
    let confidence: Float
    let timestamp: Date

    init(
        boundingBox: CGRect,
        classIndex: Int? = nil,
        label: String,
        confidence: Float,
        timestamp: Date
    ) {
        self.boundingBox = boundingBox
        self.classIndex = classIndex
        self.label = label
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

// MARK: - Service

final class RepairMLDetectionService: ObservableObject {
    @Published var detections: [RepairDetection] = []
    @Published var isDetecting: Bool = false
    @Published var lastError: String? = nil

    // ML tuning
    @Published var confidenceThreshold: Float = 0.50
    @Published var useROI: Bool = false
    /// Centered square ROI size (0..1), applied when `useROI == true`.
    @Published var roiSize: Float = 0.60

    /// Max number of boxes to publish.
    var maxDetections: Int = 20

    let processingQueue = DispatchQueue(label: "Repair.MLDetection", qos: .userInitiated)
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

    /// The model URL assigned for the current session's selected CoremlModel.
    /// Must be set by the session host (RepairModelDownloadService) before detection starts.
    var assignedModelURL: URL? = nil

    /// Class labels for the currently assigned model (from CoremlModel.classLabels).
    /// Used to name detections when the model has no embedded label metadata.
    var classLabels: [String] = ["object"]

    /// Assign a new model URL and reload the internal Vision request on the next frame.
    func setModelURL(_ url: URL, classLabels: [String] = ["object"]) {
        log("setModelURL: \(url.lastPathComponent)")
        assignedModelURL = url
        self.classLabels = classLabels.isEmpty ? ["object"] : classLabels
        reloadModel()
        // Eagerly infer input size so it's available in the UI without waiting for first detection frame.
        processingQueue.async { [weak self] in
            guard let self else { return }
            if let (mlModel, _) = try? Self.loadRepairModel(overrideURL: url) {
                let size = Self.inferModelInputSize(from: mlModel)
                self.log("setModelURL: inferredSize=\(size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")
                DispatchQueue.main.async { self.modelInputSize = size }
            }
        }
    }

    func log(_ message: String) {
        print("[RepairML] \(message)")
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
            let (mlModel, modelURL) = try Self.loadRepairModel(overrideURL: overrideURL)
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

    func processFrame(_ frame: ARFrame, orientation: CGImagePropertyOrientation = .right) {
        processPixelBuffer(frame.capturedImage, orientation: orientation)
    }

    /// Feed a raw CVPixelBuffer for ML detection.
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
        let classLabels = self.classLabels

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

            let orientedSize = Self.orientedImageSize(for: pixelBuffer, orientation: orientation)

            do {
                let roiRectTopLeft: CGRect
                if useROI {
                    let size = CGFloat(roiSize)
                    let x = (1.0 - size) / 2.0
                    let yTopLeft = (1.0 - size) / 2.0
                    let yBottomLeft = 1.0 - yTopLeft - size
                    request.regionOfInterest = CGRect(x: x, y: yBottomLeft, width: size, height: size)
                    roiRectTopLeft = CGRect(x: x, y: yTopLeft, width: size, height: size)
                } else {
                    // Center-crop the frame to match the model's aspect ratio so Vision has
                    // no letterbox padding to add.
                    let inputSize = modelInputSize ?? CGSize(width: 640, height: 640)
                    let modelAspect = inputSize.width / inputSize.height
                    let frameAspect = orientedSize.width / orientedSize.height

                    let cropW: CGFloat
                    let cropH: CGFloat
                    if frameAspect > modelAspect {
                        cropH = orientedSize.height
                        cropW = cropH * modelAspect
                    } else {
                        cropW = orientedSize.width
                        cropH = cropW / modelAspect
                    }

                    let normX = ((orientedSize.width - cropW) / 2.0) / orientedSize.width
                    let normY = ((orientedSize.height - cropH) / 2.0) / orientedSize.height
                    let normW = cropW / orientedSize.width
                    let normH = cropH / orientedSize.height

                    roiRectTopLeft = CGRect(x: normX, y: normY, width: normW, height: normH)
                    request.regionOfInterest = CGRect(x: normX, y: 1.0 - normY - normH, width: normW, height: normH)
                }

                try handler.perform([request])
                let results = request.results ?? []

                let recognized = results.compactMap { $0 as? VNRecognizedObjectObservation }
                let detected = results.compactMap { $0 as? VNDetectedObjectObservation }

                let recognizedMapped: [RepairDetection] = recognized
                    .sorted(by: { ($0.labels.first?.confidence ?? $0.confidence) > ($1.labels.first?.confidence ?? $1.confidence) })
                    .filter { obs in
                        let labelConf = obs.labels.first?.confidence ?? obs.confidence
                        return labelConf >= confidenceThreshold
                    }
                    .prefix(maxDetections)
                    .map { obs in
                        let topLabel = obs.labels.first
                        let label = topLabel?.identifier ?? (classLabels.first ?? "object")
                        let conf = topLabel?.confidence ?? obs.confidence
                        return RepairDetection(
                            boundingBox: Self.toTopLeftBoundingBox(obs.boundingBox),
                            classIndex: nil,
                            label: label,
                            confidence: conf,
                            timestamp: Date()
                        )
                    }

                let detectedMapped: [RepairDetection] = detected
                    .filter { !($0 is VNRecognizedObjectObservation) }
                    .sorted(by: { $0.confidence > $1.confidence })
                    .filter { $0.confidence >= confidenceThreshold }
                    .prefix(max(0, maxDetections - recognizedMapped.count))
                    .map { obs in
                        return RepairDetection(
                            boundingBox: Self.toTopLeftBoundingBox(obs.boundingBox),
                            classIndex: nil,
                            label: classLabels.first ?? "object",
                            confidence: obs.confidence,
                            timestamp: Date()
                        )
                    }

                let mapped = recognizedMapped + detectedMapped

                let coreMLFeatures = results.compactMap { $0 as? VNCoreMLFeatureValueObservation }
                let decodedFromFeatures: [RepairDetection]
                if mapped.isEmpty, !coreMLFeatures.isEmpty {
                    decodedFromFeatures = self.decodeYOLOLikeDetections(
                        from: coreMLFeatures,
                        modelInputSize: modelInputSize,
                        orientedImageSize: orientedSize,
                        roiRectTopLeftNormalized: roiRectTopLeft,
                        orientation: orientation,
                        cropAndScaleOption: request.imageCropAndScaleOption,
                        confidenceThreshold: confidenceThreshold,
                        maxDetections: maxDetections,
                        classLabels: classLabels
                    )
                } else {
                    decodedFromFeatures = []
                }

                let allMapped = mapped.isEmpty ? decodedFromFeatures : mapped

                let now = CACurrentMediaTime()
                if now - self.lastResultsTypeLogTime >= 3.0 {
                    self.lastResultsTypeLogTime = now
                    self.log(
                        "Vision results: total=\(results.count) recognized=\(recognized.count) detected=\(detected.count) crop=\(request.imageCropAndScaleOption) orientation=\(orientation.rawValue)"
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

    static func loadRepairModel(overrideURL: URL?) throws -> (MLModel, URL?) {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let overrideURL {
            return (try MLModel(contentsOf: overrideURL, configuration: config), overrideURL)
        }

        throw NSError(
            domain: "RepairMLDetectionService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No ML model assigned. The Repair session cannot start detection without a configured model URL."]
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
        for (_, input) in inputs {
            if let constraint = input.imageConstraint {
                let w = CGFloat(constraint.pixelsWide)
                let h = CGFloat(constraint.pixelsHigh)
                if w > 0, h > 0 {
                    return CGSize(width: w, height: h)
                }
            }
            if let constraint = input.multiArrayConstraint {
                let shape = constraint.shape
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
        }
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

// MARK: - Dependency injection hook (mirrors LaserMLDetectionService+DI.swift)

extension RepairMLDetectionService {
    /// Override in tests to provide a custom instance.
    static var provider: () -> RepairMLDetectionService = { RepairMLDetectionService() }

    /// Convenience: creates a fresh instance via the current provider.
    static func make() -> RepairMLDetectionService { provider() }
}
