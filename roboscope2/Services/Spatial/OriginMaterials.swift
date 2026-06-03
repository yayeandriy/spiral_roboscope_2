//
//  OriginMaterials.swift
//  roboscope2
//
//  Factory for CustomMaterial instances backed by Shaders.metal.
//  Replaces SimpleMaterial/UnlitMaterial for origin-related geometry.
//

import RealityKit
import UIKit

/// Stateless factory that creates `CustomMaterial` instances from the
/// glow-sphere and emissive-axis Metal surface shaders.
enum OriginMaterials {

    // MARK: - Library loading (lazy, cached)

    private static var _library: MTLLibrary?

    /// Returns the default MTLLibrary containing `Shaders.metal`.
    /// Cached so we only load once per process lifetime.
    static func library() throws -> MTLLibrary {
        if let lib = _library { return lib }
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        // Shaders.metal is in the main bundle (Resources folder).
        let lib = try device.makeDefaultLibrary(bundle: .main)
        _library = lib
        return lib
    }

    // MARK: - Material factories

    /// Glow sphere material with fresnel edge glow.
    /// - Parameter color: UIKit colour used as the base tint.
    /// - Returns: A `CustomMaterial` backed by `glowSphereSurface`.
    static func glowSphere(color: UIColor) throws -> CustomMaterial {
        let lib = try library()
        let baseMaterial = SimpleMaterial(color: color, isMetallic: false)
        let surfaceShader = CustomMaterial.SurfaceShader(
            named: "glowSphereSurface",
            in: lib
        )
        return try CustomMaterial(from: baseMaterial, surfaceShader: surfaceShader)
    }

    /// Emissive axis material — bright, saturated, no specular.
    /// - Parameter color: UIKit colour used as the base tint.
    /// - Returns: A `CustomMaterial` backed by `emissiveAxisSurface`.
    static func emissiveAxis(color: UIColor) throws -> CustomMaterial {
        let lib = try library()
        let baseMaterial = SimpleMaterial(color: color, isMetallic: false)
        let surfaceShader = CustomMaterial.SurfaceShader(
            named: "emissiveAxisSurface",
            in: lib
        )
        return try CustomMaterial(from: baseMaterial, surfaceShader: surfaceShader)
    }

    // MARK: - Convenience: pre-baked materials (lazy)

    /// Lazy convenience accessors.  Force-unwrap is acceptable here because
    /// a missing shader is a programmer error that should crash early.
    static var xGlowSphere: CustomMaterial = {
        try! glowSphere(color: .systemRed)
    }()
    static var yGlowSphere: CustomMaterial = {
        try! glowSphere(color: .systemGreen)
    }()
    static var zGlowSphere: CustomMaterial = {
        try! glowSphere(color: .systemBlue)
    }()
    static var centerGlowSphere: CustomMaterial = {
        try! glowSphere(color: .systemYellow)
    }()
    static var manualFirstSphere: CustomMaterial = {
        try! glowSphere(color: .systemRed)
    }()
    static var manualSecondSphere: CustomMaterial = {
        try! glowSphere(color: .systemBlue)
    }()
    static var manualSelectedSphere: CustomMaterial = {
        try! glowSphere(color: .black)
    }()
    static var debugDotSphere: CustomMaterial = {
        try! glowSphere(color: .systemRed)
    }()
    static var debugLineSphere: CustomMaterial = {
        try! glowSphere(color: .systemGreen)
    }()
    static var markerNodeSphere: CustomMaterial = {
        try! glowSphere(color: .white)
    }()

    // MARK: - Manual point disks (Measure-app style, 10 cm diameter)

    /// White disk for manual two-point placement — normal state.
    static var manualPointDisk: CustomMaterial = {
        try! glowSphere(color: .white)
    }()
    /// White disk for manual two-point placement — selected/highlighted state.
    static var manualPointDiskSelected: CustomMaterial = {
        try! glowSphere(color: UIColor(white: 0.3, alpha: 1.0))
    }()

    static var xAxisEmissive: CustomMaterial = {
        try! emissiveAxis(color: .systemRed)
    }()
    static var yAxisEmissive: CustomMaterial = {
        try! emissiveAxis(color: .systemGreen)
    }()
    static var zAxisEmissive: CustomMaterial = {
        try! emissiveAxis(color: .systemBlue)
    }()
}
