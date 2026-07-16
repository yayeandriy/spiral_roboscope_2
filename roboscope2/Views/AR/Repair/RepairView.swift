//
//  RepairView.swift
//  roboscope2
//
//  Top-level "Repair" tab — independent AR inspection workflow with its own space picker
//  and its own session list (RepairSession, Veranda-backed), mirroring the Space -> list
//  pattern used by SessionsView/WorkSession without sharing any state with it.
//
//  "+" creates and starts a repair session immediately (server-default or operator-preferred
//  model from RepairSettings.preferredPlanningModelId — see RepairModelPickerSection in
//  Settings) — there is no intermediate model-picker screen blocking the flow. Always launches
//  in Planning mode (RepairSessionMode); Validation mode is a live in-session switch, not a
//  launch-time choice.
//
//  Part of the Repair module. Does NOT use or modify the Laser Guide / anchoring system.
//

import SwiftUI
import UIKit

struct RepairView: View {
    @StateObject private var spaceService = SpaceService.shared
    @StateObject private var sessionService = RepairSessionService.shared
    @StateObject private var modelRegistry = ModelRegistryService.shared

    @State private var allRepairSessions: [RepairSession] = []
    @State private var isLoadingSessions = false
    @State private var errorMessage: String?

    /// Persisted space tab selection, kept independent of the Sessions tab's own persisted tab.
    @AppStorage("selectedRepairSpaceTabId") private var persistedSpaceId: String = ""
    @State private var selectedTabSpaceId: UUID? = nil

    @State private var launchModel: CoremlModel?
    @State private var activeARSession: RepairSession?
    /// Covers both "creating a brand-new session" and "resuming an existing active one".
    @State private var isLaunchingAR = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if selectedTabSpaceId == nil {
                    SpacesListView(
                        spaces: availableSpaces,
                        sessionCounts: repairSessionCounts,
                        isLoading: false,
                        onSelect: { selectSpaceTab($0.id) }
                    )
                    .padding(.top, 16)
                } else {
                    header
                    sessionsList
                }
            }
            .navigationTitle((selectedTabSpaceId == nil && !availableSpaces.isEmpty) ? "Spaces" : (selectedTabSpaceId == nil ? "" : selectedSpaceName))
            .navigationBarTitleDisplayMode(selectedTabSpaceId == nil ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectedTabSpaceId != nil {
                        Button(action: goBackToSpaces) {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedTabSpaceId != nil {
                        Button(action: { Task { await createAndStartSession() } }) {
                            Image(systemName: "plus")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .disabled(isLaunchingAR)
                    }
                }
            }
            .task { await loadInitialData() }
            .refreshable { await loadAllRepairSessions() }
            .onChange(of: spaceService.spaces) { _, _ in
                resolvePersistedTab()
            }
            .fullScreenCover(item: $activeARSession) { repairSession in
                if let launchModel {
                    RepairARSessionView(session: repairSession, model: launchModel)
                }
            }
            .onChange(of: activeARSession) { oldValue, newValue in
                if oldValue != nil && newValue == nil {
                    Task { await loadAllRepairSessions() }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .overlay {
                if isLaunchingAR {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Starting session…")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("\(filteredRepairSessions.count) repair session\(filteredRepairSessions.count == 1 ? "" : "s")")
                .font(.title3)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        Group {
            if isLoadingSessions && filteredRepairSessions.isEmpty {
                ProgressView("Loading repair sessions...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRepairSessions.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(filteredRepairSessions) { session in
                        RepairSessionRowView(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if session.isActive {
                                    Task { await resume(session) }
                                }
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                // No confirmation here — swipe-to-delete is already a deliberate,
                                // two-step gesture (swipe + tap), unlike the AR viewport's
                                // "Clear All Pins" button which needed its own confirmation.
                                Button(role: .destructive) {
                                    Task { await deleteSession(session) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                if session.isActive {
                                    Button {
                                        Task { await closeSession(session) }
                                    } label: {
                                        Label("Close", systemImage: "checkmark.circle")
                                    }
                                    .tint(.orange)
                                }
                            }
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text("No Repair Sessions Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start a repair session to auto-detect and pin objects in this space.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await createAndStartSession() }
            } label: {
                Label("Start Repair Session", systemImage: "plus")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.orange)
                    .cornerRadius(12)
            }
            .disabled(isLaunchingAR)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed Properties

    private var availableSpaces: [Space] {
        spaceService.spaces.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var filteredRepairSessions: [RepairSession] {
        guard let spaceId = selectedTabSpaceId else { return [] }
        return allRepairSessions
            .filter { $0.spaceId == spaceId.uuidString }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Repair session counts per space, for the badge shown on the space picker.
    private var repairSessionCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for session in allRepairSessions {
            guard let uuid = UUID(uuidString: session.spaceId) else { continue }
            counts[uuid, default: 0] += 1
        }
        return counts
    }

    private var selectedSpaceName: String {
        guard let spaceId = selectedTabSpaceId,
              let space = availableSpaces.first(where: { $0.id == spaceId }) else {
            return "Repair"
        }
        return space.name
    }

    // MARK: - Actions

    private func selectSpaceTab(_ spaceId: UUID) {
        selectedTabSpaceId = spaceId
        persistedSpaceId = spaceId.uuidString
    }

    private func goBackToSpaces() {
        selectedTabSpaceId = nil
        persistedSpaceId = ""
    }

    /// Resolve the persisted tab ID against available spaces. If valid, select it.
    private func resolvePersistedTab() {
        guard !persistedSpaceId.isEmpty,
              let uuid = UUID(uuidString: persistedSpaceId),
              availableSpaces.contains(where: { $0.id == uuid }) else {
            return
        }
        if selectedTabSpaceId != uuid {
            selectedTabSpaceId = uuid
        }
    }

    private func loadInitialData() async {
        _ = try? await spaceService.listSpaces()
        await loadAllRepairSessions()
        resolvePersistedTab()
    }

    private func loadAllRepairSessions() async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            allRepairSessions = try await sessionService.list()
        } catch {
            errorMessage = "Failed to load repair sessions: \(error.localizedDescription)"
        }
    }

    private func resume(_ session: RepairSession) async {
        isLaunchingAR = true
        defer { isLaunchingAR = false }
        do {
            let models = try await modelRegistry.list()
            guard let match = models.first(where: { $0.id == session.coremlModelId }) else {
                errorMessage = "This session's detector model is no longer active."
                return
            }
            launchModel = match
            activeARSession = session
        } catch {
            errorMessage = "Failed to resume session: \(error.localizedDescription)"
        }
    }

    /// Creates a new repair session using the operator-preferred model (RepairSettings, set from
    /// Settings > Repair) if configured and still active, else the server's registry default,
    /// else the first active model — then jumps straight into AR. No model-picker screen.
    private func createAndStartSession() async {
        guard let spaceId = selectedTabSpaceId else { return }
        isLaunchingAR = true
        defer { isLaunchingAR = false }
        do {
            guard let model = try await resolveModelToUse() else {
                errorMessage = "No active detector models are available. An admin needs to upload one to Robovision."
                return
            }
            let created = try await sessionService.create(
                spaceId: spaceId.uuidString,
                spaceNameCache: selectedSpaceName,
                coremlModelId: model.id,
                deviceLabel: UIDevice.current.name
            )
            launchModel = model
            activeARSession = created
            await loadAllRepairSessions()
        } catch {
            errorMessage = "Failed to start repair session: \(error.localizedDescription)"
        }
    }

    private func resolveModelToUse() async throws -> CoremlModel? {
        let models = try await modelRegistry.list()
        guard !models.isEmpty else { return nil }

        if let preferredIdString = RepairSettings.shared.preferredPlanningModelId,
           let preferredUUID = UUID(uuidString: preferredIdString),
           let match = models.first(where: { $0.id == preferredUUID }) {
            return match
        }
        if let def = models.first(where: { $0.isDefaultPlanning == true }) {
            return def
        }
        if let def = try await modelRegistry.getDefault(), let matched = models.first(where: { $0.id == def.id }) {
            return matched
        }
        return models.first
    }

    private func closeSession(_ session: RepairSession) async {
        do {
            _ = try await sessionService.close(id: session.id)
            await loadAllRepairSessions()
        } catch {
            errorMessage = "Failed to close session: \(error.localizedDescription)"
        }
    }

    private func deleteSession(_ session: RepairSession) async {
        do {
            try await sessionService.delete(id: session.id)
            await loadAllRepairSessions()
        } catch {
            errorMessage = "Failed to delete session: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#Preview {
    RepairView()
}

// MARK: - Repair Session Row
//
// Styled to match the existing SessionRowView (Views/Sessions/SessionRowView.swift) card look —
// rounded card, relative-time headline title, secondary subtitle row, and a marker/pin-count
// pill on the trailing edge — so Repair sessions read consistently with regular Roboscope
// sessions rather than as a visually distinct list.

private struct RepairSessionRowView: View {
    let session: RepairSession

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(startedAtText)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            HStack(spacing: 8) {
                Text("Repair")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                statusBadge

                Spacer()

                pinCountIndicator

                if session.isActive {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardStrokeColor, lineWidth: 0.5)
        )
        .shadow(color: cardShadowColor, radius: 6, x: 0, y: 2)
        .opacity(session.isActive ? 1 : 0.6)
    }

    private var startedAtText: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: session.startedAt, relativeTo: Date())
    }

    private var statusBadge: some View {
        Text(session.isActive ? "Active" : "Closed")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(session.isActive ? Color.green : Color.gray))
    }

    @ViewBuilder
    private var pinCountIndicator: some View {
        let count = session.pinCount ?? 0
        if count == 0 {
            Text("Empty")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("\(count) pin\(count == 1 ? "" : "s")")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private var cardStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    private var cardShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.08)
    }
}
