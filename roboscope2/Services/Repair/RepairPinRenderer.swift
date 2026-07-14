//
//  RepairPinRenderer.swift
//  roboscope2
//
//  UNTESTED — authored on Windows without Xcode. Needs on-device verification on a physical iPhone.
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Copied (pattern) from the cached-mesh sphere approach in Services/Spatial/SpatialMarkerService.swift
//  and the single-sphere-at-world-pos pattern in LaserGuideARSessionView+Scoping.swift
//  (both READ-ONLY references) per 05-ios-repair.md §5.2. Repair has no quads/gestures/edge
//  crossing — just a red ball per pin, placed at a raw ARKit-world point and tracked by pin id
//  so it can be removed again on delete.
//
//  Deliberately does NOT reuse Services/Spatial/SpatialMarkerService* (00 §0.8 — never touch/
//  import Laser Guide's spatial marker code).
//

import RealityKit
import UIKit

/// Manages red-ball pin entities placed directly at raw ARKit-world coordinates.
/// No anchoring/transform indirection — Repair places pins in the raw ARKit world (00 §0.6).
final class RepairPinRenderer: ObservableObject {

    // Cached mesh + material so we don't regenerate geometry per pin.
    private static let pinMesh = MeshResource.generateSphere(radius: 0.025)
    private static let pinMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.08, blue: 0.08, alpha: 1.0))

    private weak var arView: ARView?
    private var anchorsByPinId: [UUID: AnchorEntity] = [:]

    init(arView: ARView? = nil) {
        self.arView = arView
    }

    func attach(to arView: ARView) {
        self.arView = arView
    }

    /// Places a red sphere at `world` and tracks it under `pinId` for later removal.
    @discardableResult
    func addPin(id pinId: UUID, at world: SIMD3<Float>) -> AnchorEntity? {
        guard let arView else { return nil }
        guard !world.x.isNaN, !world.y.isNaN, !world.z.isNaN else { return nil }

        let sphere = ModelEntity(mesh: Self.pinMesh, materials: [Self.pinMaterial])
        let anchor = AnchorEntity(world: world)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchorsByPinId[pinId] = anchor
        return anchor
    }

    /// Removes the pin entity for `pinId`, if present. Used by tap-to-delete (§5.7).
    func removePin(id pinId: UUID) {
        guard let anchor = anchorsByPinId.removeValue(forKey: pinId) else { return }
        arView?.scene.removeAnchor(anchor)
    }

    /// Removes all pin entities (e.g. on session exit / cleanup).
    func removeAll() {
        guard let arView else { anchorsByPinId.removeAll(); return }
        for anchor in anchorsByPinId.values {
            arView.scene.removeAnchor(anchor)
        }
        anchorsByPinId.removeAll()
    }

    /// All currently-rendered pin ids — useful for tap-to-delete hit testing.
    var renderedPinIds: [UUID] {
        Array(anchorsByPinId.keys)
    }

    func anchor(for pinId: UUID) -> AnchorEntity? {
        anchorsByPinId[pinId]
    }

    /// Walks up from a hit-tested entity (e.g. from `ARView.entity(at:)`) to find which
    /// tracked pin anchor it belongs to. Used by tap-to-delete.
    func pinId(containingEntity entity: Entity) -> UUID? {
        var current: Entity? = entity
        while let e = current {
            if let match = anchorsByPinId.first(where: { $0.value === e }) {
                return match.key
            }
            current = e.parent
        }
        return nil
    }
}
