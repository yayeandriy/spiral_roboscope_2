//
//  RepairDetectionMath.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied from Services/Detection/LaserDetectionMath.swift (READ-ONLY reference) per
//  05-ios-repair.md §5.2. Keeps the union-merge / clustering (bbox `intersects` + 10% gap
//  tolerance) machinery, but made CLASS-AGNOSTIC (Laser's version special-cased "dot"/"line"
//  classIndex 0/1; Repair has no such fixed taxonomy — any label counts as its own class).
//
//  This is the 2D association engine RepairAutoPlacer (§5.6) uses for per-frame bbox
//  matching (IoU-based, see `repairBBoxIoU`). The union-merge/clustering functions are kept
//  available per the copy-map instruction even though RepairAutoPlacer's primary matching
//  primitive is IoU, not a pre-merge across frames (05 §5.6: "the union-merge machinery is
//  reused as the association primitive, not as a pre-merge").
//

import CoreGraphics

// MARK: - IoU (association primitive used by RepairAutoPlacer)

/// Intersection-over-union of two normalized-image-space bounding boxes.
func repairBBoxIoU(_ a: CGRect, _ b: CGRect) -> Float {
    let ix = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    let iy = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    let inter = ix * iy
    guard inter > 0 else { return 0 }
    let union = a.width * a.height + b.width * b.height - inter
    guard union > 0 else { return 0 }
    return Float(inter / union)
}

/// True if two boxes intersect, or are within `gapToleranceFraction` of the longer box's
/// longest side of each other (handles small gaps, e.g. a detection that's split across
/// two slightly-separated boxes in one frame).
func repairBBoxOverlapsWithGapTolerance(
    _ a: CGRect,
    _ b: CGRect,
    gapToleranceFraction: CGFloat = 0.10
) -> Bool {
    if a.intersects(b) { return true }
    let longestSide = max(max(a.width, a.height), max(b.width, b.height))
    let tol = longestSide * gapToleranceFraction
    return a.insetBy(dx: -tol, dy: -tol).intersects(b)
}

// MARK: - Multi-frame accumulator merge (class-agnostic)

/// Greedy cluster-then-transitive-closure union merge for a set of detections, grouped
/// by `label` first (so different object classes never merge into one box).
func repairDetectionUnionMerge(
    _ detections: [RepairDetection],
    gapToleranceFraction: CGFloat = 0.10
) -> [RepairDetection] {
    guard !detections.isEmpty else { return [] }

    let byLabel = Dictionary(grouping: detections, by: { $0.label })
    return byLabel.values.flatMap { group in
        repairUnionMergeSingleClass(group, gapToleranceFraction: gapToleranceFraction)
    }
}

private func repairUnionMergeSingleClass(
    _ detections: [RepairDetection],
    gapToleranceFraction: CGFloat
) -> [RepairDetection] {
    guard !detections.isEmpty else { return [] }

    // Phase 1 — greedy seed clustering on direct bbox intersection.
    var clusters: [[RepairDetection]] = []
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
    // `gapToleranceFraction` of the longer box's longest side of each other.
    var changed = true
    while changed {
        changed = false
        var merged: [[RepairDetection]] = []
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
                if repairBBoxOverlapsWithGapTolerance(box, other, gapToleranceFraction: gapToleranceFraction) {
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

    return clusters.compactMap { cluster -> RepairDetection? in
        guard let best = cluster.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let unionBox = cluster.dropFirst().reduce(cluster[0].boundingBox) { $0.union($1.boundingBox) }
        return RepairDetection(
            boundingBox: unionBox,
            classIndex: best.classIndex,
            label: best.label,
            confidence: best.confidence,
            timestamp: best.timestamp
        )
    }
}
