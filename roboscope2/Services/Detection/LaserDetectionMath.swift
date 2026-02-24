//
//  LaserDetectionMath.swift
//  roboscope2
//
//  Shared detection math utilities used by both VideoDetectionView and
//  LaserGuideARSessionView.  Pure functions; no SwiftUI/UIKit dependencies.
//

import CoreGraphics

// MARK: - Pixel-correct size measurement

/// Returns the length (in display pixels) of the longest side of an axis-aligned bbox.
///
/// - `bbox`      : bounding box in raw-buffer-normalized coordinates (0..1, top-left origin)
/// - `transform` : affine transform from buffer space to view-normalised space
///                 (`ARFrame.displayTransform` for AR, or the orientation transform for video)
/// - `viewport`  : size of the rendered view in points / pixels
///
/// For a transform with components (a,b,c,d):
///   view_x_extent_normalised = |a|·w + |c|·h
///   view_y_extent_normalised = |b|·w + |d|·h
func laserDetectionLongestSidePixels(
    _ bbox: CGRect,
    transform t: CGAffineTransform,
    viewport: CGSize
) -> Float {
    let vxNorm = abs(t.a) * bbox.width + abs(t.c) * bbox.height
    let vyNorm = abs(t.b) * bbox.width + abs(t.d) * bbox.height
    return Float(max(vxNorm * viewport.width, vyNorm * viewport.height))
}

// MARK: - Multi-frame accumulator merge

/// Merges detections from multiple frames into a unified set.
/// Boxes of the same class that overlap (or are within a 10% gap) are union-merged into one box,
/// taking the highest-confidence detection's metadata.
func laserDetectionMergeFrames(
    _ frames: [[LaserMLDetection]]
) -> [LaserMLDetection] {
    let all = frames.flatMap { $0 }
    guard !all.isEmpty else { return [] }
    let dots   = laserDetectionUnionMerge(all.filter { $0.classIndex == 0 || $0.label.lowercased().contains("dot") })
    let lines  = laserDetectionUnionMerge(all.filter { $0.classIndex == 1 || $0.label.lowercased().contains("line") })
    let others = laserDetectionUnionMerge(all.filter {
        guard let idx = $0.classIndex else { return false }
        return idx > 1
    })
    return dots + lines + others
}

/// Greedy cluster-then-transitive-closure union merge for one class of detections.
func laserDetectionUnionMerge(
    _ detections: [LaserMLDetection]
) -> [LaserMLDetection] {
    guard !detections.isEmpty else { return [] }

    // Phase 1 — greedy seed clustering on direct bbox intersection.
    var clusters: [[LaserMLDetection]] = []
    for det in detections {
        if let (idx, _) = clusters.enumerated().first(where: { (_, cluster) in
            cluster.contains(where: { $0.boundingBox.intersects(det.boundingBox) })
        }) {
            clusters[idx].append(det)
        } else {
            clusters.append([det])
        }
    }

    // Phase 2 — transitive closure: merge clusters whose union boxes are within
    // 10% of the longer box's longest side of each other (handles gapped segments).
    var changed = true
    while changed {
        changed = false
        var merged: [[LaserMLDetection]] = []
        var used = [Bool](repeating: false, count: clusters.count)
        for i in clusters.indices {
            guard !used[i] else { continue }
            var group = clusters[i]
            var box = group.reduce(group[0].boundingBox) { $0.union($1.boundingBox) }
            for j in (i + 1)..<clusters.count {
                guard !used[j] else { continue }
                let other = clusters[j].reduce(clusters[j][0].boundingBox) {
                    $0.union($1.boundingBox)
                }
                let longestSide = max(
                    max(box.width, box.height),
                    max(other.width, other.height)
                )
                let tol = longestSide * 0.10
                let expanded = box.insetBy(dx: -tol, dy: -tol)
                if expanded.intersects(other) {
                    group += clusters[j]
                    box = box.union(other)
                    used[j] = true
                    changed = true
                }
            }
            merged.append(group)
            used[i] = true
        }
        clusters = merged
    }

    return clusters.compactMap { cluster -> LaserMLDetection? in
        guard let best = cluster.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let unionBox = cluster.dropFirst().reduce(cluster[0].boundingBox) { $0.union($1.boundingBox) }
        // Pool all mask points from the cluster and refit an oriented quad via PCA.
        let pooled = cluster.compactMap { $0.maskPoints }.flatMap { $0 }
        let quad = pooled.count >= 8 ? orientedQuadFromMaskPoints(pooled) : nil
        return LaserMLDetection(
            boundingBox: unionBox,
            orientedQuad: quad,
            maskPoints: pooled.isEmpty ? nil : pooled,
            classIndex: best.classIndex,
            label: best.label,
            confidence: best.confidence,
            timestamp: best.timestamp
        )
    }
}

// MARK: - Oriented quad fitting

/// Fits an oriented bounding quad to a cloud of points in normalised image coordinates
/// using PCA on the point covariance matrix. Used by the accumulator to produce
/// shape-aligned boxes for merged multi-frame clusters.
func orientedQuadFromMaskPoints(_ points: [CGPoint]) -> LaserMLOrientedQuad? {
    guard points.count >= 4 else { return nil }
    var sumX: Double = 0, sumY: Double = 0
    for p in points { sumX += Double(p.x); sumY += Double(p.y) }
    let n = Double(points.count)
    let meanX = sumX / n
    let meanY = sumY / n
    var covXX: Double = 0, covYY: Double = 0, covXY: Double = 0
    for p in points {
        let dx = Double(p.x) - meanX
        let dy = Double(p.y) - meanY
        covXX += dx * dx; covYY += dy * dy; covXY += dx * dy
    }
    covXX /= n; covYY /= n; covXY /= n
    let theta = 0.5 * atan2(2.0 * covXY, covXX - covYY)
    let cosT = cos(theta), sinT = sin(theta)
    var minU = Double.greatestFiniteMagnitude, maxU = -Double.greatestFiniteMagnitude
    var minV = Double.greatestFiniteMagnitude, maxV = -Double.greatestFiniteMagnitude
    for p in points {
        let dx = Double(p.x) - meanX
        let dy = Double(p.y) - meanY
        let u =  dx * cosT + dy * sinT
        let v = -dx * sinT + dy * cosT
        if u < minU { minU = u }; if u > maxU { maxU = u }
        if v < minV { minV = v }; if v > maxV { maxV = v }
    }
    func corner(u: Double, v: Double) -> CGPoint {
        CGPoint(x: meanX + u * cosT - v * sinT,
                y: meanY + u * sinT + v * cosT)
    }
    return LaserMLOrientedQuad(
        p1: corner(u: minU, v: minV),
        p2: corner(u: maxU, v: minV),
        p3: corner(u: maxU, v: maxV),
        p4: corner(u: minU, v: maxV)
    )
}
