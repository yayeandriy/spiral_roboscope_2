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
//  crossing — just a small marker per pin, placed at a raw ARKit-world point and tracked by pin
//  id so it can be removed again on delete.
//
//  Deliberately does NOT reuse Services/Spatial/SpatialMarkerService* (00 §0.8 — never touch/
//  import Laser Guide's spatial marker code).
//
//  Per-class marker appearance (shape/color) comes from CoremlModel.classStyles — see
//  RepairClassStyle in RepairModels.swift. Mesh/material are generated per-pin at the moment of
//  placement so they can reflect a live pin-size setting change (updateAllPinSizes).
//

import Combine
import RealityKit
import UIKit

/// Manages pin entities placed directly at raw ARKit-world coordinates.
/// No anchoring/transform indirection — Repair places pins in the raw ARKit world (00 §0.6).
final class RepairPinRenderer: ObservableObject {

    private static let defaultMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.08, blue: 0.08, alpha: 1.0))
    private static let highlightMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.82, blue: 0.0, alpha: 1.0))

    private weak var arView: ARView?
    private var anchorsByPinId: [UUID: AnchorEntity] = [:]
    private var spheresByPinId: [UUID: ModelEntity] = [:]
    /// The style each pin was placed with, so a later resize (updateAllPinSizes) regenerates the
    /// correct shape instead of silently resetting every pin back to a plain sphere.
    private var styleByPinId: [UUID: RepairClassStyle?] = [:]
    private var baseMaterialByPinId: [UUID: UnlitMaterial] = [:]

    init(arView: ARView? = nil) {
        self.arView = arView
    }

    func attach(to arView: ARView) {
        self.arView = arView
    }

    /// Places a marker at `world` and tracks it under `pinId` for later removal. `style` (from
    /// the active model's `classStyles`, looked up by the detection's class) chooses the mesh
    /// shape and color; nil/unrecognized falls back to the default red sphere. Radius comes from
    /// `RepairSettings.shared.repairPinRadiusMeters` at call time.
    @discardableResult
    func addPin(id pinId: UUID, at world: SIMD3<Float>, style: RepairClassStyle? = nil) -> AnchorEntity? {
        guard let arView else { return nil }
        guard !world.x.isNaN, !world.y.isNaN, !world.z.isNaN else { return nil }

        let radius = max(0.0005, RepairSettings.shared.repairPinRadiusMeters)
        let mesh = Self.mesh(for: style?.shape, radius: radius)
        let material = Self.material(for: style?.color)

        let sphere = ModelEntity(mesh: mesh, materials: [material])
        let anchor = AnchorEntity(world: world)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)

        anchorsByPinId[pinId] = anchor
        spheresByPinId[pinId] = sphere
        styleByPinId[pinId] = style
        baseMaterialByPinId[pinId] = material
        return anchor
    }

    /// Removes the pin entity for `pinId`, if present. Used by tap-to-delete (§5.7).
    func removePin(id pinId: UUID) {
        guard let anchor = anchorsByPinId.removeValue(forKey: pinId) else { return }
        arView?.scene.removeAnchor(anchor)
        spheresByPinId.removeValue(forKey: pinId)
        styleByPinId.removeValue(forKey: pinId)
        baseMaterialByPinId.removeValue(forKey: pinId)
    }

    /// Removes all pin entities (e.g. on session exit / cleanup).
    func removeAll() {
        if let arView {
            for anchor in anchorsByPinId.values {
                arView.scene.removeAnchor(anchor)
            }
        }
        anchorsByPinId.removeAll()
        spheresByPinId.removeAll()
        styleByPinId.removeAll()
        baseMaterialByPinId.removeAll()
    }

    /// Swaps a pin's material between normal (its class color) and highlighted (yellow) — used
    /// for the tap-to-select-then-delete flow. Shape is untouched.
    func setSelected(id pinId: UUID, selected: Bool) {
        guard let sphere = spheresByPinId[pinId] else { return }
        let material = selected ? Self.highlightMaterial : (baseMaterialByPinId[pinId] ?? Self.defaultMaterial)
        sphere.model?.materials = [material]
    }

    /// Live-resizes every currently-rendered pin (not just future ones) to `radiusMeters` —
    /// called when the operator changes the pin-size setting mid-session. Regenerates each pin's
    /// mesh using ITS OWN recorded shape, not a hardcoded sphere.
    func updateAllPinSizes(to radiusMeters: Float) {
        guard !spheresByPinId.isEmpty else { return }
        let radius = max(0.0005, radiusMeters)
        for (pinId, sphere) in spheresByPinId {
            let style = styleByPinId[pinId] ?? nil
            sphere.model?.mesh = Self.mesh(for: style?.shape, radius: radius)
        }
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

    // MARK: - Shape / color

    private static func mesh(for shape: String?, radius: Float) -> MeshResource {
        switch shape?.lowercased() {
        case "square":
            return .generateBox(size: radius * 1.6)
        case "triangle":
            return triangularPyramid(radius: radius * 1.3)
        default: // "circle", missing, or unrecognized
            return .generateSphere(radius: radius)
        }
    }

    /// Simple 4-face triangular pyramid (tetrahedron-ish), since RealityKit has no built-in
    /// triangle/cone primitive generator. Face culling is disabled on the material using it, so
    /// winding order doesn't matter for visibility from any angle.
    private static func triangularPyramid(radius: Float) -> MeshResource {
        let apex = SIMD3<Float>(0, radius, 0)
        let base0 = SIMD3<Float>(-radius, -radius * 0.5, radius * 0.577)
        let base1 = SIMD3<Float>(radius, -radius * 0.5, radius * 0.577)
        let base2 = SIMD3<Float>(0, -radius * 0.5, -radius * 1.155)

        var descriptor = MeshDescriptor(name: "repairTrianglePin")
        descriptor.positions = MeshBuffer([apex, base0, base1, base2])
        descriptor.primitives = .triangles([
            0, 1, 2,
            0, 2, 3,
            0, 3, 1,
            1, 3, 2,
        ])

        guard let generated = try? MeshResource.generate(from: [descriptor]) else {
            return .generateSphere(radius: radius)
        }
        return generated
    }

    private static func material(for colorHex: String?) -> UnlitMaterial {
        guard let colorHex, let color = UIColor(hex: colorHex) else {
            return defaultMaterial
        }
        var material = UnlitMaterial(color: color)
        material.faceCulling = .none
        return material
    }
}
