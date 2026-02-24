//
//  LaserMLDetectionService+Decode.swift
//  roboscope2
//
//  Decodes raw YOLO-like MLMultiArray tensor output into LaserMLDetection boxes.
//  Called from processPixelBuffer when Vision returns VNCoreMLFeatureValueObservation
//  (i.e. the model outputs raw tensors rather than VNRecognizedObjectObservation).
//

import Foundation
import CoreML
import Vision
import CoreGraphics
import QuartzCore
import ImageIO

extension LaserMLDetectionService {

    // Intermediate box candidate used during tensor decode + NMS.
    struct DecodeCandidate {
        let rect: CGRect
        let classIndex: Int
        let score: Float
        let orientedQuad: LaserMLOrientedQuad?
        let maskPoints: [CGPoint]?
    }

    func decodeYOLOLikeDetections(
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

        // If Vision ROI is enabled, the model sees only that cropped region.
        let roi = roiRectTopLeftNormalized
        let roiOrientedImageSize = CGSize(width: orientedImageSize.width * roi.width, height: orientedImageSize.height * roi.height)

        // Inverse mapping: model-input pixel coords -> oriented camera image pixel coords.
        let scale: CGFloat
        let xPadding: CGFloat
        let yPadding: CGFloat
        if cropAndScaleOption == .scaleFit || cropAndScaleOption == .centerCrop {
            scale = min(inputW / roiOrientedImageSize.width, inputH / roiOrientedImageSize.height)
            let scaledW = roiOrientedImageSize.width * scale
            let scaledH = roiOrientedImageSize.height * scale
            xPadding = (inputW - scaledW) / 2.0
            yPadding = (inputH - scaledH) / 2.0
        } else {
            scale = max(inputW / roiOrientedImageSize.width, inputH / roiOrientedImageSize.height)
            let scaledW = roiOrientedImageSize.width * scale
            let scaledH = roiOrientedImageSize.height * scale
            xPadding = (inputW - scaledW) / 2.0
            yPadding = (inputH - scaledH) / 2.0
        }

        let ptr = pred.dataPointer.assumingMemoryBound(to: Float.self)

        var candidates: [DecodeCandidate] = []
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
            let modelRect = CGRect(x: x - w / 2.0, y: y - h / 2.0, width: w, height: h)

            // Optional: mask coefficients (segmentation head).
            var maskCoeffs: [Float] = []
            if maskCoeffLen > 0 {
                maskCoeffs.reserveCapacity(maskCoeffLen)
                let coeffBase = ((4 + numClasses) * numAnchors) + j
                for k in 0..<maskCoeffLen {
                    maskCoeffs.append(ptr[coeffBase + (k * numAnchors)])
                }
            }

            // Map model-input pixels -> oriented camera image normalized coords.
            let imgX = (modelRect.origin.x - xPadding) / scale
            let imgY = (modelRect.origin.y - yPadding) / scale
            let imgW = modelRect.size.width / scale
            let imgH = modelRect.size.height / scale

            let normRectOrientedInROI = CGRect(
                x: imgX / roiOrientedImageSize.width,
                y: imgY / roiOrientedImageSize.height,
                width: imgW / roiOrientedImageSize.width,
                height: imgH / roiOrientedImageSize.height
            )
            let normRectOriented = CGRect(
                x: roi.minX + (normRectOrientedInROI.minX * roi.width),
                y: roi.minY + (normRectOrientedInROI.minY * roi.height),
                width: normRectOrientedInROI.width * roi.width,
                height: normRectOrientedInROI.height * roi.height
            )
            let normRectRaw = Self.mapNormalizedRectFromOrientedToRaw(normRectOriented, orientation: orientation)

            let orientedQuad: LaserMLOrientedQuad?
            let maskPoints: [CGPoint]?
            if let proto, maskCoeffLen > 0, maskCoeffs.count == maskCoeffLen,
               let seg = Self.computeOrientedQuadFromProtoMask(
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
               ) {
                orientedQuad = seg.quad
                maskPoints = seg.maskPoints
            } else {
                orientedQuad = nil
                maskPoints = nil
            }

            candidates.append(DecodeCandidate(rect: normRectRaw, classIndex: bestClass, score: bestScore, orientedQuad: orientedQuad, maskPoints: maskPoints))
        }

        // Per-class NMS: suppress overlapping boxes of the same class with IoU > threshold.
        let nmsThreshold: Float = 0.45
        let suppressed = Self.applyNMS(candidates: candidates, iouThreshold: nmsThreshold)
        let top = suppressed.sorted(by: { $0.score > $1.score }).prefix(maxDetections)
        return top.map {
            let label: String
            if numClasses <= 1 {
                label = "laser"
            } else {
                switch $0.classIndex {
                case 0: label = "dot"
                case 1: label = "line"
                default: label = "class \($0.classIndex)"
                }
            }
            return LaserMLDetection(
                boundingBox: $0.rect,
                orientedQuad: $0.orientedQuad,
                maskPoints: $0.maskPoints,
                classIndex: $0.classIndex,
                label: label,
                confidence: $0.score,
                timestamp: Date()
            )
        }
    }

    // MARK: - NMS helpers

    private static func applyNMS(
        candidates: [DecodeCandidate],
        iouThreshold: Float
    ) -> [DecodeCandidate] {
        // Group by class then apply greedy NMS within each group.
        let classes = Set(candidates.map { $0.classIndex })
        var kept: [DecodeCandidate] = []
        for cls in classes {
            let group = candidates.filter { $0.classIndex == cls }.sorted { $0.score > $1.score }
            var active = [Bool](repeating: true, count: group.count)
            for i in 0..<group.count {
                guard active[i] else { continue }
                kept.append(group[i])
                for j in (i+1)..<group.count {
                    guard active[j] else { continue }
                    if iou(group[i].rect, group[j].rect) > iouThreshold {
                        active[j] = false
                    }
                }
            }
        }
        return kept
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let ix = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let iy = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let inter = ix * iy
        guard inter > 0 else { return 0 }
        let union = a.width * a.height + b.width * b.height - inter
        guard union > 0 else { return 0 }
        return Float(inter / union)
    }
}
