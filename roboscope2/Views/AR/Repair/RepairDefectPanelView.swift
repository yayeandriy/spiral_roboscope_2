//
//  RepairDefectPanelView.swift
//  roboscope2
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//
//  Placeholder "defect record" panel, surfaced from the beige badge on the main AR viewport
//  once at least one left-side AND one right-side reference marker have been placed in the
//  current Planning session (see RepairARSessionView.hasLeftAndRightMarkers) — i.e. once a full
//  BOD reference frame is visible, there's presumably a known defect at that location worth
//  surfacing.
//
//  IMPORTANT: every value shown here — QCRID, defect type, BOD geometry, ply count, blade/shell
//  type, the layup table, the chamfering drawing — is HARD-CODED MOCK DATA. There is no
//  defect-record API yet; this exists purely as a placeholder for what a future real panel
//  should look and feel like (loosely modeled on the old Roboscope inspection sheet), which is
//  why it carries an unmissable "PLACEHOLDER" banner rather than looking like live data.
//

import SwiftUI

/// Programmatic navigation target for the two reference buttons below. Using `.navigationDestination(item:)`
/// with plain `Button`s — rather than two side-by-side `NavigationLink`s sharing one Form row —
/// avoids a well-known List/NavigationLink quirk where a row containing more than one
/// NavigationLink can stop responding to taps after the first push+pop cycle.
enum RepairDefectRoute: Hashable {
    case chamfering
    case layup
}

/// One row of the placeholder layup table — mirrors the essential columns of the real per-project
/// layup CSV export (stack_order, ply_number, ply_group, material, width) without dragging the
/// other ~15 geometry columns into a phone-sized table.
struct RepairMockLayupPly: Identifiable {
    let id = UUID()
    let stackOrder: Int
    let plyNumber: Int
    let group: String
    let material: String
    let widthMm: Int
}

struct RepairDefectPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var route: RepairDefectRoute?

    /// Placeholder BOD (Bond/Overlap Detection area) geometry, in mm, raw-frame coordinates
    /// (same Z/X convention as the layup CSV's `defect_z_mm`/`defect_x_mm`/`defect_size_*_mm`
    /// columns). Center + size are the two "given" numbers; the four edge measurements below are
    /// derived from them rather than independently hard-coded, so they always stay consistent.
    private static let bodCenterZmm = 32000
    private static let bodCenterXmm = -390
    private static let bodSizeLongitudinalMm = 750  // Z extent
    private static let bodSizeTransversalMm = 200   // X extent

    /// Root is the lower-Z edge, tip the higher-Z edge (Z increases root -> tip along the blade).
    private static var bodRootZmm: Int { bodCenterZmm - bodSizeLongitudinalMm / 2 }
    private static var bodTipZmm: Int { bodCenterZmm + bodSizeLongitudinalMm / 2 }
    /// Leading edge is the less-negative/higher-X edge, trailing edge the more-negative/lower-X
    /// edge (matches the layup CSV's LE_proxy > 0, TE_proxy < 0 convention).
    private static var bodLeadingEdgeXmm: Int { bodCenterXmm + bodSizeTransversalMm / 2 }
    private static var bodTrailingEdgeXmm: Int { bodCenterXmm - bodSizeTransversalMm / 2 }

    /// The layup stack's own reference Z — deliberately a few centimeters off the BOD center
    /// (31950 vs. 32000) rather than reusing the same round number, so it reads as its own
    /// distinct measurement instead of an approximation of the BOD location.
    private static let layupZmm = 31950

    /// Placeholder record metadata shown below BOD — timestamp deliberately set in the past
    /// (mock data has no "live" clock) and a placeholder operator name.
    private static let recordTimestamp = "Feb 18, 2026 · 09:42"
    private static let operatorName = "Rui Almeida"

    /// Hard-coded placeholder layup, matching the ply numbers called out in the placeholder
    /// chamfering drawing (229 -> 208 -> 206 -> 204 -> 203 -> 174 -> 168, "7 plies" affected).
    private static let plies: [RepairMockLayupPly] = [
        .init(stackOrder: 1, plyNumber: 3, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 2, plyNumber: 5, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 3, plyNumber: 12, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 4, plyNumber: 13, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 5, plyNumber: 17, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 6, plyNumber: 40, group: "Uniaxial", material: "Unidirectional Laminate U412", widthMm: 800),
        .init(stackOrder: 7, plyNumber: 42, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 8, plyNumber: 44, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 9, plyNumber: 46, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 10, plyNumber: 48, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 11, plyNumber: 50, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 12, plyNumber: 58, group: "Uniaxial", material: "Unidirectional Laminate U412", widthMm: 800),
        .init(stackOrder: 13, plyNumber: 78, group: "Uniaxial", material: "Unidirectional Laminate U412", widthMm: 800),
        .init(stackOrder: 14, plyNumber: 102, group: "Uniaxial", material: "Unidirectional Laminate U412", widthMm: 800),
        .init(stackOrder: 15, plyNumber: 136, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 16, plyNumber: 138, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 17, plyNumber: 140, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 18, plyNumber: 142, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 19, plyNumber: 144, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 20, plyNumber: 148, group: "Uniaxial", material: "Unidirectional Laminate U412", widthMm: 800),
        .init(stackOrder: 21, plyNumber: 1640, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 22, plyNumber: 1660, group: "Uniaxial", material: "Linear-Fiber Sheet L871", widthMm: 800),
        .init(stackOrder: 23, plyNumber: 168, group: "Uniaxial", material: "Unidirectional Laminate U412", widthMm: 800),
        .init(stackOrder: 24, plyNumber: 174, group: "Uniaxial", material: "Unidirectional Laminate U412", widthMm: 800),
        .init(stackOrder: 25, plyNumber: 203, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 26, plyNumber: 204, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 27, plyNumber: 206, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 28, plyNumber: 208, group: "Biaxial", material: "Reinforced Mesh T450", widthMm: 1250),
        .init(stackOrder: 29, plyNumber: 229, group: "Biaxial", material: "Textile-Laminate F1280", widthMm: 920),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    detailRow(label: "QCRID", value: "032QN028705")
                    detailRow(label: "Defect Type", value: "LCM")
                    detailRow(label: "Defect Level", value: "Level 2")
                    detailRow(label: "Plies Affected", value: "7")
                    detailRow(label: "Arm Type", value: "75.2 meters")
                    detailRow(label: "Shell Type", value: "Pressure Side")
                }

                // Plain in-flow row between Details and BOD (no separate non-scrolling panel —
                // everything scrolls together as one Form).
                Section {
                    referenceButtonsBar
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 4)
                }

                Section("BOD") {
                    detailRow(label: "Center (Z / X)", value: "\(Self.bodCenterZmm) mm / \(Self.bodCenterXmm) mm")
                    detailRow(label: "Size (Long × Transv)", value: "\(Self.bodSizeLongitudinalMm) mm × \(Self.bodSizeTransversalMm) mm")
                    detailRow(label: "Root side (Z)", value: "\(Self.bodRootZmm) mm")
                    detailRow(label: "Tip side (Z)", value: "\(Self.bodTipZmm) mm")
                    detailRow(label: "Leading edge (X)", value: "\(Self.bodLeadingEdgeXmm) mm")
                    detailRow(label: "Trailing edge (X)", value: "\(Self.bodTrailingEdgeXmm) mm")
                }

                Section("Other Details") {
                    detailRow(label: "Time", value: Self.recordTimestamp)
                    detailRow(label: "Operator", value: Self.operatorName)
                }

                Section {
                    placeholderBanner
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Defect Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $route) { route in
                switch route {
                case .chamfering:
                    RepairMockChamferingDrawingView()
                case .layup:
                    RepairMockLayupTableView(plies: Self.plies, zMillimeters: Self.layupZmm)
                }
            }
        }
    }

    /// Two equally-sized, neutral reference buttons — deliberately styled after a standard
    /// system tile (subtle fill + hairline border + a single colored icon) rather than a
    /// full-bleed saturated color block, per operator feedback that the earlier bright/irregular
    /// version looked unpolished. Plain `Button`s driving `route` (not `NavigationLink`s) — see
    /// `RepairDefectRoute` for why: no disclosure chevron, and no List-row tap-tracking quirk.
    private var referenceButtonsBar: some View {
        HStack(spacing: 12) {
            Button {
                route = .chamfering
            } label: {
                referenceButtonLabel(title: "Chamfering Drawing", icon: "square.on.square.dashed", tint: .blue)
            }
            Button {
                route = .layup
            } label: {
                referenceButtonLabel(title: "Layup", icon: "square.stack.3d.up.fill", tint: .orange)
            }
        }
        .buttonStyle(.plain)
    }

    private func referenceButtonLabel(title: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Fixed height (not minHeight) so both tiles match exactly regardless of a 1- vs.
        // 2-line title — this is what made the previous version look irregular/mismatched.
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .tertiarySystemFill)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        // Whole tile responds to taps, not just the icon/text glyphs.
        .contentShape(Rectangle())
    }

    /// Back to the original bright/unmissable styling — the toned-down version was a step too
    /// far; bright is fine as long as it's pinned to the very bottom of the screen (it is).
    private var placeholderBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.black)
            Text("PLACEHOLDER — mock data. Live inspection records could be sourced from a Quality Management System (QMS) and the Laminate Repair Tool (LRT).")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.yellow)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Full-screen, pinch-to-zoom placeholder chamfering drawing (static PNG, `Assets.xcassets` ->
/// `ChamferingDrawingZ32m`) — stands in for a future per-defect drawing lookup. Fits the whole
/// drawing on screen by default (no cropping, no manual scroll needed), then lets the operator
/// pinch/double-tap to zoom and drag to pan once zoomed in.
struct RepairMockChamferingDrawingView: View {
    var body: some View {
        ZoomableImageView(image: Image("ChamferingDrawingZ32m"))
            .navigationTitle("Chamfering Drawing")
            .navigationBarTitleDisplayMode(.inline)
            .ignoresSafeArea(edges: .bottom)
    }
}

/// Placeholder ply-by-ply layup table for this defect's location, condensed from the real
/// per-project layup CSV export down to the columns a technician actually needs at a glance.
struct RepairMockLayupTableView: View {
    let plies: [RepairMockLayupPly]
    let zMillimeters: Int

    var body: some View {
        List(plies) { ply in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ply #\(ply.plyNumber)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(ply.material)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(ply.group)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(groupColor(for: ply.group))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(groupColor(for: ply.group).opacity(0.12))
                        .clipShape(Capsule())
                    Text("\(ply.widthMm) mm")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
        .navigationTitle("Layup · Z \(zMillimeters) mm")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func groupColor(for group: String) -> Color {
        group == "Biaxial" ? .red : .blue
    }
}

/// Fits an image tightly inside its container at rest (no overflow, no manual scrolling needed),
/// then supports pinch-to-zoom (clamped 1x–6x), drag-to-pan once zoomed, and double-tap to
/// toggle between fit and 2x. Generic/self-contained — not tied to the chamfering drawing
/// specifically, so it can be reused for any other reference image later.
struct ZoomableImageView: View {
    let image: Image

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            image
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, minScale), maxScale)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= minScale {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        offset = .zero
                                    }
                                    lastOffset = .zero
                                }
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > minScale else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if scale > minScale {
                            scale = minScale
                            offset = .zero
                        } else {
                            scale = 2
                        }
                    }
                    lastScale = scale
                    lastOffset = offset
                }
        }
        .clipped()
    }
}
