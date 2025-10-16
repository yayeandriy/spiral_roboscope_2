# Liquid Glass UI Implementation Guide

This guide documents how the app implements Apple’s Liquid Glass effects for buttons and controls, following the official SwiftUI guidance.

References:
- Apply and configure Liquid Glass effects: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- Building an app with Liquid Glass: https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass

## Goals
- Use Apple’s system Liquid Glass API when available (iOS 18+)
- Provide graceful fallback for earlier iOS versions using system materials
- Keep appearance consistent and clear on AR backgrounds (avoid gray tint)

## Components

We expose two helpers that wrap the platform differences while keeping the call sites simple and readable.

```swift
extension View {
    // Capsule-shaped Liquid Glass with optional tint
    @ViewBuilder
    func lgCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 18.0, *) {
            let appliedTint = tint ?? .white
            self
                .tint(appliedTint)
                .glassEffect(in: .capsule)
        } else {
            let appliedTint = tint ?? .white
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.25)))
                .overlay(Capsule().fill(appliedTint.opacity(0.18)))
        }
    }

    // Circular Liquid Glass with optional tint
    @ViewBuilder
    func lgCircle(tint: Color? = nil) -> some View {
        if #available(iOS 18.0, *) {
            let appliedTint = tint ?? .white
            self
                .tint(appliedTint)
                .glassEffect(in: .circle)
        } else {
            let appliedTint = tint ?? .white
            self
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25)))
                .overlay(Circle().fill(appliedTint.opacity(0.18)))
        }
    }
}
```

- On iOS 18+, we use Apple’s `.glassEffect(in:)` API with a shape and `.tint` to control prominence.
- On iOS < 18, we approximate the effect with `.thinMaterial` plus a light white stroke and a translucent overlay. This avoids the muddy/gray look against camera video.

## Usage

In `ContentView.swift`:

```swift
// Top controls
Button("Send spatial data") { exportSpatialData() }
    .buttonStyle(.plain)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .lgCapsule(tint: .white)

Button(isScanning ? "Stop scan" : "Scan") { toggleScanning() }
    .buttonStyle(.plain)
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .lgCapsule(tint: isScanning ? .red : .white)

// Bottom action button
Button { placeMarker() } label: {
    Image(systemName: "+").font(.system(size: 36))
        .frame(width: 80, height: 80)
}
.buttonStyle(.plain)
.lgCircle(tint: .white)
```

## Design Decisions
- Avoid bold fonts per project typography rules; rely on size and spacing.
- Prefer white tint on neutral states to keep buttons bright and clear on AR feed.
- Use red tint when scanning to signal urgency/state.
- Keep padding outside the helpers so touch targets remain comfortable.

## Troubleshooting
- If buttons look flat, ensure you’re running on iOS 18+ to see true Liquid Glass.
- On older OS versions, the fallback still looks frosted but less animated.
- Very uniform camera backgrounds can make the effect appear subtler; white tint and stroke mitigate this.

## Next Enhancements
- Use `glassEffectUnion(id:namespace:)` to fuse multiple controls into a single pill when grouping is desired.
- Add subtle press animations (when supported by SDK) to match Apple’s interactive guidance.
