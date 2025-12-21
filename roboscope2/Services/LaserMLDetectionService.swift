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
import CoreGraphics

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
    private var lastResultsTypeLogTime: TimeInterval = 0

    private var modelInputSize: CGSize? = nil

    private func log(_ message: String) {
        print("[LaserGuideML] \(message)")
    }

    private lazy var request: VNCoreMLRequest? = {
        do {
            let (mlModel, modelURL) = try Self.loadLaserPensModel()
            let vnModel = try VNCoreMLModel(for: mlModel)
            let request = VNCoreMLRequest(model: vnModel)
            // For object detection, scaleFill is typically the most robust default.
            // scaleFit can introduce letterboxing which may reduce detections depending on training.
            request.imageCropAndScaleOption = .scaleFill
            if !self.didLogModelLoad {
                self.didLogModelLoad = true
                self.modelInputSize = Self.inferModelInputSize(from: mlModel)
                if let modelURL {
                    if let modelInputSize {
                        self.log("Model loaded (\(modelURL.lastPathComponent)) input=\(Int(modelInputSize.width))x\(Int(modelInputSize.height)) and VNCoreMLRequest created")
                    } else {
                        self.log("Model loaded (\(modelURL.lastPathComponent)) and VNCoreMLRequest created")
                    }
                } else {
                    self.log("Model loaded and VNCoreMLRequest created")
                }
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

    func processFrame(_ frame: ARFrame, orientation: CGImagePropertyOrientation = .right) {
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
        let modelInputSize = self.modelInputSize

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
                orientation: orientation,
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
                            label: label,
                            confidence: conf,
                            timestamp: Date()
                        )
                    }

                let detectedMapped: [LaserMLDetection] = detected
                    // Avoid double-counting recognized observations (they are subclasses of detected).
                    .filter { !($0 is VNRecognizedObjectObservation) }
                    .sorted(by: { $0.confidence > $1.confidence })
                    .filter { $0.confidence >= confidenceThreshold }
                    .prefix(max(0, maxDetections - recognizedMapped.count))
                    .map { obs in
                        return LaserMLDetection(
                            boundingBox: Self.toTopLeftBoundingBox(obs.boundingBox),
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

    private static func loadLaserPensModel() throws -> (MLModel, URL?) {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let direct = Bundle.main.url(forResource: "laser-pens", withExtension: "mlmodelc") {
            return (try MLModel(contentsOf: direct, configuration: config), direct)
        }

        // Be resilient to filename sanitization (e.g. laser_pens.mlmodelc) and subdirectory placement.
        let candidates = (Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? [])
        if let match = candidates.first(where: {
            let name = $0.lastPathComponent.lowercased()
            return name.contains("laser") && name.contains("pens")
        }) {
            return (try MLModel(contentsOf: match, configuration: config), match)
        }

        throw NSError(
            domain: "LaserMLDetectionService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No compiled model (.mlmodelc) found in app bundle. Ensure laser-pens.mlpackage is included in the app target."]
        )
    }

    private static func toTopLeftBoundingBox(_ visionBottomLeftBox: CGRect) -> CGRect {
        // Vision bounding boxes are normalized with origin at bottom-left.
        // Convert to normalized image coords with origin at top-left to match ARFrame.displayTransform.
        CGRect(
            x: visionBottomLeftBox.origin.x,
            y: 1.0 - visionBottomLeftBox.origin.y - visionBottomLeftBox.size.height,
            width: visionBottomLeftBox.size.width,
            height: visionBottomLeftBox.size.height
        )
    }

    private static func inferModelInputSize(from model: MLModel) -> CGSize? {
        // Prefer an ImageConstraint (fixed input size).
        for (_, input) in model.modelDescription.inputDescriptionsByName {
            if let constraint = input.imageConstraint {
                let w = CGFloat(constraint.pixelsWide)
                let h = CGFloat(constraint.pixelsHigh)
                if w > 0, h > 0 {
                    return CGSize(width: w, height: h)
                }
            }
        }
        return nil
    }

    private static func orientedImageSize(for pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CGSize {
        let w = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: h, height: w)
        default:
            return CGSize(width: w, height: h)
        }
    }

    private func decodeYOLOLikeDetections(
        from featureObservations: [VNCoreMLFeatureValueObservation],
        modelInputSize: CGSize?,
        orientedImageSize: CGSize,
        orientation: CGImagePropertyOrientation,
        cropAndScaleOption: VNImageCropAndScaleOption,
        confidenceThreshold: Float,
        maxDetections: Int
    ) -> [LaserMLDetection] {
        // The laser-pens model returns two output tensors (segmentation-style): protos + predictions.
        // We only need bounding boxes, so decode the prediction tensor.
        let arrays: [MLMultiArray] = featureObservations.compactMap { $0.featureValue.multiArrayValue }
        guard arrays.count >= 1 else { return [] }

        var pred: MLMultiArray? = nil
        if arrays.count >= 2 {
            // Heuristic: the prototype/mask tensor is 4D; predictions are 3D.
            let a0 = arrays[0]
            let a1 = arrays[1]
            pred = (a0.shape.count == 4) ? a1 : a0
        } else {
            pred = arrays[0]
        }
        guard let pred else { return [] }
        guard pred.dataType == .float32 else { return [] }
        guard pred.shape.count >= 3 else { return [] }

        // Expected layout (from Ultralytics iOS): [1, numFeatures, numAnchors]
        let numFeatures = pred.shape[1].intValue
        let numAnchors = pred.shape[2].intValue
        guard numAnchors > 0, numFeatures > 4 else { return [] }

        // Infer whether this is a segmentation head (mask coefficients present).
        let maskCoeffLen = (numFeatures >= (4 + 32 + 1)) ? 32 : 0
        let numClasses = max(1, numFeatures - 4 - maskCoeffLen)

        let inputSize = modelInputSize ?? CGSize(width: 640, height: 640)
        let inputW = inputSize.width
        let inputH = inputSize.height

        // Inverse mapping: model-input pixel coords -> oriented camera image pixel coords.
        // We only implement scaleFill precisely; for other modes we fall back to a simple normalization.
        let scale: CGFloat
        let xOffset: CGFloat
        let yOffset: CGFloat
        if cropAndScaleOption == .scaleFill {
            scale = max(inputW / orientedImageSize.width, inputH / orientedImageSize.height)
            let scaledW = orientedImageSize.width * scale
            let scaledH = orientedImageSize.height * scale
            xOffset = (scaledW - inputW) / 2.0
            yOffset = (scaledH - inputH) / 2.0
        } else {
            scale = 1.0
            xOffset = 0
            yOffset = 0
        }

        let ptr = pred.dataPointer.assumingMemoryBound(to: Float.self)

        struct Candidate {
            let rect: CGRect
            let classIndex: Int
            let score: Float
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(512, numAnchors))

        for j in 0..<numAnchors {
            let x = CGFloat(ptr[j])
            let y = CGFloat(ptr[numAnchors + j])
            let w = CGFloat(ptr[2 * numAnchors + j])
            let h = CGFloat(ptr[3 * numAnchors + j])

            var bestScore: Float = 0
            var bestClass: Int = 0

            let classBase = (4 * numAnchors) + j
            for c in 0..<numClasses {
                let score = ptr[classBase + (c * numAnchors)]
                if score > bestScore {
                    bestScore = score
                    bestClass = c
                }
            }
            guard bestScore >= confidenceThreshold else { continue }

            // Convert center-based xywh -> top-left xywh (model-input pixels).
            let boxX = x - w / 2.0
            let boxY = y - h / 2.0
            let modelRect = CGRect(x: boxX, y: boxY, width: w, height: h)

            // Map to oriented camera image pixels.
            let imgX: CGFloat
            let imgY: CGFloat
            let imgW: CGFloat
            let imgH: CGFloat
            if cropAndScaleOption == .scaleFill {
                imgX = (modelRect.origin.x + xOffset) / scale
                imgY = (modelRect.origin.y + yOffset) / scale
                imgW = modelRect.size.width / scale
                imgH = modelRect.size.height / scale
            } else {
                // Fallback: treat modelRect as already in image space.
                imgX = modelRect.origin.x
                imgY = modelRect.origin.y
                imgW = modelRect.size.width
                imgH = modelRect.size.height
            }

            let normRectOriented = CGRect(
                x: imgX / orientedImageSize.width,
                y: imgY / orientedImageSize.height,
                width: imgW / orientedImageSize.width,
                height: imgH / orientedImageSize.height
            )

            // Convert from the oriented/model coordinate system back into the raw ARFrame capturedImage
            // normalized coordinate system that ARFrame.displayTransform expects.
            let normRectRaw = Self.mapNormalizedRectFromOrientedToRaw(normRectOriented, orientation: orientation)

            candidates.append(Candidate(rect: normRectRaw, classIndex: bestClass, score: bestScore))
        }

        // No NMS for now (milestone is just: show bounding boxes). Keep the top results.
        let top = candidates.sorted(by: { $0.score > $1.score }).prefix(maxDetections)
        return top.map {
            let label: String
            if numClasses <= 1 {
                label = "laser"
            } else {
                label = "class \($0.classIndex)"
            }
            return LaserMLDetection(boundingBox: $0.rect, label: label, confidence: $0.score, timestamp: Date())
        }
    }

    private static func mapNormalizedPointFromOrientedToRaw(_ p: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        // Coordinates are normalized (0..1) with origin at top-left.
        // `orientation` is the orientation we told Vision to use when feeding the pixelBuffer into the model.
        // We need the inverse mapping: oriented/model space -> raw pixelBuffer space.
        switch orientation {
        case .up:
            return p
        case .down:
            return CGPoint(x: 1.0 - p.x, y: 1.0 - p.y)
        case .left:
            // Inverse of CCW rotation: (x,y) -> (1 - y, x)
            return CGPoint(x: 1.0 - p.y, y: p.x)
        case .right:
            // Inverse of CW rotation: (x,y) -> (y, 1 - x)
            return CGPoint(x: p.y, y: 1.0 - p.x)
        case .upMirrored:
            // Mirror horizontal in oriented space.
            return CGPoint(x: 1.0 - p.x, y: p.y)
        case .downMirrored:
            return CGPoint(x: p.x, y: 1.0 - p.y)
        case .leftMirrored:
            // Mirror+rotate variants; treat as left then mirror.
            let base = CGPoint(x: 1.0 - p.y, y: p.x)
            return CGPoint(x: 1.0 - base.x, y: base.y)
        case .rightMirrored:
            let base = CGPoint(x: p.y, y: 1.0 - p.x)
            return CGPoint(x: 1.0 - base.x, y: base.y)
        @unknown default:
            return p
        }
    }

    private static func mapNormalizedRectFromOrientedToRaw(_ rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        let p1 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.minX, y: rect.minY), orientation: orientation)
        let p2 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.maxX, y: rect.minY), orientation: orientation)
        let p3 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.minX, y: rect.maxY), orientation: orientation)
        let p4 = mapNormalizedPointFromOrientedToRaw(CGPoint(x: rect.maxX, y: rect.maxY), orientation: orientation)

        let xs = [p1.x, p2.x, p3.x, p4.x]
        let ys = [p1.y, p2.y, p3.y, p4.y]
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0

        // Clamp just in case the inverse crop mapping produces slight overshoot.
        let clampedMinX = max(0, min(1, minX))
        let clampedMinY = max(0, min(1, minY))
        let clampedMaxX = max(0, min(1, maxX))
        let clampedMaxY = max(0, min(1, maxY))

        return CGRect(x: clampedMinX, y: clampedMinY, width: max(0, clampedMaxX - clampedMinX), height: max(0, clampedMaxY - clampedMinY))
    }
}
