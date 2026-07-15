//
//  RepairAutoPlacer.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  THE core new logic (05-ios-repair.md §5.6 / 00-rules-and-boundaries.md §0.7.1).
//  Locked design: 2D-first association -> temporal confirm -> raycast at confirmation ->
//  3D dedup -> place. This file is pure Swift + simd (no ARKit/RealityKit import) so the
//  raycast and rendering side effects are injected by the caller (RepairARSessionView+Logic),
//  keeping the algorithm itself easy to reason about in isolation.
//

import Foundation
import CoreGraphics
import simd

// MARK: - Candidate state

struct RepairCandidate {
    let id: UUID                    // stable while associated
    var lastBBox: CGRect            // normalized image space (top-left)
    var hitWindow: [Bool]           // sliding window, most-recent last (max windowSize)
    var lastClass: String
    var lastConfidence: Float
    /// True once this candidate has produced a pin. Excluded from further association;
    /// its window is left to decay to all-false via natural "not matched" pushes, at which
    /// point it's dropped from `candidates` (05 §5.6 "Notes": one physical object -> one pin).
    var hasProducedPin: Bool = false

    var confirmedHitCount: Int {
        hitWindow.filter { $0 }.count
    }
}

/// A pin the placer decided to create this `ingest` call. The caller is responsible for
/// actually rendering it (RepairPinRenderer) and buffering/flushing the CreatePin network call.
struct RepairPlacedPin {
    let id: UUID
    let world: SIMD3<Float>
    let detectionClass: String
    let confidence: Float
}

/// The core auto-placement state machine. One instance per Repair AR session.
final class RepairAutoPlacer {

    // `var`, not `let` — the in-session settings sheet lets the operator retune these live
    // (RepairARSessionView observes RepairSettings and pushes changes in here on the fly).
    var windowSize: Int
    var confirmThreshold: Int
    var dedupRadiusMeters: Float
    var iouThreshold: Float

    private(set) var candidates: [RepairCandidate] = []
    /// All pins placed so far this session — used for the 3D dedup check.
    private(set) var placedPins: [(id: UUID, world: SIMD3<Float>)] = []

    init(
        windowSize: Int = 20,
        confirmThreshold: Int = 15,
        dedupRadiusMeters: Float = 0.05,
        iouThreshold: Float = 0.3
    ) {
        self.windowSize = windowSize
        self.confirmThreshold = confirmThreshold
        self.dedupRadiusMeters = dedupRadiusMeters
        self.iouThreshold = iouThreshold
    }

    /// Clears all state. Call when a new session starts.
    func reset() {
        candidates = []
        placedPins = []
    }

    /// Clears only in-flight tracking candidates, keeping `placedPins` (and therefore the 3D
    /// dedup set) intact. Used when swapping the detector model mid-session — old candidates
    /// reference the previous model's class labels/box geometry and must not carry over, but
    /// pins already placed must still block re-placement at the same spot.
    func resetCandidatesOnly() {
        candidates = []
    }

    /// Candidates currently accumulating hits toward confirmation, for UI feedback (e.g. a
    /// "maturing" progress ring drawn over the live detection box). Filters out:
    ///  - Candidates that already produced a pin (obviously).
    ///  - Very fresh candidates (< ~20% of confirmThreshold hits) — single/couple-frame noise
    ///    blips (reflections, wood grain, etc.) that would otherwise flash a ring on screen for
    ///    one frame and vanish, reading as visual "artifacts" rather than useful feedback.
    ///  - Candidates overlapping a retired (already-placed-a-pin) candidate's last box — these
    ///    only exist because the object is still visible after its pin was placed (the retired
    ///    candidate is excluded from further association by design); showing a second ring right
    ///    on top of an already-placed pin is confusing, even though it'll never produce a
    ///    duplicate pin (the 3D dedup check still catches it at confirm time).
    var maturingCandidates: [(id: UUID, bbox: CGRect, progress: Float)] {
        let minHitsToShow = max(2, confirmThreshold / 5)
        let retiredBoxes = candidates.filter { $0.hasProducedPin }.map { $0.lastBBox }

        return candidates
            .filter { !$0.hasProducedPin && $0.confirmedHitCount >= minHitsToShow }
            .filter { candidate in
                !retiredBoxes.contains { repairBBoxIoU(candidate.lastBBox, $0) >= iouThreshold }
            }
            .map { ($0.id, $0.lastBBox, min(1.0, Float($0.confirmedHitCount) / Float(max(1, confirmThreshold)))) }
    }

    /// Seed the dedup set from pins already persisted for this session (e.g. after re-opening
    /// an existing active session). Does not affect `candidates`.
    func seedPlacedPins(_ pins: [(id: UUID, world: SIMD3<Float>)]) {
        placedPins.append(contentsOf: pins)
    }

    /// Removes a placed pin from the dedup set (used by tap-to-delete — once removed, a new
    /// detection near that spot is free to produce a fresh pin again).
    func removePlacedPin(id: UUID) {
        placedPins.removeAll { $0.id == id }
    }

    /// Per-frame update. `rawDetections` MUST be the raw, per-frame detections from
    /// RepairMLDetectionService.detections — NOT the multi-frame accumulated/merged set
    /// (05 §5.6: association needs raw per-frame boxes; the union-merge machinery is reused
    /// only as the association primitive, i.e. the IoU check, not as a pre-merge).
    ///
    /// `raycast` maps a confirming candidate's normalized-image-space bbox to a real-world
    /// ARKit point (existing-plane -> estimated-plane fallback, implemented by the caller).
    /// Returns nil on a raycast miss, in which case no pin is placed this frame but the
    /// candidate keeps evaluating on subsequent frames.
    @discardableResult
    func ingest(
        _ rawDetections: [RepairDetection],
        raycast: (CGRect) -> SIMD3<Float>?
    ) -> [RepairPlacedPin] {

        // MARK: 1. ASSOCIATE (2D)

        let activeIndices = candidates.indices.filter { !candidates[$0].hasProducedPin }

        // For each detection, the set of active candidates whose class matches and whose
        // IoU with the candidate's last-known box clears the association threshold.
        let detectionMatches: [[Int]] = rawDetections.map { det in
            activeIndices.filter { idx in
                candidates[idx].lastClass == det.label &&
                repairBBoxIoU(det.boundingBox, candidates[idx].lastBBox) >= iouThreshold
            }
        }

        var candidateMatchCounts: [Int: Int] = [:]
        for matches in detectionMatches {
            for idx in matches { candidateMatchCounts[idx, default: 0] += 1 }
        }

        // MARK: 2. AMBIGUITY GUARD (reset on collision)

        // Split: one candidate matched by 2+ detections. Merge: one detection matched 2+ candidates.
        var resetIndices = Set(candidateMatchCounts.filter { $0.value >= 2 }.keys)
        for matches in detectionMatches where matches.count >= 2 {
            resetIndices.formUnion(matches)
        }
        for idx in resetIndices {
            candidates[idx].hitWindow = []
        }

        // MARK: Resolve unambiguous single-match associations

        var matchedCandidateIndices = Set<Int>()
        var detectionsWithAnyMatch = Set<Int>()
        for (dIdx, matches) in detectionMatches.enumerated() {
            guard !matches.isEmpty else { continue }
            detectionsWithAnyMatch.insert(dIdx)

            let validMatches = matches.filter { !resetIndices.contains($0) }
            guard validMatches.count == 1,
                  let cIdx = validMatches.first,
                  candidateMatchCounts[cIdx] == 1 else { continue }

            let det = rawDetections[dIdx]
            candidates[cIdx].lastBBox = det.boundingBox
            candidates[cIdx].lastClass = det.label
            candidates[cIdx].lastConfidence = det.confidence
            candidates[cIdx].hitWindow.append(true)
            matchedCandidateIndices.insert(cIdx)
        }

        // MARK: New candidates — only for detections with ZERO raw matches.
        // Detections involved in ambiguity (merge/split) do NOT spawn a new candidate this
        // frame; they'll naturally re-associate (or spawn fresh) once the reset candidate's
        // cleared window lets it re-accumulate. This avoids a flood of duplicate candidates
        // the instant two objects' boxes touch.
        for (dIdx, det) in rawDetections.enumerated() where !detectionsWithAnyMatch.contains(dIdx) {
            let newCandidate = RepairCandidate(
                id: UUID(),
                lastBBox: det.boundingBox,
                hitWindow: [true],
                lastClass: det.label,
                lastConfidence: det.confidence
            )
            candidates.append(newCandidate)
        }

        // MARK: Push `false` for every candidate not matched (and not just reset) this frame.
        // This includes retired (hasProducedPin) candidates, which are never in activeIndices
        // and therefore never matched — they decay out of the window naturally (05 §5.6 Notes).
        for idx in candidates.indices {
            if resetIndices.contains(idx) { continue } // window already cleared above
            if matchedCandidateIndices.contains(idx) { continue } // already pushed `true` above
            candidates[idx].hitWindow.append(false)
        }

        // Trim every window to the last `windowSize`.
        for idx in candidates.indices {
            if candidates[idx].hitWindow.count > windowSize {
                candidates[idx].hitWindow.removeFirst(candidates[idx].hitWindow.count - windowSize)
            }
        }

        // Drop candidates whose window is non-empty and entirely false (decayed / left the frame,
        // or a retired candidate that has fully decayed out).
        candidates.removeAll { candidate in
            !candidate.hitWindow.isEmpty && !candidate.hitWindow.contains(true)
        }

        // MARK: 3. CONFIRM (temporal) -> raycast -> dedup -> place

        var newlyPlaced: [RepairPlacedPin] = []

        for idx in candidates.indices {
            let candidate = candidates[idx]
            guard !candidate.hasProducedPin else { continue }
            guard candidate.confirmedHitCount >= confirmThreshold else { continue }

            guard let world = raycast(candidate.lastBBox) else {
                // Raycast miss -> no pin, keep evaluating (do nothing this frame).
                continue
            }
            guard !world.x.isNaN, !world.y.isNaN, !world.z.isNaN else { continue }

            let tooClose = placedPins.contains { existing in
                simd_distance(existing.world, world) <= dedupRadiusMeters
            }
            if tooClose {
                // Same physical object as an already-placed pin — absorb, no new pin.
                // Retire the candidate too, so it decays out rather than re-triggering
                // the dedup check every frame.
                candidates[idx].hasProducedPin = true
                continue
            }

            let pinId = UUID()
            placedPins.append((id: pinId, world: world))
            candidates[idx].hasProducedPin = true

            let placed = RepairPlacedPin(
                id: pinId,
                world: world,
                detectionClass: candidate.lastClass,
                confidence: candidate.lastConfidence
            )
            newlyPlaced.append(placed)
        }

        return newlyPlaced
    }
}
