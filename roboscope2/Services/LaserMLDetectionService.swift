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

struct LaserMLOrientedQuad: Equatable {
    /// Points are in normalized image coordinates (0..1) with origin at top-left.
    /// Order is clockwise starting from top-left-ish corner (not guaranteed perfectly).
    let p1: CGPoint
    let p2: CGPoint
    let p3: CGPoint
    let p4: CGPoint
}

struct LaserMLDetection: Identifiable, Equatable {
    let id = UUID()
    /// Bounding box in normalized image coordinates (0..1), origin at top-left.
    let boundingBox: CGRect
    /// Optional rotated quad in normalized image coordinates.
    let orientedQuad: LaserMLOrientedQuad?
    let label: String
    let confidence: Float
    let timestamp: Date

    init(
        boundingBox: CGRect,
        orientedQuad: LaserMLOrientedQuad? = nil,
        label: String,
        confidence: Float,
        timestamp: Date
    ) {
        self.boundingBox = boundingBox
        self.orientedQuad = orientedQuad
        self.label = label
        self.confidence = confidence
        self.timestamp = timestamp
    }
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
            // YOLO models are typically trained with letterbox (scaleFit) preprocessing.
            // Using scaleFit ensures the inverse coordinate mapping matches training.
            request.imageCropAndScaleOption = .scaleFit
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
                // Keep an equivalent top-left normalized rect for mapping decoded tensor outputs.
                let roiRectTopLeft: CGRect
                if useROI {
                    let size = CGFloat(roiSize)
                    let x = (1.0 - size) / 2.0
                    let yTopLeft = (1.0 - size) / 2.0
                    let yBottomLeft = 1.0 - yTopLeft - size
                    request.regionOfInterest = CGRect(x: x, y: yBottomLeft, width: size, height: size)

                    // Convert bottom-left coords to top-left coords.
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
                            orientedQuad: nil,
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
        roiRectTopLeftNormalized: CGRect,
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
        var proto: MLMultiArray? = nil
        if arrays.count >= 2 {
            // Heuristic: the prototype/mask tensor is 4D; predictions are 3D.
            let a0 = arrays[0]
            let a1 = arrays[1]
            if a0.shape.count == 4 {
                proto = a0
                pred = a1
            } else if a1.shape.count == 4 {
                proto = a1
                pred = a0
            } else {
                pred = a0
            }
        } else {
            pred = arrays[0]
        }
        guard let pred else { return [] }
        guard pred.dataType == .float32 else { return [] }
        guard pred.shape.count >= 3 else { return [] }

        let now = CACurrentMediaTime()
        if now - lastStatsLogTime >= 1.5 {
            // Light-touch shape log (piggy-backs on stats cadence).
            if let proto {
                log("Decode tensors: pred.shape=\(pred.shape) proto.shape=\(proto.shape)")
            } else {
                log("Decode tensors: pred.shape=\(pred.shape) proto=none")
            }
        }

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

        // If Vision ROI is enabled, the model sees only that cropped region. We must interpret tensor
        // coordinates in ROI space, then map back into full oriented-image normalized coordinates.
        let roi = roiRectTopLeftNormalized
        let roiOrientedImageSize = CGSize(width: orientedImageSize.width * roi.width, height: orientedImageSize.height * roi.height)

        // Inverse mapping: model-input pixel coords -> oriented camera image pixel coords.
        // scaleFit (letterbox): image is scaled to fit, padding is added.
        // scaleFill: image is scaled to fill, excess is cropped.
        let scale: CGFloat
        let xPadding: CGFloat  // padding added to reach model input size
        let yPadding: CGFloat
        if cropAndScaleOption == .scaleFit || cropAndScaleOption == .centerCrop {
            // Letterbox: scale = min so image fits inside model input; remaining space is padded.
            scale = min(inputW / roiOrientedImageSize.width, inputH / roiOrientedImageSize.height)
            let scaledW = roiOrientedImageSize.width * scale
            let scaledH = roiOrientedImageSize.height * scale
            xPadding = (inputW - scaledW) / 2.0
            yPadding = (inputH - scaledH) / 2.0
        } else {
            // scaleFill: scale = max so image fills model input; excess is cropped.
            scale = max(inputW / roiOrientedImageSize.width, inputH / roiOrientedImageSize.height)
            let scaledW = roiOrientedImageSize.width * scale
            let scaledH = roiOrientedImageSize.height * scale
            // For scaleFill, "padding" is negative (represents crop offset).
            xPadding = (inputW - scaledW) / 2.0
            yPadding = (inputH - scaledH) / 2.0
        }

        let ptr = pred.dataPointer.assumingMemoryBound(to: Float.self)

        struct Candidate {
            let rect: CGRect
            let classIndex: Int
            let score: Float
            let orientedQuad: LaserMLOrientedQuad?
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

            // Optional: mask coefficients (if this is a segmentation head).
            var maskCoeffs: [Float] = []
            if maskCoeffLen > 0 {
                maskCoeffs.reserveCapacity(maskCoeffLen)
                let coeffBase = ((4 + numClasses) * numAnchors) + j
                for k in 0..<maskCoeffLen {
                    maskCoeffs.append(ptr[coeffBase + (k * numAnchors)])
                }
            }

            // Map to oriented camera image pixels.
            // For letterbox: subtract padding, then divide by scale.
            // For scaleFill: subtract (negative) padding = add crop offset, then divide by scale.
            let imgX = (modelRect.origin.x - xPadding) / scale
            let imgY = (modelRect.origin.y - yPadding) / scale
            let imgW = modelRect.size.width / scale
            let imgH = modelRect.size.height / scale

            // Normalized within ROI-oriented image.
            let normRectOrientedInROI = CGRect(
                x: imgX / roiOrientedImageSize.width,
                y: imgY / roiOrientedImageSize.height,
                width: imgW / roiOrientedImageSize.width,
                height: imgH / roiOrientedImageSize.height
            )

            // Map ROI-normalized -> full oriented-image normalized (top-left origin).
            let normRectOriented = CGRect(
                x: roi.minX + (normRectOrientedInROI.minX * roi.width),
                y: roi.minY + (normRectOrientedInROI.minY * roi.height),
                width: normRectOrientedInROI.width * roi.width,
                height: normRectOrientedInROI.height * roi.height
            )

            // Convert from the oriented/model coordinate system back into the raw ARFrame capturedImage
            // normalized coordinate system that ARFrame.displayTransform expects.
            let normRectRaw = Self.mapNormalizedRectFromOrientedToRaw(normRectOriented, orientation: orientation)

            let orientedQuad: LaserMLOrientedQuad?
            if let proto, maskCoeffLen > 0, maskCoeffs.count == maskCoeffLen {
                orientedQuad = Self.computeOrientedQuadFromProtoMask(
                    proto: proto,
                    maskCoefficients: maskCoeffs,
                    modelRect: modelRect,
                    inputSize: inputSize,
                    orientedImageSize: roiOrientedImageSize,
                    roiRectTopLeftNormalized: roi,
                    orientation: orientation,
                    cropAndScaleOption: cropAndScaleOption,
                    scale: scale,
                    xPadding: xPadding,
                    yPadding: yPadding
                )
            } else {
                orientedQuad = nil
            }

            candidates.append(Candidate(rect: normRectRaw, classIndex: bestClass, score: bestScore, orientedQuad: orientedQuad))
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
            return LaserMLDetection(boundingBox: $0.rect, orientedQuad: $0.orientedQuad, label: label, confidence: $0.score, timestamp: Date())
        }
    }

    private static func computeOrientedQuadFromProtoMask(
        proto: MLMultiArray,
        maskCoefficients: [Float],
        modelRect: CGRect,
        inputSize: CGSize,
        orientedImageSize: CGSize,
        roiRectTopLeftNormalized: CGRect,
        orientation: CGImagePropertyOrientation,
        cropAndScaleOption: VNImageCropAndScaleOption,
        scale: CGFloat,
        xPadding: CGFloat,
        yPadding: CGFloat
    ) -> LaserMLOrientedQuad? {
        guard proto.dataType == .float32 else { return nil }
        guard proto.shape.count == 4 else { return nil }
        guard maskCoefficients.count > 0 else { return nil }

        // Determine proto layout. Common layouts:
        // - [1, C, H, W] (channels-first)
        // - [1, H, W, C] (channels-last)
        let s = proto.shape.map { $0.intValue }
        let cFirst = (s.count == 4) ? s[1] : 0
        let cLast = (s.count == 4) ? s[3] : 0

        enum ProtoLayout { case chw, hwc }
        let layout: ProtoLayout
        let channels: Int
        let height: Int
        let width: Int
        if cFirst == maskCoefficients.count {
            layout = .chw
            channels = cFirst
            height = s[2]
            width = s[3]
        } else if cLast == maskCoefficients.count {
            layout = .hwc
            channels = cLast
            height = s[1]
            width = s[2]
        } else {
            return nil
        }
        guard channels == maskCoefficients.count, width > 0, height > 0 else { return nil }

        // Work in proto coordinates for speed.
        // Map the detection box (model-input pixels) into proto pixel indices.
        let x0f = (modelRect.minX / inputSize.width) * CGFloat(width)
        let x1f = (modelRect.maxX / inputSize.width) * CGFloat(width)
        let y0f = (modelRect.minY / inputSize.height) * CGFloat(height)
        let y1f = (modelRect.maxY / inputSize.height) * CGFloat(height)

        let x0 = max(0, min(width - 1, Int(floor(x0f))))
        let x1 = max(0, min(width - 1, Int(ceil(x1f))))
        let y0 = max(0, min(height - 1, Int(floor(y0f))))
        let y1 = max(0, min(height - 1, Int(ceil(y1f))))
        if x1 <= x0 || y1 <= y0 { return nil }

        // Downsample to keep per-frame cost bounded.
        let sampleStep = max(1, Int(sqrt(Double((x1 - x0) * (y1 - y0))) / 32.0))

        let ptr = proto.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = proto.strides.map { $0.intValue }

        @inline(__always)
        func idx(_ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int) -> Int {
            i0 * strides[0] + i1 * strides[1] + i2 * strides[2] + i3 * strides[3]
        }

        func protoAt(c: Int, y: Int, x: Int) -> Float {
            switch layout {
            case .chw:
                return ptr[idx(0, c, y, x)]
            case .hwc:
                return ptr[idx(0, y, x, c)]
            }
        }

        @inline(__always)
        func sigmoid(_ v: Float) -> Float {
            1.0 / (1.0 + exp(-v))
        }

        // Collect mask points and compute principal axis via covariance.
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXX: Double = 0
        var sumYY: Double = 0
        var sumXY: Double = 0
        var count: Double = 0

        // Also keep sparse points for min/max projections.
        var points: [CGPoint] = []
        points.reserveCapacity(512)

        for yy in Swift.stride(from: y0, through: y1, by: sampleStep) {
            for xx in Swift.stride(from: x0, through: x1, by: sampleStep) {
                var dot: Float = 0
                for c in 0..<channels {
                    dot += protoAt(c: c, y: yy, x: xx) * maskCoefficients[c]
                }
                let p = sigmoid(dot)
                guard p >= 0.5 else { continue }
                let fx = Double(xx) + 0.5
                let fy = Double(yy) + 0.5
                sumX += fx
                sumY += fy
                sumXX += fx * fx
                sumYY += fy * fy
                sumXY += fx * fy
                count += 1
                if points.count < 2000 {
                    points.append(CGPoint(x: fx, y: fy))
                }
            }
        }

        guard count >= 10, points.count >= 10 else { return nil }

        let meanX = sumX / count
        let meanY = sumY / count
        let covXX = max(0.0, (sumXX / count) - meanX * meanX)
        let covYY = max(0.0, (sumYY / count) - meanY * meanY)
        let covXY = (sumXY / count) - meanX * meanY

        // Principal axis angle (in proto pixel coords; x right, y down).
        let theta = 0.5 * atan2(2.0 * covXY, covXX - covYY)
        let cosT = cos(theta)
        let sinT = sin(theta)

        // Project points onto principal axes.
        var minU = Double.greatestFiniteMagnitude
        var maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude
        var maxV = -Double.greatestFiniteMagnitude

        for p in points {
            let dx = Double(p.x) - meanX
            let dy = Double(p.y) - meanY
            let u = dx * cosT + dy * sinT
            let v = -dx * sinT + dy * cosT
            minU = min(minU, u)
            maxU = max(maxU, u)
            minV = min(minV, v)
            maxV = max(maxV, v)
        }

        let u0 = minU
        let u1 = maxU
        let v0 = minV
        let v1 = maxV

        func protoPoint(u: Double, v: Double) -> CGPoint {
            // Convert (u,v) back to proto pixel coords.
            let x = meanX + u * cosT - v * sinT
            let y = meanY + u * sinT + v * cosT
            return CGPoint(x: x, y: y)
        }

        // Corners in proto pixels.
        let c1 = protoPoint(u: u0, v: v0)
        let c2 = protoPoint(u: u1, v: v0)
        let c3 = protoPoint(u: u1, v: v1)
        let c4 = protoPoint(u: u0, v: v1)

        // Map proto pixels -> model-input pixels.
        func toModel(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: (p.x / CGFloat(width)) * inputSize.width,
                y: (p.y / CGFloat(height)) * inputSize.height
            )
        }

        let m1 = toModel(c1)
        let m2 = toModel(c2)
        let m3 = toModel(c3)
        let m4 = toModel(c4)

        // Map model-input pixels -> oriented camera image normalized coords.
        // Subtract padding (positive for letterbox, negative for scaleFill) then divide by scale.
        func modelToOrientedNorm(_ p: CGPoint) -> CGPoint {
            let imgX = (p.x - xPadding) / scale
            let imgY = (p.y - yPadding) / scale
            return CGPoint(x: imgX / orientedImageSize.width, y: imgY / orientedImageSize.height)
        }

        let o1 = modelToOrientedNorm(m1)
        let o2 = modelToOrientedNorm(m2)
        let o3 = modelToOrientedNorm(m3)
        let o4 = modelToOrientedNorm(m4)

        // If ROI is enabled, points are normalized within ROI; expand to full oriented-image normalized coords.
        let roi = roiRectTopLeftNormalized
        func roiToFull(_ p: CGPoint) -> CGPoint {
            CGPoint(x: roi.minX + (p.x * roi.width), y: roi.minY + (p.y * roi.height))
        }

        let f1 = roiToFull(o1)
        let f2 = roiToFull(o2)
        let f3 = roiToFull(o3)
        let f4 = roiToFull(o4)

        // Convert oriented -> raw normalized coords.
        let r1 = mapNormalizedPointFromOrientedToRaw(f1, orientation: orientation)
        let r2 = mapNormalizedPointFromOrientedToRaw(f2, orientation: orientation)
        let r3 = mapNormalizedPointFromOrientedToRaw(f3, orientation: orientation)
        let r4 = mapNormalizedPointFromOrientedToRaw(f4, orientation: orientation)

        return LaserMLOrientedQuad(p1: r1, p2: r2, p3: r3, p4: r4)
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
