//
//  SpacesListView.swift
//  roboscope2
//
//  Space selection list — shown when no space tab is selected.
//

import SwiftUI

struct SpacesListView: View {
    let spaces: [Space]
    let sessionCounts: [UUID: Int]
    let isLoading: Bool
    let onSelect: (Space) -> Void

    var body: some View {
        Group {
            if isLoading && spaces.isEmpty {
                ProgressView("Loading spaces…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if spaces.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "square.split.2x2")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    Text("No Spaces")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Create a space on the server to get started.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(spaces) { space in
                        Button {
                            onSelect(space)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(space.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    if let desc = space.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                let count = sessionCounts[space.id] ?? 0
                                Text("\(count) session\(count == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.blue.opacity(0.12))
                                    )
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }
}
