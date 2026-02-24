//
//  LaserMLDetectionService+Segmentation.swift
//  roboscope2
//
//  Computes an oriented bounding quad from a prototype mask (segmentation head).
//  Called from decodeYOLOLikeDetections when the model outputs mask coefficients.
//

import Foundation
import CoreML
import Vision
import CoreGraphics
import ImageIO

extension LaserMLDetectionService {

    static func computeOrientedQuadFromProtoMask(
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
    ) -> (quad: LaserMLOrientedQuad, maskPoints: [CGPoint])? {
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

        let quad = LaserMLOrientedQuad(p1: r1, p2: r2, p3: r3, p4: r4)

        // Subsample mask points (proto pixel coords) → raw normalized image coords.
        // Cap at 128 points for the accumulator to stay cheap.
        let sampleEvery = max(1, points.count / 128)
        let rawMaskPoints: [CGPoint] = Swift.stride(from: 0, to: points.count, by: sampleEvery).map { i in
            let pt = points[i]
            let mx = (pt.x / CGFloat(width)) * inputSize.width
            let my = (pt.y / CGFloat(height)) * inputSize.height
            let imgX = (mx - xPadding) / scale
            let imgY = (my - yPadding) / scale
            let orientedInROI = CGPoint(x: imgX / orientedImageSize.width, y: imgY / orientedImageSize.height)
            let fullOriented = CGPoint(
                x: roi.minX + orientedInROI.x * roi.width,
                y: roi.minY + orientedInROI.y * roi.height
            )
            return Self.mapNormalizedPointFromOrientedToRaw(fullOriented, orientation: orientation)
        }

        return (quad: quad, maskPoints: rawMaskPoints)
    }
}
