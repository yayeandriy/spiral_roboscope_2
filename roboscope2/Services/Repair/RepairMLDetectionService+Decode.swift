//
//  RepairMLDetectionService+Decode.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied from Services/Detection/LaserMLDetectionService+Decode.swift (READ-ONLY reference)
//  per 05-ios-repair.md §5.2. Decodes raw YOLO-like MLMultiArray tensor output into
//  RepairDetection boxes. The proto-mask / oriented-quad path is DROPPED (Repair places
//  single-point pins, not quads) — this only decodes bounding boxes + per-class scores.
//

import Foundation
import CoreML
import Vision
import CoreGraphics
import QuartzCore
import ImageIO

extension RepairMLDetectionService {

    // Intermediate box candidate used during tensor decode + NMS.
    struct DecodeCandidate {
        let rect: CGRect
        let classIndex: Int
        let score: Float
        /// Center-based (cx, cy, w, h) in MODEL-INPUT PIXEL space, kept alongside `rect` (which
        /// is already remapped into raw-buffer normalized space) because mask-polygon extraction
        /// needs to crop/scan the proto tensor in the model's own pixel grid, not the final
        /// remapped space.
        let modelCenterRect: (cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat)?
        /// The 32 mask coefficients for this anchor (YOLOv8-segmentation only), combined with the
        /// proto tensor post-NMS to extract `RepairDetection.maskPolygon`. nil for detect-only
        /// models or anchors we didn't bother extracting for (see `maskCoeffCount` gate below).
        let maskCoeffs: [Float]?
    }

    func decodeYOLOLikeDetections(
        from featureObservations: [VNCoreMLFeatureValueObservation],
        modelInputSize: CGSize?,
        orientedImageSize: CGSize,
        roiRectTopLeftNormalized: CGRect,
        orientation: CGImagePropertyOrientation,
        cropAndScaleOption: VNImageCropAndScaleOption,
        confidenceThreshold: Float,
        maxDetections: Int,
        classLabels: [String]
    ) -> [RepairDetection] {
        // The model may return one or more output tensors; predictions are the one with
        // shape [1, numFeatures, numAnchors] (Ultralytics-style export). If a segmentation
        // proto tensor (4D) is also present, we simply ignore it — Repair has no mask use.
        let arrays: [MLMultiArray] = featureObservations.compactMap { $0.featureValue.multiArrayValue }
        guard !arrays.isEmpty else { return [] }

        let pred: MLMultiArray? = arrays.first(where: { $0.shape.count == 3 }) ?? arrays.first
        guard let pred else { return [] }
        guard pred.dataType == .float32 else { return [] }
        guard pred.shape.count >= 3 else { return [] }

        // Expected layout (from Ultralytics iOS): [1, numFeatures, numAnchors]
        let numFeatures = pred.shape[1].intValue
        let numAnchors = pred.shape[2].intValue
        guard numAnchors > 0, numFeatures > 4 else { return [] }

        // Class count MUST come from the model's registered class_labels metadata, not from
        // the raw tensor width. A YOLOv8-SEGMENTATION export (e.g. "chips1") appends 32 extra
        // mask-coefficient channels after the per-class scores: [4 bbox, numClasses scores,
        // 32 mask coeffs]. Those coefficients are unconstrained (not sigmoid-bounded like a
        // real class score) and can exceed any real class's confidence, so deriving numClasses
        // as numFeatures-4 silently treats them as bogus extra "classes" and corrupts/starves
        // every real detection's argmax. Falls back to numFeatures-4 only if the class_labels
        // metadata looks unusable (empty or larger than the tensor could actually hold).
        let numClasses: Int
        if !classLabels.isEmpty, classLabels.count <= numFeatures - 4 {
            numClasses = classLabels.count
        } else {
            numClasses = max(1, numFeatures - 4)
        }

        // A YOLOv8-SEGMENTATION export appends exactly 32 mask-coefficient channels after the
        // per-class scores. When present (and a matching [1, 32, H, W] proto tensor is also in
        // this frame's outputs), we can reconstruct a per-detection mask polygon — see
        // `extractMaskPolygon` below, ported from class-balance-ios's live YOLO overlay (that
        // app is READ-ONLY reference here; this decoder is roboscope2's own).
        let maskCoeffCount = max(0, numFeatures - 4 - numClasses)
        let protoTensor: MLMultiArray? = maskCoeffCount == 32
            ? arrays.first(where: { $0.shape.count == 4 && $0.shape[1].intValue == 32 })
            : nil

        let now = CACurrentMediaTime()
        if now - lastStatsLogTime >= 1.5 {
            log("Decode tensors: pred.shape=\(pred.shape) classLabels=\(classLabels) numClasses=\(numClasses) maskCoeffChannels=\(maskCoeffCount) protoTensor=\(protoTensor?.shape.map { $0.intValue } ?? [])")
        }

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
        } else {
            scale = max(inputW / roiOrientedImageSize.width, inputH / roiOrientedImageSize.height)
        }
        let scaledW = roiOrientedImageSize.width * scale
        let scaledH = roiOrientedImageSize.height * scale
        xPadding = (inputW - scaledW) / 2.0
        yPadding = (inputH - scaledH) / 2.0

        // Use the array's actual strides rather than assuming a tightly-packed
        // [numFeatures, numAnchors] layout — matches the known-good sister-app decoder and
        // is robust to any non-default memory layout CoreML may hand back.
        let featureStride = pred.strides[1].intValue
        let anchorStride = pred.strides[2].intValue
        let ptr = pred.dataPointer.assumingMemoryBound(to: Float.self)

        // Maps a single point in MODEL-INPUT PIXEL space (the same space `x,y,w,h` above are
        // in) through the exact same padding/scale -> ROI -> orientation chain used for the
        // bbox above, landing in the same raw-buffer normalized (top-left origin) space as
        // `RepairDetection.boundingBox`. Used by `extractMaskPolygon` to place each polygon
        // point in agreement with its detection's own box.
        func mapModelPixelPointToRawNormalized(_ mx: CGFloat, _ my: CGFloat) -> CGPoint {
            let imgX = (mx - xPadding) / scale
            let imgY = (my - yPadding) / scale
            let normXInROI = imgX / roiOrientedImageSize.width
            let normYInROI = imgY / roiOrientedImageSize.height
            let normOriented = CGPoint(
                x: roi.minX + normXInROI * roi.width,
                y: roi.minY + normYInROI * roi.height
            )
            return Self.mapNormalizedPointFromOrientedToRaw(normOriented, orientation: orientation)
        }

        var candidates: [DecodeCandidate] = []
        candidates.reserveCapacity(min(512, numAnchors))

        for j in 0..<numAnchors {
            let x = CGFloat(ptr[0 * featureStride + j * anchorStride])
            let y = CGFloat(ptr[1 * featureStride + j * anchorStride])
            let w = CGFloat(ptr[2 * featureStride + j * anchorStride])
            let h = CGFloat(ptr[3 * featureStride + j * anchorStride])

            var bestScore: Float = 0
            var bestClass: Int = 0
            for c in 0..<numClasses {
                let score = ptr[(4 + c) * featureStride + j * anchorStride]
                if score > bestScore {
                    bestScore = score
                    bestClass = c
                }
            }
            guard bestScore >= confidenceThreshold else { continue }

            // Convert center-based xywh -> top-left xywh (model-input pixels).
            let modelRect = CGRect(x: x - w / 2.0, y: y - h / 2.0, width: w, height: h)

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

            var maskCoeffs: [Float]? = nil
            if protoTensor != nil {
                maskCoeffs = (0..<32).map { k in ptr[(4 + numClasses + k) * featureStride + j * anchorStride] }
            }

            candidates.append(DecodeCandidate(
                rect: normRectRaw,
                classIndex: bestClass,
                score: bestScore,
                modelCenterRect: (cx: x, cy: y, w: w, h: h),
                maskCoeffs: maskCoeffs
            ))
        }

        // Per-class NMS: suppress overlapping boxes of the same class with IoU > threshold.
        let nmsThreshold: Float = 0.45
        let suppressed = Self.applyNMS(candidates: candidates, iouThreshold: nmsThreshold)
        let top = suppressed.sorted(by: { $0.score > $1.score }).prefix(maxDetections)
        return top.map { candidate in
            let label: String
            if candidate.classIndex < classLabels.count {
                label = classLabels[candidate.classIndex]
            } else {
                label = classLabels.first ?? "object"
            }

            var polygon: [CGPoint]? = nil
            if let proto = protoTensor, let coeffs = candidate.maskCoeffs, let modelCenterRect = candidate.modelCenterRect {
                polygon = Self.extractMaskPolygon(
                    coefficients: coeffs,
                    prototypes: proto,
                    modelCenterRect: modelCenterRect,
                    modelInputSize: inputSize,
                    mapModelPixelPoint: mapModelPixelPointToRawNormalized
                )
            }

            return RepairDetection(
                boundingBox: candidate.rect,
                classIndex: candidate.classIndex,
                label: label,
                confidence: candidate.score,
                timestamp: Date(),
                maskPolygon: polygon
            )
        }
    }

    // MARK: - Segmentation mask -> polygon (YOLOv8-seg only)

    /// Reconstructs a rough polygon contour for one detection from its 32 mask coefficients and
    /// the model's shared prototype tensor ([1, 32, protoH, protoW]) — a per-row left/right edge
    /// scan over the bbox's crop of the proto grid, thresholded at `sum > 0` (pre-sigmoid logit
    /// space). Ported (algorithm only — this file, not class-balance-ios, owns the code) from
    /// class-balance-ios's `YOLODetectionService.extractMaskPolygon` (READ-ONLY reference), which
    /// uses the same technique for its live segmentation overlay. Deliberately NOT a full
    /// upsample + Vision/vImage contour trace — this is CPU-cheap enough to run every frame for
    /// a handful of post-NMS detections (rows downsampled to ≤ ~40).
    ///
    /// `mapModelPixelPoint` places each polygon point in the SAME normalized raw-buffer space as
    /// `boundingBox`, so the two always agree regardless of ROI cropping/device orientation.
    private static func extractMaskPolygon(
        coefficients: [Float],
        prototypes: MLMultiArray,
        modelCenterRect: (cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat),
        modelInputSize: CGSize,
        mapModelPixelPoint: (CGFloat, CGFloat) -> CGPoint
    ) -> [CGPoint]? {
        guard prototypes.dataType == .float32, prototypes.shape.count == 4 else { return nil }
        let protoH = prototypes.shape[2].intValue
        let protoW = prototypes.shape[3].intValue
        guard protoH > 0, protoW > 0 else { return nil }
        let cStride = prototypes.strides[1].intValue
        let yStride = prototypes.strides[2].intValue
        let xStride = prototypes.strides[3].intValue
        let protoPtr = prototypes.dataPointer.assumingMemoryBound(to: Float.self)

        // Proto grid is coarser than the model's own input resolution by a fixed per-axis
        // stride (typically 4 for YOLOv8-seg, e.g. 640 input -> 160x160 proto) — derived from
        // the actual shapes rather than hardcoded, matching class-balance-ios's approach, so
        // this stays correct even if a future export uses a different ratio.
        let strideX = modelInputSize.width / CGFloat(protoW)
        let strideY = modelInputSize.height / CGFloat(protoH)
        guard strideX > 0, strideY > 0 else { return nil }

        let px1 = max(0, Int(floor((modelCenterRect.cx - modelCenterRect.w / 2) / strideX)))
        let py1 = max(0, Int(floor((modelCenterRect.cy - modelCenterRect.h / 2) / strideY)))
        let px2 = min(protoW - 1, Int(ceil((modelCenterRect.cx + modelCenterRect.w / 2) / strideX)))
        let py2 = min(protoH - 1, Int(ceil((modelCenterRect.cy + modelCenterRect.h / 2) / strideY)))
        guard px2 > px1, py2 > py1 else { return nil }

        let cropH = py2 - py1 + 1
        let rowStep = max(1, cropH / 40)

        var leftEdge: [(CGFloat, CGFloat)] = []
        var rightEdge: [(CGFloat, CGFloat)] = []

        var y = py1
        while y <= py2 {
            var leftX: Int? = nil
            var rightX: Int? = nil
            for x in px1...px2 {
                var sum: Float = 0
                for k in 0..<32 {
                    sum += coefficients[k] * protoPtr[k * cStride + y * yStride + x * xStride]
                }
                if sum > 0 {
                    if leftX == nil { leftX = x }
                    rightX = x
                }
            }
            if let lx = leftX, let rx = rightX {
                let modelX0 = CGFloat(lx) * strideX
                let modelX1 = CGFloat(rx + 1) * strideX
                let modelY = CGFloat(y) * strideY + strideY / 2
                leftEdge.append((modelX0, modelY))
                rightEdge.append((modelX1, modelY))
            }
            y += rowStep
        }

        guard !leftEdge.isEmpty else { return nil }

        var polygon: [CGPoint] = []
        for (mx, my) in leftEdge {
            polygon.append(mapModelPixelPoint(mx, my))
        }
        for (mx, my) in rightEdge.reversed() {
            polygon.append(mapModelPixelPoint(mx, my))
        }
        return polygon.count >= 3 ? polygon : nil
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
