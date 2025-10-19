# SwiftUI Views Guide - Roboscope 2 API

Pre-built SwiftUI views and components for the Roboscope 2 API integration.

## Table of Contents

1. [Overview](#overview)
2. [Space Management Views](#space-management-views)
3. [Work Session Views](#work-session-views)
4. [Marker Management Views](#marker-management-views)
5. [View Models](#view-models)
6. [Reusable Components](#reusable-components)

---

## Overview

This guide provides ready-to-use SwiftUI views for:
- Browsing and managing spaces
- Creating and editing work sessions
- Viewing and creating markers
- Real-time collaboration indicators

---

## Space Management Views

### SpaceListView.swift

```swift
import SwiftUI

struct SpaceListView: View {
    @StateObject private var viewModel = SpaceListViewModel()
    @State private var showCreateSheet = false
    
    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading && viewModel.spaces.isEmpty {
                    ProgressView("Loading spaces...")
                } else if viewModel.spaces.isEmpty {
                    emptyStateView
                } else {
                    spacesList
                }
            }
            .navigationTitle("Spaces")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateSpaceView { newSpace in
                    viewModel.spaces.append(newSpace)
                }
            }
            .refreshable {
                await viewModel.loadSpaces()
            }
            .alert("Error", isPresented: .constant(viewModel.error != nil)) {
                Button("OK") {
                    viewModel.error = nil
                }
            } message: {
                if let error = viewModel.error {
                    Text(error)
                }
            }
        }
    }
    
    private var spacesList: some View {
        List {
            ForEach(viewModel.spaces) { space in
                NavigationLink(destination: SpaceDetailView(space: space)) {
                    SpaceRowView(space: space)
                }
            }
            .onDelete { indexSet in
                Task {
                    await viewModel.deleteSpaces(at: indexSet)
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            
            Text("No Spaces Yet")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Create a space to start managing AR work sessions")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button("Create Space") {
                showCreateSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct SpaceRowView: View {
    let space: Space
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            AsyncImage(url: space.previewUrl.flatMap(URL.init)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure, .empty:
                    Image(systemName: "cube.fill")
                        .foregroundColor(.blue)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 60, height: 60)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(space.name)
                    .font(.headline)
                
                Text(space.key)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let description = space.description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(.gray)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
```

### CreateSpaceView.swift

```swift
import SwiftUI

struct CreateSpaceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = CreateSpaceViewModel()
    
    let onCreate: (Space) -> Void
    
    var body: some View {
        NavigationView {
            Form {
                Section("Basic Information") {
                    TextField("Space Key", text: $viewModel.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    
                    TextField("Name", text: $viewModel.name)
                    
                    TextField("Description", text: $viewModel.description, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section("3D Models") {
                    TextField("GLB Model URL", text: $viewModel.modelGlbUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    
                    TextField("USDC Model URL", text: $viewModel.modelUsdcUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                
                Section("Preview") {
                    TextField("Preview Image URL", text: $viewModel.previewUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
            }
            .navigationTitle("Create Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await viewModel.createSpace()
                        }
                    }
                    .disabled(!viewModel.isValid || viewModel.isLoading)
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                }
            }
            .alert("Error", isPresented: .constant(viewModel.error != nil)) {
                Button("OK") {
                    viewModel.error = nil
                }
            } message: {
                if let error = viewModel.error {
                    Text(error)
                }
            }
            .onChange(of: viewModel.createdSpace) { newSpace in
                if let space = newSpace {
                    onCreate(space)
                    dismiss()
                }
            }
        }
    }
}
```

### SpaceDetailView.swift

```swift
import SwiftUI

struct SpaceDetailView: View {
    let space: Space
    @StateObject private var viewModel: SpaceDetailViewModel
    @State private var showWorkSessionSheet = false
    
    init(space: Space) {
        self.space = space
        _viewModel = StateObject(wrappedValue: SpaceDetailViewModel(space: space))
    }
    
    var body: some View {
        List {
            Section("Space Information") {
                LabeledContent("Key", value: space.key)
                LabeledContent("Name", value: space.name)
                
                if let description = space.description {
                    LabeledContent("Description") {
                        Text(description)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let modelUrl = space.modelGlbUrl ?? space.modelUsdcUrl {
                    LabeledContent("3D Model") {
                        Link("View", destination: URL(string: modelUrl)!)
                    }
                }
            }
            
            Section("Work Sessions") {
                if viewModel.workSessions.isEmpty {
                    Text("No work sessions yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.workSessions) { session in
                        NavigationLink(destination: WorkSessionDetailView(workSession: session)) {
                            WorkSessionRowView(workSession: session)
                        }
                    }
                }
                
                Button("Create Work Session") {
                    showWorkSessionSheet = true
                }
            }
        }
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.loadWorkSessions()
        }
        .refreshable {
            await viewModel.loadWorkSessions()
        }
        .sheet(isPresented: $showWorkSessionSheet) {
            CreateWorkSessionView(spaceId: space.id) { newSession in
                viewModel.workSessions.append(newSession)
            }
        }
    }
}
```

---

## Work Session Views

### WorkSessionListView.swift

```swift
import SwiftUI

struct WorkSessionListView: View {
    @StateObject private var viewModel = WorkSessionListViewModel()
    @State private var filterStatus: WorkSessionStatus?
    @State private var filterType: WorkSessionType?
    
    var body: some View {
        NavigationView {
            VStack {
                // Filters
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        FilterChip(
                            title: "All",
                            isSelected: filterStatus == nil && filterType == nil,
                            action: {
                                filterStatus = nil
                                filterType = nil
                                Task { await viewModel.loadSessions() }
                            }
                        )
                        
                        ForEach([WorkSessionStatus.draft, .active, .done, .archived], id: \.self) { status in
                            FilterChip(
                                title: status.rawValue.capitalized,
                                isSelected: filterStatus == status,
                                action: {
                                    filterStatus = status
                                    Task { await viewModel.loadSessions(status: status) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
                
                // Sessions list
                List(viewModel.workSessions) { session in
                    NavigationLink(destination: WorkSessionDetailView(workSession: session)) {
                        WorkSessionRowView(workSession: session)
                    }
                }
            }
            .navigationTitle("Work Sessions")
            .refreshable {
                await viewModel.loadSessions(status: filterStatus, sessionType: filterType)
            }
        }
    }
}

struct WorkSessionRowView: View {
    let workSession: WorkSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusBadge
                
                Text(workSession.sessionType.rawValue.capitalized)
                    .font(.headline)
                
                Spacer()
                
                Text(workSession.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Label("\(workSession.version)", systemImage: "number")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if let startedAt = workSession.startedAt {
                    Label(startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        Text(workSession.status.rawValue.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.2))
            .foregroundColor(statusColor)
            .cornerRadius(4)
    }
    
    private var statusColor: Color {
        switch workSession.status {
        case .draft: return .gray
        case .active: return .blue
        case .done: return .green
        case .archived: return .orange
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(16)
        }
    }
}
```

### CreateWorkSessionView.swift

```swift
import SwiftUI

struct CreateWorkSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CreateWorkSessionViewModel
    
    let onCreate: (WorkSession) -> Void
    
    init(spaceId: UUID, onCreate: @escaping (WorkSession) -> Void) {
        _viewModel = StateObject(wrappedValue: CreateWorkSessionViewModel(spaceId: spaceId))
        self.onCreate = onCreate
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section("Session Type") {
                    Picker("Type", selection: $viewModel.sessionType) {
                        ForEach([WorkSessionType.inspection, .repair, .other], id: \.self) { type in
                            Text(type.rawValue.capitalized).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Status") {
                    Picker("Status", selection: $viewModel.status) {
                        ForEach([WorkSessionStatus.draft, .active], id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Timing") {
                    Toggle("Start Now", isOn: $viewModel.startNow)
                    
                    if viewModel.startNow {
                        DatePicker("Start Time", selection: $viewModel.startedAt, displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }
            .navigationTitle("New Work Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await viewModel.createSession()
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                }
            }
            .alert("Error", isPresented: .constant(viewModel.error != nil)) {
                Button("OK") {
                    viewModel.error = nil
                }
            } message: {
                if let error = viewModel.error {
                    Text(error)
                }
            }
            .onChange(of: viewModel.createdSession) { newSession in
                if let session = newSession {
                    onCreate(session)
                    dismiss()
                }
            }
        }
    }
}
```

### WorkSessionDetailView.swift

```swift
import SwiftUI

struct WorkSessionDetailView: View {
    let workSession: WorkSession
    @StateObject private var viewModel: WorkSessionDetailViewModel
    @State private var showARView = false
    
    init(workSession: WorkSession) {
        self.workSession = workSession
        _viewModel = StateObject(wrappedValue: WorkSessionDetailViewModel(workSession: workSession))
    }
    
    var body: some View {
        List {
            Section("Session Details") {
                LabeledContent("Type", value: workSession.sessionType.rawValue.capitalized)
                LabeledContent("Status", value: workSession.status.rawValue.capitalized)
                LabeledContent("Version", value: "\(workSession.version)")
                
                if let startedAt = workSession.startedAt {
                    LabeledContent("Started", value: startedAt.formatted())
                }
                
                if let completedAt = workSession.completedAt {
                    LabeledContent("Completed", value: completedAt.formatted())
                }
            }
            
            Section {
                HStack {
                    PresenceIndicator(sessionId: workSession.id)
                    Spacer()
                    SyncIndicatorView(workSessionId: workSession.id)
                }
            }
            
            Section("Markers") {
                if viewModel.markers.isEmpty {
                    Text("No markers yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.markers) { marker in
                        MarkerRowView(marker: marker)
                    }
                }
                
                Button("View in AR") {
                    showARView = true
                }
            }
        }
        .navigationTitle("Work Session")
        .task {
            await viewModel.loadMarkers()
        }
        .refreshable {
            await viewModel.loadMarkers()
        }
        .fullScreenCover(isPresented: $showARView) {
            ARSessionView(
                space: .constant(nil),
                workSession: .constant(workSession),
                markers: $viewModel.markers
            )
        }
    }
}
```

---

## Marker Management Views

### MarkerRowView.swift

```swift
import SwiftUI

struct MarkerRowView: View {
    let marker: Marker
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let label = marker.label {
                    Text(label)
                        .font(.headline)
                } else {
                    Text("Marker")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if let color = marker.color {
                    Circle()
                        .fill(Color(hex: color) ?? .gray)
                        .frame(width: 20, height: 20)
                }
            }
            
            HStack {
                Label("v\(marker.version)", systemImage: "number")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(marker.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
```

---

## View Models

### SpaceListViewModel.swift

```swift
import Foundation
import Combine

@MainActor
class SpaceListViewModel: ObservableObject {
    @Published var spaces: [Space] = []
    @Published var isLoading = false
    @Published var error: String?
    
    private let spaceService = SpaceService.shared
    
    init() {
        Task {
            await loadSpaces()
        }
    }
    
    func loadSpaces() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            spaces = try await spaceService.listSpaces()
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    func deleteSpaces(at offsets: IndexSet) async {
        for index in offsets {
            let space = spaces[index]
            do {
                try await spaceService.deleteSpace(id: space.id)
                spaces.remove(at: index)
            } catch {
                self.error = "Failed to delete space: \(error.localizedDescription)"
            }
        }
    }
}
```

### CreateSpaceViewModel.swift

```swift
import Foundation

@MainActor
class CreateSpaceViewModel: ObservableObject {
    @Published var key = ""
    @Published var name = ""
    @Published var description = ""
    @Published var modelGlbUrl = ""
    @Published var modelUsdcUrl = ""
    @Published var previewUrl = ""
    
    @Published var isLoading = false
    @Published var error: String?
    @Published var createdSpace: Space?
    
    private let spaceService = SpaceService.shared
    
    var isValid: Bool {
        !key.isEmpty && !name.isEmpty
    }
    
    func createSpace() async {
        guard isValid else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        let createSpace = CreateSpace(
            key: key,
            name: name,
            description: description.isEmpty ? nil : description,
            modelGlbUrl: modelGlbUrl.isEmpty ? nil : modelGlbUrl,
            modelUsdcUrl: modelUsdcUrl.isEmpty ? nil : modelUsdcUrl,
            previewUrl: previewUrl.isEmpty ? nil : previewUrl
        )
        
        do {
            createdSpace = try await spaceService.createSpace(createSpace)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

### WorkSessionDetailViewModel.swift

```swift
import Foundation
import Combine

@MainActor
class WorkSessionDetailViewModel: ObservableObject {
    @Published var markers: [Marker] = []
    @Published var isLoading = false
    @Published var error: String?
    
    let workSession: WorkSession
    private let markerService = MarkerService.shared
    private var cancellables = Set<AnyCancellable>()
    
    init(workSession: WorkSession) {
        self.workSession = workSession
        
        // Listen for sync updates
        NotificationCenter.default.publisher(for: .markersDidSync)
            .compactMap { $0.userInfo?["markers"] as? [Marker] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] markers in
                self?.markers = markers
            }
            .store(in: &cancellables)
    }
    
    func loadMarkers() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            markers = try await markerService.listMarkers(workSessionId: workSession.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

---

## Reusable Components

### Color Extension

```swift
import SwiftUI

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        guard hexSanitized.count == 6 else { return nil }
        
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}
```

---

## Next Steps

- [Code Examples](./IOS_CODE_EXAMPLES.md) - Complete working examples
- [Testing Guide](./IOS_TESTING_GUIDE.md) - Unit & integration tests
- [Deployment Guide](./IOS_DEPLOYMENT_GUIDE.md) - App Store submission

