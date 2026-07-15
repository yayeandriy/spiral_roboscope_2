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

/// A Repair AR session is split into two sub-modes (v0.4). Planning is the original
/// auto-placement workflow, unchanged. Validation is a new passive mode: no auto-placement, no
/// pins — just a live YOLO detection overlay (box + class + confidence) using a SEPARATE model,
/// for visually confirming detection quality without touching the planning pin set.
enum RepairSessionMode: String, CaseIterable {
    case planning
    case validation

    var displayName: String {
        switch self {
        case .planning: return "Planning"
        case .validation: return "Validation"
        }
    }
}

final class RepairSettings: ObservableObject {
    static let shared = RepairSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let windowFrames = "repairTemporalWindowFrames"
        static let confirmThreshold = "repairConfirmThreshold"
        static let dedupRadiusMeters = "repairDedupRadiusMeters"
        static let assocIoUThreshold = "repairAssocIoUThreshold"
        // Kept as the on-disk key for the (renamed) planning threshold, so an existing install's
        // saved value carries over rather than silently resetting to the new 0.35 default.
        static let planningConfidenceThreshold = "repairConfidenceThreshold"
        static let validationConfidenceThreshold = "repairValidationConfidenceThreshold"
        static let bulkFlushIntervalSeconds = "repairBulkFlushIntervalSeconds"
        // Kept as the on-disk key for the (renamed) planning model preference, same reasoning.
        static let preferredPlanningModelId = "repairPreferredModelId"
        static let preferredValidationModelId = "repairPreferredValidationModelId"
        static let pinRadiusMeters = "repairPinRadiusMeters"
        static let showDetectionOverlay = "repairShowDetectionOverlay"
        static let useAccumulator = "repairUseAccumulator"
    }

    /// Whether Planning mode requires several repeated detections ("N of the last M frames",
    /// tuned by `repairConfirmThreshold`/`repairTemporalWindowFrames` below) before placing a
    /// pin. ON by default (classic "15 of the last 20" behavior). Turning this off collapses to
    /// a pin dropping on the very FIRST detection of an object — RepairARSessionView enforces
    /// this by pinning `RepairAutoPlacer.windowSize`/`confirmThreshold` to 1 whenever this is
    /// false, rather than by changing the algorithm itself (see `applyAccumulatorSettings()`).
    @Published var repairUseAccumulator: Bool {
        didSet { defaults.set(repairUseAccumulator, forKey: Keys.useAccumulator) }
    }

    /// Sliding window size (frames) used for temporal confirmation — only in effect while
    /// `repairUseAccumulator == true`.
    @Published var repairTemporalWindowFrames: Int {
        didSet { defaults.set(repairTemporalWindowFrames, forKey: Keys.windowFrames) }
    }

    /// Hits required within the window before a candidate is confirmed (of the last N frames) —
    /// only in effect while `repairUseAccumulator == true`.
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

    /// Minimum YOLO confidence for a raw detection to be considered at all, in Planning mode.
    @Published var repairPlanningConfidenceThreshold: Float {
        didSet { defaults.set(repairPlanningConfidenceThreshold, forKey: Keys.planningConfidenceThreshold) }
    }

    /// Minimum YOLO confidence for a raw detection to be shown at all, in Validation mode.
    /// Independent of the planning threshold — Validation runs a different model for a different
    /// purpose (passive confirmation, not placement), so it gets its own tunable.
    @Published var repairValidationConfidenceThreshold: Float {
        didSet { defaults.set(repairValidationConfidenceThreshold, forKey: Keys.validationConfidenceThreshold) }
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

    /// Operator-chosen Planning-mode detector model (CoremlModel.id, as a UUID string) used for
    /// NEW repair sessions instead of the server's registry default. nil = use the server/model
    /// registry default (CoremlModel.isDefaultPlanning, falling back to isDefault). Only affects
    /// sessions started from now on — a session already created keeps whatever model it was
    /// created with (there is no endpoint to retarget an existing session's model).
    @Published var preferredPlanningModelId: String? {
        didSet {
            if let preferredPlanningModelId {
                defaults.set(preferredPlanningModelId, forKey: Keys.preferredPlanningModelId)
            } else {
                defaults.removeObject(forKey: Keys.preferredPlanningModelId)
            }
        }
    }

    /// Operator-chosen Validation-mode detector model (CoremlModel.id, as a UUID string). nil =
    /// use CoremlModel.isDefaultValidation, falling back further to isDefault/first active model.
    /// Resolved lazily — only looked up the first time a session's operator switches into
    /// Validation mode, never at session creation.
    @Published var preferredValidationModelId: String? {
        didSet {
            if let preferredValidationModelId {
                defaults.set(preferredValidationModelId, forKey: Keys.preferredValidationModelId)
            } else {
                defaults.removeObject(forKey: Keys.preferredValidationModelId)
            }
        }
    }

    private init() {
        // Default ON — no explicit key written yet means "not yet set", not "false".
        self.repairUseAccumulator = defaults.object(forKey: Keys.useAccumulator) == nil
            ? true
            : defaults.bool(forKey: Keys.useAccumulator)

        let window = defaults.integer(forKey: Keys.windowFrames)
        self.repairTemporalWindowFrames = window > 0 ? window : 20

        let confirm = defaults.integer(forKey: Keys.confirmThreshold)
        self.repairConfirmThreshold = confirm > 0 ? confirm : 15

        let dedup = defaults.float(forKey: Keys.dedupRadiusMeters)
        self.repairDedupRadiusMeters = dedup > 0 ? dedup : 0.02

        let iou = defaults.float(forKey: Keys.assocIoUThreshold)
        self.repairAssocIoUThreshold = iou > 0 ? iou : 0.3

        let planningConf = defaults.float(forKey: Keys.planningConfidenceThreshold)
        self.repairPlanningConfidenceThreshold = planningConf > 0 ? planningConf : 0.35

        let validationConf = defaults.float(forKey: Keys.validationConfidenceThreshold)
        self.repairValidationConfidenceThreshold = validationConf > 0 ? validationConf : 0.35

        let flush = defaults.double(forKey: Keys.bulkFlushIntervalSeconds)
        self.repairBulkFlushIntervalSeconds = flush > 0 ? flush : 5.0

        let pinRadius = defaults.float(forKey: Keys.pinRadiusMeters)
        // Default diameter 1 cm -> radius 0.005 m. Slider (RepairSessionSettingsView) allows
        // down to 0.05 cm radius (0.1 cm diameter).
        self.repairPinRadiusMeters = pinRadius > 0 ? pinRadius : 0.005

        // Default ON — no explicit key written yet means "not yet set", not "false".
        self.repairShowDetectionOverlay = defaults.object(forKey: Keys.showDetectionOverlay) == nil
            ? true
            : defaults.bool(forKey: Keys.showDetectionOverlay)

        self.preferredPlanningModelId = defaults.string(forKey: Keys.preferredPlanningModelId)
        self.preferredValidationModelId = defaults.string(forKey: Keys.preferredValidationModelId)
    }
}
