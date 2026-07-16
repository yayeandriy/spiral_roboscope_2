//
//  VerandaAPIConfiguration.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Second, INDEPENDENT API base for the Repair module. Deliberately does not touch the
//  existing `APIConfiguration` (00-rules-and-boundaries.md §0.8 — "never touch").
//  Prod-only, no LAN dev IP (00 §0.7.2 / 05 §5.1.5): Repair targets the deployed Veranda
//  API from day one.
//

import Foundation

enum VerandaAPIConfiguration {
    /// Host + /v1 prefix. Endpoints below are appended directly to this (e.g. "/models").
    /// Health lives at the bare host root (no /v1), but Repair never calls /health from iOS.
    static let baseURL = "https://api.robovision.spiral.technology/v1"

    static let timeout: TimeInterval = 30.0
}
