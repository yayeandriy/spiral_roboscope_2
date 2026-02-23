//
//  VideoDetectionHistoryPanel.swift
//  roboscope2
//
//  Slide-in panel showing the last 50 detection frames for VideoDetectionView.
//  Each row summarises detected objects and the measured dot→line distance.
//

import SwiftUI

// MARK: - Record type

/// Snapshot of one processed frame's detection results.
struct DetectionFrameRecord: Identifiable {
    let id = UUID()
    let timestamp: Date
    let dots: Int
    let lines: Int
    let otherCount: Int
    /// Scaled distance in fake world metres, nil when no valid dot+line pair was found.
    let distanceMeters: Float?
    /// Diagonal of best-line bbox / diagonal of best-dot bbox. Nil when either class is absent.
    let lineToDotSizeRatio: Float?
}

// MARK: - Panel view

struct VideoDetectionHistoryPanel: View {
    let records: [DetectionFrameRecord]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                Text("Detection History")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("last \(min(records.count, 50)) frames")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().background(Color.white.opacity(0.12))

            if records.isEmpty {
                Text("No frames recorded yet")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 24)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(records.reversed().prefix(50).enumerated()), id: \.element.id) { idx, record in
                            rowView(for: record, index: idx)
                            if idx < min(records.count, 50) - 1 {
                                Divider()
                                    .background(Color.white.opacity(0.07))
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
    }

    @ViewBuilder
    private func rowView(for record: DetectionFrameRecord, index: Int) -> some View {
        // A ratio < 4 means the line box is barely longer than the dot box — likely a bad pair.
        let suspectRatio = record.lineToDotSizeRatio.map { $0 < 4 } ?? false

        HStack(alignment: .center, spacing: 10) {
            // Frame index circle (no badge here any more — indicator moved to right)
            ZStack {
                Circle()
                    .fill(record.distanceMeters != nil ? Color.green.opacity(0.2) : Color.white.opacity(0.06))
                    .frame(width: 28, height: 28)
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(record.distanceMeters != nil ? .green : .white.opacity(0.5))
            }

            // Detection chips + distance
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if record.dots > 0 {
                        detectionChip(label: "\(record.dots) dot\(record.dots > 1 ? "s" : "")", color: .cyan)
                    }
                    if record.lines > 0 {
                        detectionChip(label: "\(record.lines) line\(record.lines > 1 ? "s" : "")", color: .yellow)
                    }
                    if record.otherCount > 0 {
                        detectionChip(label: "\(record.otherCount) other", color: .white)
                    }
                    if record.dots == 0 && record.lines == 0 && record.otherCount == 0 {
                        Text("no detections")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }

                if let d = record.distanceMeters {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 9))
                            .foregroundColor(.green.opacity(0.8))
                        Text(String(format: "%.3f m scaled", d))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                }

                // Relative timestamp
                Text(relativeTime(record.timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer(minLength: 4)

            // Ratio — large, white, between info and the suspect dot
            if let ratio = record.lineToDotSizeRatio {
                let isSuspect = ratio < 4
                VStack(spacing: 1) {
                    Text(String(format: "×%.2f", ratio))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isSuspect ? .red : .white)
                    Text("l/d")
                        .font(.system(size: 9))
                        .foregroundColor(isSuspect ? .red.opacity(0.7) : .white.opacity(0.4))
                }
                .frame(minWidth: 44)
            }

            // Suspect indicator dot — right edge, vertically centered
            Circle()
                .fill(suspectRatio ? Color.red : Color.clear)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(index == 0 ? Color.white.opacity(0.04) : Color.clear)
    }

    private func detectionChip(label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
    }

    private func relativeTime(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 1 { return "now" }
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        return "\(mins)m ago"
    }
}
