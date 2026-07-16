//
//  RepairMiniMapView.swift
//  roboscope2
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Top-down 2D "minimap" preview of every pin placed so far this Planning session — a
//  minimized, on-device mirror of the web portal's Pin3DViewer (spiral-roboscope-veranda
//  services/web/components/pin-3d-viewer.tsx), reusing the SAME corner-sheet /
//  oriented-rectangle / distance-formatting logic, ported from TypeScript+three.js to plain
//  SwiftUI Canvas drawing (no 3D engine needed for a flat top-down projection).
//
//  Deliberately simplified vs. the web version:
//   - No "ply drop" 3-sided open shape (top_left/top_right/bottom_right present,
//     bottom_left absent) — explicitly dropped per operator request ("ignore the ply drop, I
//     never managed to do it well"). That 3-corner case is simply left undrawn here.
//   - No free 3D orbit/tilt — this is a fixed top-down projection only (X horizontal, Z
//     vertical, Y/height dropped), with pinch/drag zoom+pan instead of the web's OrbitControls.
//
//  Kept faithful to the web version:
//   - Same corner-role bucketing + greedy nearest-match "sheet" grouping
//     (buildCornerSheets), so multiple physical reference sheets in one session are each
//     connected independently, not into one tangled shape.
//   - Same oriented-rectangle construction for 2 diagonal corners (using the sheet's own
//     bounding_box edge direction, not world X/Z) and same 4-corner closed-quad case.
//   - Same formatDistance rounding convention (mm below 1m, meters with 2 decimals above).
//

import SwiftUI
import simd

/// One pin's worth of data the minimap needs — position + class (for color/shape lookup) +
/// bounding box (for a corner-flagged pin's real edge direction). Deliberately a separate,
/// lightweight type rather than reusing `Pin`/`CreatePin` — this is built up locally as pins are
/// placed (see `RepairARSessionView.allPins`) and needs to survive past the point a pin's
/// `CreatePin` payload is flushed and dropped from `pendingPinsBuffer`.
struct RepairMiniMapPin: Identifiable {
    let id: UUID
    let position: SIMD3<Float>
    let detectionClass: String
    let boundingBox: [SIMD3<Float>]?
}

private typealias Sheet = [RepairMarkerCorner: RepairMiniMapView.CornerPin]

struct RepairMiniMapView: View {
    let pins: [RepairMiniMapPin]
    let classStyles: [String: RepairClassStyle]?

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Flat "map rotation" around the view's own vertical (viewing) axis — independent of
    /// zoom/pan, same idea as the web viewer's RotationDial, just driven here by a two-finger
    /// twist gesture and +/- buttons instead of a dedicated dial control.
    @State private var rotationDeg: Double = 0
    @State private var lastRotationDeg: Double = 0

    private let minScale: CGFloat = 0.3
    private let maxScale: CGFloat = 8

    /// A corner-flagged pin's recentered position + bounding box, bucketed by its
    /// `RepairClassStyle.corner` role — mirrors the web's `CornerPin` type exactly.
    struct CornerPin {
        let pos: SIMD3<Float>
        let boundingBox: [SIMD3<Float>]?
    }

    private static let cornerRoles: [RepairMarkerCorner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    private static let boxEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]

    private var centroid: SIMD3<Float> {
        guard !pins.isEmpty else { return .zero }
        let sum = pins.reduce(SIMD3<Float>.zero) { $0 + $1.position }
        return sum / Float(pins.count)
    }

    /// Radius in the X/Z (top-down) plane only — this view never shows height, so fitting the
    /// projection to X/Z alone (rather than the web's full 3-D radius) frames tighter.
    private var boundingRadius: Float {
        guard !pins.isEmpty else { return 1 }
        let c = centroid
        var maxDist: Float = 0
        for pin in pins {
            let d = pin.position - c
            maxDist = max(maxDist, sqrt(d.x * d.x + d.z * d.z))
        }
        return max(maxDist, 0.05)
    }

    private var sheets: [Sheet] {
        Self.buildCornerSheets(pins: pins, classStyles: classStyles, centroid: centroid)
    }

    /// ARKit world space is session-relative with no shared absolute frame (00 §0.4), so there's
    /// no "true" orientation to align to — but the operator still wants the picture to *look*
    /// like a plan view where `top_left`-flagged pins (e.g. `l1`) sit toward the top-left of the
    /// screen, matching the physical reference sheet's own labeling. This computes the rotation
    /// that best achieves that: average the recentered position of every `top_left` pin, then
    /// solve for the angle that rotates that average vector to point toward the screen's
    /// top-left diagonal (up and to the left). Best-effort/approximate by nature — with only 1-2
    /// `top_left` pins and no real compass reference, this is a bias, not a guarantee, and it's
    /// exactly what was asked for ("I know we don't have proper orientation there, but...").
    /// Returns 0 (no bias) when there's no `top_left` pin to anchor on.
    private var topLeftBiasDegrees: Double {
        let c = centroid
        let topLeftOffsets = pins.compactMap { pin -> SIMD3<Float>? in
            guard classStyles?[pin.detectionClass]?.corner == .topLeft else { return nil }
            return pin.position - c
        }
        guard !topLeftOffsets.isEmpty else { return 0 }

        let sum = topLeftOffsets.reduce(SIMD3<Float>.zero, +)
        let avg = sum / Float(topLeftOffsets.count)
        let magnitude = sqrt(avg.x * avg.x + avg.z * avg.z)
        guard magnitude > 1e-4 else { return 0 }

        // Rotating the canvas by `rotationDeg` (via .rotationEffect) rotates every projected
        // (x, z) pair by that same angle, which simply adds `rotationDeg` to the pair's own
        // atan2 angle — so solving "what angle takes the current l1 direction to the top-left
        // diagonal" is just target minus current.
        let currentAngle = atan2(Double(avg.z), Double(avg.x))
        let targetAngle = atan2(-1.0, -1.0) // up-and-left in canvas space (x right, z down)
        var delta = (targetAngle - currentAngle) * 180 / .pi
        delta = delta.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geo in
                    Canvas { context, size in
                        draw(context: &context, size: size)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .background(Color.white)
                    .rotationEffect(.degrees(rotationDeg))
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        scale = min(max(lastScale * value, minScale), maxScale)
                                    }
                                    .onEnded { _ in lastScale = scale },
                                DragGesture()
                                    .onChanged { value in
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in lastOffset = offset }
                            ),
                            RotationGesture()
                                .onChanged { angle in
                                    rotationDeg = lastRotationDeg + angle.degrees
                                }
                                .onEnded { _ in lastRotationDeg = rotationDeg }
                        )
                    )
                    .onTapGesture(count: 2) {
                        rotate(to: topLeftBiasDegrees)
                        withAnimation(.easeOut(duration: 0.2)) {
                            scale = 1
                            offset = .zero
                        }
                        lastScale = 1
                        lastOffset = .zero
                    }
                    .clipped()
                }
                .background(Color.white)
                .onAppear {
                    rotationDeg = topLeftBiasDegrees
                    lastRotationDeg = rotationDeg
                }

                legend
                    .padding(12)

                viewControls
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .navigationTitle("Pins Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Zoom +/- and clockwise/counterclockwise rotation controls grouped together (in addition
    /// to the pinch-zoom/two-finger-twist gestures on the canvas itself), plus the current
    /// rotation angle — mirroring the web viewer's zoom buttons + rotation dial + readout/reset
    /// in a simpler tap-based form suited to a small on-device preview.
    private var viewControls: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    scale = min(scale * 1.25, maxScale)
                }
                lastScale = scale
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    scale = max(scale / 1.25, minScale)
                }
                lastScale = scale
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }

            Divider().frame(height: 16)

            Button {
                rotate(by: -15)
            } label: {
                Image(systemName: "rotate.left")
            }
            Text("\(Int(rotationDeg.rounded()))°")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(minWidth: 32)
            Button {
                rotate(by: 15)
            } label: {
                Image(systemName: "rotate.right")
            }
            if abs(rotationDeg - topLeftBiasDegrees) > 0.5 {
                Button("Reset") {
                    rotate(to: topLeftBiasDegrees)
                }
                .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func rotate(by degreesDelta: Double) {
        withAnimation(.easeOut(duration: 0.15)) {
            rotationDeg += degreesDelta
        }
        lastRotationDeg = rotationDeg
    }

    private func rotate(to degrees: Double) {
        withAnimation(.easeOut(duration: 0.15)) {
            rotationDeg = degrees
        }
        lastRotationDeg = degrees
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(pins.count) pin\(pins.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(distinctClasses, id: \.self) { className in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: className))
                        .frame(width: 8, height: 8)
                    Text(className)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var distinctClasses: [String] {
        Array(Set(pins.map { $0.detectionClass })).sorted()
    }

    private func color(for detectionClass: String) -> Color {
        if let hex = classStyles?[detectionClass]?.color, let uiColor = UIColor(hex: hex) {
            return Color(uiColor)
        }
        return .red
    }

    // MARK: - Drawing

    private func pixelsPerMeter(for size: CGSize) -> CGFloat {
        let margin: CGFloat = 0.42
        let minSide = min(size.width, size.height)
        return (minSide * margin) / CGFloat(boundingRadius)
    }

    /// World (x, z), already recentered on `centroid`, mapped to canvas pixels. Screen-right =
    /// world +X, screen-down = world +Z (i.e. screen-up = world -Z) — same convention the web
    /// viewer's top-down camera uses (see its comment on rotation direction).
    private func project(_ p: SIMD3<Float>, center: CGPoint, pixelsPerMeter: CGFloat) -> CGPoint {
        let recentered = p - centroid
        return CGPoint(
            x: center.x + CGFloat(recentered.x) * pixelsPerMeter,
            y: center.y + CGFloat(recentered.z) * pixelsPerMeter
        )
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ppm = pixelsPerMeter(for: size)

        for sheet in sheets {
            drawSheet(sheet, context: &context, center: center, pixelsPerMeter: ppm)
        }

        for pin in pins {
            let p = project(pin.position, center: center, pixelsPerMeter: ppm)
            let c = color(for: pin.detectionClass)
            let dotRect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: dotRect), with: .color(c))
            context.stroke(Path(ellipseIn: dotRect), with: .color(.black.opacity(0.35)), lineWidth: 1)
        }
    }

    /// Renders one sheet's connecting shape — mirrors CornerConnections' switch on
    /// `present.count` (web `pin-3d-viewer.tsx`), minus the 3-corner "ply drop" case which is
    /// intentionally left undrawn here.
    private func drawSheet(_ sheet: Sheet, context: inout GraphicsContext, center: CGPoint, pixelsPerMeter ppm: CGFloat) {
        let present = Self.cornerRoles.filter { sheet[$0] != nil }
        guard present.count >= 2 else { return }

        func projected(_ pos: SIMD3<Float>) -> CGPoint {
            CGPoint(x: center.x + CGFloat(pos.x) * ppm, y: center.y + CGFloat(pos.z) * ppm)
        }

        let dash: [CGFloat] = [6, 4]

        if present.count == 4 {
            let order: [RepairMarkerCorner] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .topLeft]
            let corners = order.map { sheet[$0]!.pos }
            let screenPoints = corners.map { projected($0) }

            var path = Path()
            for (i, pt) in screenPoints.enumerated() {
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            context.stroke(path, with: .color(Color(white: 0.45)), style: StrokeStyle(lineWidth: 1.5, dash: dash))

            // This quad is built directly from the 4 raw corner positions (unlike the
            // 2-diagonal-corner case below, there's no oriented-rectangle math forcing right
            // angles), so opposite sides aren't assumed equal — label every edge rather than
            // just two "width"/"height" values.
            for i in 0..<4 {
                let a = corners[i]
                let b = corners[i + 1]
                let mid = CGPoint(x: (screenPoints[i].x + screenPoints[i + 1].x) / 2, y: (screenPoints[i].y + screenPoints[i + 1].y) / 2)
                let d = a - b
                let distance = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
                drawLabel(Self.formatDistance(distance), at: mid, context: &context)
            }
            return
        }

        // present.count == 2 or 3 (the "ply drop" 3-corner case is deliberately left undrawn —
        // it falls through this guard with no explicit `if present.count == 3` branch).
        guard present.count == 2 else { return }

        let roleA = present[0]
        let roleB = present[1]
        let a = sheet[roleA]!
        let b = sheet[roleB]!
        let isDiagonal = (roleA == .topLeft && roleB == .bottomRight) || (roleA == .topRight && roleB == .bottomLeft)

        if isDiagonal {
            let dirXZ = Self.sheetXZDirection(boundingBox: a.boundingBox, point: a.pos)
                ?? Self.sheetXZDirection(boundingBox: b.boundingBox, point: b.pos)
            let rect = Self.orientedRectangle(l: a.pos, r: b.pos, dirXZ: dirXZ)

            var path = Path()
            for (i, pt) in rect.points.enumerated() {
                let screen = CGPoint(x: center.x + CGFloat(pt.x) * ppm, y: center.y + CGFloat(pt.y) * ppm)
                if i == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
            }
            context.stroke(path, with: .color(Color(white: 0.45)), style: StrokeStyle(lineWidth: 1.5, dash: dash))

            let widthMid = CGPoint(
                x: center.x + CGFloat(a.pos.x + rect.cornerA.x) / 2 * ppm,
                y: center.y + CGFloat(a.pos.z + rect.cornerA.y) / 2 * ppm
            )
            let heightMid = CGPoint(
                x: center.x + CGFloat(rect.cornerA.x + b.pos.x) / 2 * ppm,
                y: center.y + CGFloat(rect.cornerA.y + b.pos.z) / 2 * ppm
            )
            drawLabel(Self.formatDistance(rect.widthM), at: widthMid, context: &context)
            drawLabel(Self.formatDistance(rect.heightM), at: heightMid, context: &context)
            return
        }

        let pa = projected(a.pos)
        let pb = projected(b.pos)
        var path = Path()
        path.move(to: pa)
        path.addLine(to: pb)
        context.stroke(path, with: .color(Color(white: 0.45)), style: StrokeStyle(lineWidth: 1.5, dash: dash))

        let mid = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
        let d = a.pos - b.pos
        let distance = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        drawLabel(Self.formatDistance(distance), at: mid, context: &context)
    }

    private func drawLabel(_ text: String, at point: CGPoint, context: inout GraphicsContext) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
        )
        let labelSize = resolved.measure(in: CGSize(width: 200, height: 40))
        let bgRect = CGRect(
            x: point.x - labelSize.width / 2 - 4,
            y: point.y - labelSize.height / 2 - 2,
            width: labelSize.width + 8,
            height: labelSize.height + 4
        )
        context.fill(RoundedRectangle(cornerRadius: 5).path(in: bgRect), with: .color(.white.opacity(0.9)))
        context.draw(resolved, at: point, anchor: .center)
    }

    // MARK: - Corner-sheet grouping

    /// Groups ALL corner-flagged pins into concentric "sheets", outermost first — e.g. if the
    /// same two diagonal corners (say `l1`/`r1`) were each placed twice at different distances
    /// from the reference point, this pairs the farthest `l1` with the farthest `r1` (the
    /// outer/largest rectangle), then the next-farthest `l1` with the next-farthest `r1` (the
    /// next rectangle in), and so on — rather than pairing whichever raw pins happen to be
    /// nearest each other, which can cross rings and draw overlapping, non-concentric shapes
    /// (the bug this replaced: two `l1`+two `r1` pins rendered as two crossed, arbitrarily-sized
    /// rectangles instead of one rectangle nested inside the other).
    ///
    /// Concretely: each role's bucket is sorted by distance from `centroid` (farthest first),
    /// then sheet `i` takes the `i`-th entry from every role bucket that still has one. Ranks
    /// beyond the shortest non-empty bucket's length are simply not formed — "pair as many as
    /// you can, then stop" — so a role with more duplicate placements than another leaves its
    /// extra pins undrawn (still rendered as plain dots by the caller) rather than forcing a
    /// mismatched pairing.
    private static func buildCornerSheets(
        pins: [RepairMiniMapPin],
        classStyles: [String: RepairClassStyle]?,
        centroid: SIMD3<Float>
    ) -> [Sheet] {
        var buckets: [RepairMarkerCorner: [CornerPin]] = [.topLeft: [], .topRight: [], .bottomLeft: [], .bottomRight: []]
        for pin in pins {
            guard let corner = classStyles?[pin.detectionClass]?.corner else { continue }
            buckets[corner, default: []].append(CornerPin(pos: pin.position - centroid, boundingBox: pin.boundingBox))
        }

        for role in cornerRoles {
            buckets[role]?.sort { simd_length($0.pos) > simd_length($1.pos) }
        }

        let nonEmptyCounts = cornerRoles.compactMap { role -> Int? in
            let count = buckets[role]?.count ?? 0
            return count > 0 ? count : nil
        }
        // Need at least 2 roles present to form any 2+-corner shape at all.
        guard nonEmptyCounts.count >= 2, let ringCount = nonEmptyCounts.min() else { return [] }

        var sheets: [Sheet] = []
        for ring in 0..<ringCount {
            var sheet: Sheet = [:]
            for role in cornerRoles {
                if let bucket = buckets[role], ring < bucket.count {
                    sheet[role] = bucket[ring]
                }
            }
            sheets.append(sheet)
        }
        return sheets
    }

    private static func nearestCornerIndex(_ corners: [SIMD3<Float>], to point: SIMD3<Float>) -> Int {
        var nearestIdx = 0
        var bestDistSq = Float.greatestFiniteMagnitude
        for (i, c) in corners.enumerated() {
            let d = c - point
            let distSq = d.x * d.x + d.y * d.y + d.z * d.z
            if distSq < bestDistSq {
                bestDistSq = distSq
                nearestIdx = i
            }
        }
        return nearestIdx
    }

    /// The horizontal (X/Z) direction of a corner-flagged pin's own nearest bounding_box edge —
    /// the real rotation of the physical reference sheet in this session's world frame, exactly
    /// as the web's `sheetXZDirection` reads it. `boundingBox` corners are expected already
    /// recentered on the same centroid as `point` (both come from the same `CornerPin`).
    private static func sheetXZDirection(boundingBox: [SIMD3<Float>]?, point: SIMD3<Float>) -> SIMD2<Float>? {
        guard let boundingBox, boundingBox.count >= 8 else { return nil }
        let anchorIdx = nearestCornerIndex(boundingBox, to: point)
        let anchor = boundingBox[anchorIdx]
        let neighborIdx = boxEdges
            .filter { $0.0 == anchorIdx || $0.1 == anchorIdx }
            .map { $0.0 == anchorIdx ? $0.1 : $0.0 }
        let longest = neighborIdx
            .map { boundingBox[$0] - anchor }
            .sorted { simd_length($0) > simd_length($1) }
            .first
        guard let longest else { return nil }
        let xz = SIMD2<Float>(longest.x, longest.z)
        let lenSq = xz.x * xz.x + xz.y * xz.y
        guard lenSq > 1e-10 else { return nil }
        return xz / sqrt(lenSq)
    }

    /// Rectangle with `l`/`r` as opposite (diagonal) corners, sides parallel to `dirXZ` (the
    /// sheet's real edge direction) rather than world X/Z — same construction as the web's
    /// `orientedRectangle`. Returns points/corners in the recentered X/Z plane (Y dropped).
    private struct OrientedRectangleResult {
        let points: [SIMD2<Float>]
        let cornerA: SIMD2<Float>
        let cornerB: SIMD2<Float>
        let widthM: Float
        let heightM: Float
    }

    private static func orientedRectangle(l: SIMD3<Float>, r: SIMD3<Float>, dirXZ: SIMD2<Float>?) -> OrientedRectangleResult {
        let u = dirXZ ?? SIMD2<Float>(1, 0)
        let v = SIMD2<Float>(-u.y, u.x)

        let diff = SIMD2<Float>(r.x - l.x, r.z - l.z)
        let pu = diff.x * u.x + diff.y * u.y
        let pv = diff.x * v.x + diff.y * v.y

        let lXZ = SIMD2<Float>(l.x, l.z)
        let rXZ = SIMD2<Float>(r.x, r.z)
        let cornerA = SIMD2<Float>(l.x + u.x * pu, l.z + u.y * pu)
        let cornerB = SIMD2<Float>(l.x + v.x * pv, l.z + v.y * pv)

        return OrientedRectangleResult(
            points: [lXZ, cornerA, rXZ, cornerB, lXZ],
            cornerA: cornerA,
            cornerB: cornerB,
            widthM: abs(pu),
            heightM: abs(pv)
        )
    }

    /// Same rounding convention as the web's `formatDistance`: millimeters (rounded) below 1m,
    /// meters with 2 decimals at/above 1m.
    private static func formatDistance(_ meters: Float) -> String {
        if meters < 1 {
            return "\(Int((meters * 1000).rounded())) mm"
        }
        return String(format: "%.2f m", meters)
    }
}
