//
//  RepairSettings.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Standalone settings singleton for the four RepairAutoPlacer tunables (05-ios-repair.md
//  §5.8), following the existing AppSettings pattern (UserDefaults key enum + @Published
//  var { didSet persist }). Deliberately standalone rather than folded into AppSettings —
//  keeps the diff to existing files at zero for this file, and the module file plan (§5.4)
//  already lists this as a new file under Models/Repair/.
//

import Foundation
import Combine

final class RepairSettings: ObservableObject {
    static let shared = RepairSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let windowFrames = "repairTemporalWindowFrames"
        static let confirmThreshold = "repairConfirmThreshold"
        static let dedupRadiusMeters = "repairDedupRadiusMeters"
        static let assocIoUThreshold = "repairAssocIoUThreshold"
        static let confidenceThreshold = "repairConfidenceThreshold"
        static let bulkFlushIntervalSeconds = "repairBulkFlushIntervalSeconds"
        static let preferredModelId = "repairPreferredModelId"
        static let pinRadiusMeters = "repairPinRadiusMeters"
        static let showDetectionOverlay = "repairShowDetectionOverlay"
    }

    /// Sliding window size (frames) used for temporal confirmation.
    @Published var repairTemporalWindowFrames: Int {
        didSet { defaults.set(repairTemporalWindowFrames, forKey: Keys.windowFrames) }
    }

    /// Hits required within the window before a candidate is confirmed (of the last N frames).
    @Published var repairConfirmThreshold: Int {
        didSet { defaults.set(repairConfirmThreshold, forKey: Keys.confirmThreshold) }
    }

    /// Same-object 3-D dedup radius, in meters.
    @Published var repairDedupRadiusMeters: Float {
        didSet { defaults.set(repairDedupRadiusMeters, forKey: Keys.dedupRadiusMeters) }
    }

    /// 2-D association match strength (IoU) between a detection and a tracked candidate.
    @Published var repairAssocIoUThreshold: Float {
        didSet { defaults.set(repairAssocIoUThreshold, forKey: Keys.assocIoUThreshold) }
    }

    /// Minimum YOLO confidence for a raw detection to be considered at all.
    @Published var repairConfidenceThreshold: Float {
        didSet { defaults.set(repairConfidenceThreshold, forKey: Keys.confidenceThreshold) }
    }

    /// How often buffered pins are flushed to the API during an active session (seconds).
    @Published var repairBulkFlushIntervalSeconds: Double {
        didSet { defaults.set(repairBulkFlushIntervalSeconds, forKey: Keys.bulkFlushIntervalSeconds) }
    }

    /// Radius (meters) of the sphere rendered for each placed pin. Purely cosmetic — does not
    /// affect dedup/placement math. Applied live to ALL pins in an open AR session (including
    /// ones already placed), not just new ones — RepairARSessionView observes this and calls
    /// RepairPinRenderer.updateAllPinSizes(to:) on change.
    @Published var repairPinRadiusMeters: Float {
        didSet { defaults.set(repairPinRadiusMeters, forKey: Keys.pinRadiusMeters) }
    }

    /// Whether the live detection-box debug overlay is shown by default in new AR sessions.
    /// Toggleable per-session from the in-session settings sheet; persists as the new default.
    @Published var repairShowDetectionOverlay: Bool {
        didSet { defaults.set(repairShowDetectionOverlay, forKey: Keys.showDetectionOverlay) }
    }

    /// Operator-chosen detector model (CoremlModel.id, as a UUID string) used for NEW repair
    /// sessions instead of the server's registry default. nil = use the server default.
    /// Only affects sessions started from now on — a session already created keeps whatever
    /// model it was created with (there is no endpoint to retarget an existing session's model).
    @Published var preferredModelId: String? {
        didSet {
            if let preferredModelId {
                defaults.set(preferredModelId, forKey: Keys.preferredModelId)
            } else {
                defaults.removeObject(forKey: Keys.preferredModelId)
            }
        }
    }

    private init() {
        let window = defaults.integer(forKey: Keys.windowFrames)
        self.repairTemporalWindowFrames = window > 0 ? window : 20

        let confirm = defaults.integer(forKey: Keys.confirmThreshold)
        self.repairConfirmThreshold = confirm > 0 ? confirm : 15

        let dedup = defaults.float(forKey: Keys.dedupRadiusMeters)
        self.repairDedupRadiusMeters = dedup > 0 ? dedup : 0.05

        let iou = defaults.float(forKey: Keys.assocIoUThreshold)
        self.repairAssocIoUThreshold = iou > 0 ? iou : 0.3

        let conf = defaults.float(forKey: Keys.confidenceThreshold)
        self.repairConfidenceThreshold = conf > 0 ? conf : 0.5

        let flush = defaults.double(forKey: Keys.bulkFlushIntervalSeconds)
        self.repairBulkFlushIntervalSeconds = flush > 0 ? flush : 5.0

        let pinRadius = defaults.float(forKey: Keys.pinRadiusMeters)
        self.repairPinRadiusMeters = pinRadius > 0 ? pinRadius : 0.012

        // Default ON — no explicit key written yet means "not yet set", not "false".
        self.repairShowDetectionOverlay = defaults.object(forKey: Keys.showDetectionOverlay) == nil
            ? true
            : defaults.bool(forKey: Keys.showDetectionOverlay)

        self.preferredModelId = defaults.string(forKey: Keys.preferredModelId)
    }
}
