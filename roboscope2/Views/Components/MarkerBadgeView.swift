//
//  MarkerBadgeView.swift
//  roboscope2
//
//  Extracted badge view showing marker metrics/details.
//

import SwiftUI

struct MarkerBadgeView: View {
    let info: SpatialMarkerService.MarkerInfo
    var details: MarkerDetails? = nil
    var onDelete: (() -> Void)? = nil
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                if let details = details {
                    Text("Marker Details")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().background(Color.white.opacity(0.3))
                    HStack(spacing: 20) {
                        VStack(spacing: 4) {
                            Text("Long Size").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f m", details.longSize)).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 30)
                        VStack(spacing: 4) {
                            Text("Cross Size").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f m", details.crossSize)).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    Divider().background(Color.white.opacity(0.3))
                    VStack(spacing: 8) {
                        Text("Edge Distances")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            EdgeDistanceView(label: "X- (Left)", distance: details.xNegative, color: .blue)
                            EdgeDistanceView(label: "X+ (Right)", distance: details.xPositive, color: .green)
                            EdgeDistanceView(label: "Z- (Near)", distance: details.zNegative, color: .orange)
                            EdgeDistanceView(label: "Z+ (Far)", distance: details.zPositive, color: .purple)
                        }
                    }
                    Divider().background(Color.white.opacity(0.3))
                    HStack(spacing: 20) {
                        VStack(spacing: 4) {
                            Text("Long (Z)").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f m", details.centerLocationLong)).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                        }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 30)
                        VStack(spacing: 4) {
                            Text("Cross (X)").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f m", details.centerLocationCross)).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                        }
                    }
                } else {
                    HStack(spacing: 20) {
                        VStack(spacing: 4) {
                            Text("Width").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f m", info.width)).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 30)
                        VStack(spacing: 4) {
                            Text("Length").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f m", info.length)).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        }
                    }
                    Divider().background(Color.white.opacity(0.3))
                    HStack(spacing: 20) {
                        VStack(spacing: 4) {
                            Text("X").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f", info.centerX)).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                        }
                        Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 30)
                        VStack(spacing: 4) {
                            Text("Z").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                            Text(String(format: "%.2f", info.centerZ)).font(.system(size: 14, weight: .medium)).foregroundColor(.white)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.3), .white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 12, weight: .bold))
                        .padding(8)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.7), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                }
                .offset(x: 8, y: -8)
            }
        }
    }
}
