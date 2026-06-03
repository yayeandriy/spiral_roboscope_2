//
//  Shaders.metal
//  roboscope2
//
//  Custom Metal surface shaders for RealityKit CustomMaterial.
//  Replaces SimpleMaterial/UnlitMaterial for origin gizmo spheres and axes
//  with glow + emissive rendering that stands out in AR.
//
//  Reference: telescope_3/telescanner/Telescanner/_disabled/Shaders.metal
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// ──────────────────────────────────────────────────────────────────────────────
//  glowSphereSurface
//  ─────────────────
//  PBR-style surface with fresnel glow at edges.
//  - Interior is the base colour at reduced opacity.
//  - Edges glow brighter (fresnel) so the sphere "pops" in AR.
//  - Pass colour via `material_constants().base_color_tint()`.
//
//  Used for: origin centre sphere, axis-tip spheres, manual-placement spheres.
// ──────────────────────────────────────────────────────────────────────────────
[[visible]]
void glowSphereSurface(realitykit::surface_parameters params) {

    // ── Read base colour from CustomMaterial custom value (set in Swift) ──
    half3 baseColor = half3(params.material_constants().base_color_tint());

    // ── Fresnel: edge glow ────────────────────────────────────────────────
    // N·V: surface normal dot view direction.
    half3 N = half3(normalize(params.geometry().normal()));
    half3 V = half3(normalize(params.geometry().view_direction()));
    half  NdV = abs(dot(N, V));
    // fresnel = 1 at grazing angles (edges), 0 when looking straight on.
    half  fresnel = pow(1.0h - NdV, 3.0h);

    // ── Colours ───────────────────────────────────────────────────────────
    // Glow: brighten and whiten at edges.
    half3 glow  = clamp(baseColor * 2.5h, 0.0h, 1.0h);
    half3 color = mix(baseColor * 0.7h, glow, fresnel);
    // More opaque at edges, slightly translucent in center for depth.
    half  alpha = mix(half(0.60), half(0.95), fresnel);

    // ── Output ────────────────────────────────────────────────────────────
    params.surface().set_base_color(color);
    params.surface().set_opacity(alpha);
    // Slight emissive so spheres are visible even in dim lighting.
    params.surface().set_emissive_color(color * half(0.25));
}


// ──────────────────────────────────────────────────────────────────────────────
//  emissiveAxisSurface
//  ─────────────────
//  Bright, unlit-looking surface for the origin axes (cylinders).
//  Saturated colour with a subtle fresnel so the cylinder edges catch light.
//
//  Used for: X/Y/Z axis cylinders in the frame-origin gizmo.
// ──────────────────────────────────────────────────────────────────────────────
[[visible]]
void emissiveAxisSurface(realitykit::surface_parameters params) {

    half3 baseColor = half3(params.material_constants().base_color_tint());

    // Subtle fresnel for shape definition on cylinders.
    half3 N = half3(normalize(params.geometry().normal()));
    half3 V = half3(normalize(params.geometry().view_direction()));
    half  NdV = abs(dot(N, V));
    half  fresnel = pow(1.0h - NdV, 2.0h);

    // Bright saturated body, slightly brighter edge.
    half3 color = mix(baseColor * 1.2h, baseColor * 1.8h, fresnel);

    params.surface().set_base_color(color);
    params.surface().set_opacity(half(0.90));
    params.surface().set_emissive_color(color * half(0.40));
    // Kill specular — we want the axes to look like glowing rods, not metal.
    params.surface().set_roughness(half(1.0));
    params.surface().set_metallic(half(0.0));
}
