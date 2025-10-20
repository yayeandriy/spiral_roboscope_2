# ARKit Integration Guide - Roboscope 2 API

Complete guide for integrating AR marker visualization using ARKit and RealityKit with the Roboscope 2 API.

## Table of Contents

1. [Overview](#overview)
2. [ARKit Setup](#arkit-setup)
3. [Marker Visualization](#marker-visualization)
4. [3D Model Loading](#3d-model-loading)
5. [Spatial Tracking](#spatial-tracking)
6. [Coordinate Systems](#coordinate-systems)
7. [Performance Optimization](#performance-optimization)

---

## Overview

This guide covers:
- Visualizing API markers in AR space
- Loading and displaying 3D space models (GLB/USDC)
- Synchronizing AR coordinates with backend
- Real-time marker updates in AR view
- Gesture interactions for marker placement

---

## ARKit Setup

### ARViewController.swift

```swift
import UIKit
import ARKit
import RealityKit
import Combine

class ARViewController: UIViewController {
    
    // MARK: - Properties
    
    private var arView: ARView!
    private var cancellables = Set<AnyCancellable>()
    
    private var currentSpace: Space?
    private var currentWorkSession: WorkSession?
    private var markers: [Marker] = []
    
    private var markerEntities: [UUID: ModelEntity] = [:]
    private var spaceModelEntity: ModelEntity?
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        setupGestures()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startARSession()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arView.session.pause()
    }
    
    // MARK: - AR Setup
    
    private func setupARView() {
        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)
        
        // Enable debug options (remove in production)
        #if DEBUG
        arView.debugOptions = [.showFeaturePoints, .showWorldOrigin]
        #endif
    }
    
    private func startARSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        
        // Enable scene reconstruction for spatial awareness
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        
        arView.session.run(configuration)
    }
    
    // MARK: - Gestures
    
    private func setupGestures() {
        // Tap to place marker
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        // Long press to select marker
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        arView.addGestureRecognizer(longPressGesture)
    }
    
    @objc private func handleTap(_ sender: UITapGestureRecognizer) {
        let location = sender.location(in: arView)
        
        // Perform raycast to find 3D position
        guard let raycastResult = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first else {
            return
        }
        
        let worldTransform = raycastResult.worldTransform
        let position = SIMD3<Float>(worldTransform.columns.3.x,
                                    worldTransform.columns.3.y,
                                    worldTransform.columns.3.z)
        
        // Create marker at this position
        Task {
            await createMarkerAtPosition(position)
        }
    }
    
    @objc private func handleLongPress(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began else { return }
        
        let location = sender.location(in: arView)
        
        // Check if we hit a marker
        if let entity = arView.entity(at: location) {
            selectMarker(entity: entity)
        }
    }
    
    // MARK: - Marker Creation
    
    private func createMarkerAtPosition(_ position: SIMD3<Float>) async {
        guard let workSessionId = currentWorkSession?.id else {
            showError("No active work session")
            return
        }
        
        // Create a rectangular marker (4 points)
        let size: Float = 0.1 // 10cm square
        let points = [
            position + SIMD3<Float>(-size/2, 0, -size/2),
            position + SIMD3<Float>(size/2, 0, -size/2),
            position + SIMD3<Float>(size/2, 0, size/2),
            position + SIMD3<Float>(-size/2, 0, size/2)
        ]
        
        let createMarker = CreateMarker(
            workSessionId: workSessionId,
            label: "AR Marker",
            points: points,
            color: "#FF0000"
        )
        
        do {
            let marker = try await MarkerService.shared.createMarker(createMarker)
            await MainActor.run {
                self.markers.append(marker)
                self.visualizeMarker(marker)
            }
        } catch {
            showError("Failed to create marker: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Marker Visualization
    
    private func visualizeMarker(_ marker: Marker) {
        // Create mesh for marker (rectangular plane with 4 corners)
        let mesh = createMarkerMesh(marker: marker)
        
        var material = SimpleMaterial()
        if let colorString = marker.color, let color = parseColor(colorString) {
            material.color = .init(tint: color.withAlphaComponent(0.5))
        } else {
            material.color = .init(tint: .red.withAlphaComponent(0.5))
        }
        
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = marker.id.uuidString
        
        // Add to scene
        let anchor = AnchorEntity(world: marker.point1)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
        
        markerEntities[marker.id] = entity
    }
    
    private func createMarkerMesh(marker: Marker) -> MeshResource {
        // Create a mesh from 4 points
        var descriptor = MeshDescriptor()
        
        let positions: [SIMD3<Float>] = marker.points
        descriptor.positions = MeshBuffer(positions)
        
        // Create indices for triangles (2 triangles make a quad)
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        descriptor.primitives = .triangles(indices)
        
        // Generate mesh
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            print("Failed to generate mesh: \(error)")
            // Fallback to simple plane
            return .generatePlane(width: 0.1, depth: 0.1)
        }
    }
    
    private func updateMarkerVisualization(_ marker: Marker) {
        guard let entity = markerEntities[marker.id] else { return }
        
        // Update mesh
        let mesh = createMarkerMesh(marker: marker)
        entity.model?.mesh = mesh
        
        // Update position
        if let anchor = entity.anchor as? AnchorEntity {
            anchor.position = marker.point1
        }
    }
    
    private func removeMarkerVisualization(_ markerId: UUID) {
        guard let entity = markerEntities[markerId] else { return }
        entity.anchor?.removeFromParent()
        markerEntities.removeValue(forKey: markerId)
    }
    
    // MARK: - 3D Model Loading
    
    func loadSpaceModel(space: Space) async {
        self.currentSpace = space
        
        guard let modelUrl = space.modelUsdcUrl ?? space.modelGlbUrl else {
            print("No 3D model URL available")
            return
        }
        
        do {
            let entity = try await ModelEntity.loadModel(contentsOf: URL(string: modelUrl)!)
            
            await MainActor.run {
                // Remove previous model
                spaceModelEntity?.removeFromParent()
                
                // Add new model
                let anchor = AnchorEntity(world: .zero)
                anchor.addChild(entity)
                arView.scene.addAnchor(anchor)
                
                spaceModelEntity = entity
            }
        } catch {
            showError("Failed to load 3D model: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Marker Loading
    
    func loadMarkersForSession(_ session: WorkSession) async {
        self.currentWorkSession = session
        
        do {
            let markers = try await MarkerService.shared.listMarkers(workSessionId: session.id)
            
            await MainActor.run {
                // Clear existing markers
                self.markers = markers
                
                // Remove old visualizations
                markerEntities.values.forEach { $0.anchor?.removeFromParent() }
                markerEntities.removeAll()
                
                // Visualize new markers
                markers.forEach { visualizeMarker($0) }
            }
        } catch {
            showError("Failed to load markers: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Marker Selection
    
    private func selectMarker(entity: Entity) {
        guard let markerId = UUID(uuidString: entity.name) else { return }
        guard let marker = markers.first(where: { $0.id == markerId }) else { return }
        
        // Show marker details
        let alert = UIAlertController(
            title: marker.label ?? "Marker",
            message: "ID: \(marker.id)\nSession: \(marker.workSessionId)",
            preferredStyle: .actionSheet
        )
        
        alert.addAction(UIAlertAction(title: "Edit", style: .default) { _ in
            self.editMarker(marker)
        })
        
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            Task {
                await self.deleteMarker(marker)
            }
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func editMarker(_ marker: Marker) {
        // Show edit UI
        // Implementation depends on your UI framework
    }
    
    private func deleteMarker(_ marker: Marker) async {
        do {
            try await MarkerService.shared.deleteMarker(id: marker.id)
            
            await MainActor.run {
                markers.removeAll { $0.id == marker.id }
                removeMarkerVisualization(marker.id)
            }
        } catch {
            showError("Failed to delete marker: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Utilities
    
    private func parseColor(_ hexString: String) -> UIColor? {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        
        guard hex.count == 6 else { return nil }
        
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        
        return UIColor(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
```

---

## SwiftUI ARView Wrapper

### ARViewContainer.swift

```swift
import SwiftUI
import ARKit
import RealityKit

struct ARViewContainer: UIViewControllerRepresentable {
    @Binding var space: Space?
    @Binding var workSession: WorkSession?
    @Binding var markers: [Marker]
    
    func makeUIViewController(context: Context) -> ARViewController {
        let controller = ARViewController()
        return controller
    }
    
    func updateUIViewController(_ uiViewController: ARViewController, context: Context) {
        // Update when space changes
        if let space = space {
            Task {
                await uiViewController.loadSpaceModel(space: space)
            }
        }
        
        // Update when work session changes
        if let workSession = workSession {
            Task {
                await uiViewController.loadMarkersForSession(workSession)
            }
        }
    }
}

// MARK: - Usage Example

struct ARSessionView: View {
    @State private var space: Space?
    @State private var workSession: WorkSession?
    @State private var markers: [Marker] = []
    
    var body: some View {
        ZStack {
            ARViewContainer(
                space: $space,
                workSession: $workSession,
                markers: $markers
            )
            .ignoresSafeArea()
            
            VStack {
                HStack {
                    Text(space?.name ?? "No Space")
                        .font(.headline)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                    
                    Spacer()
                    
                    Text("\(markers.count) markers")
                        .font(.caption)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
                .padding()
                
                Spacer()
                
                // Controls
                HStack(spacing: 20) {
                    Button("Place Marker") {
                        // Handled by AR tap gesture
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    
                    Button("Sync") {
                        Task {
                            await refreshMarkers()
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                }
                .padding()
            }
        }
        .task {
            await loadInitialData()
        }
    }
    
    func loadInitialData() async {
        // Load space and work session
        // Implementation depends on navigation flow
    }
    
    func refreshMarkers() async {
        guard let sessionId = workSession?.id else { return }
        
        do {
            markers = try await MarkerService.shared.listMarkers(workSessionId: sessionId)
        } catch {
            print("Failed to refresh markers: \(error)")
        }
    }
}
```

---

## Advanced AR Features

### Marker Edge Visualization

```swift
extension ARViewController {
    
    func visualizeMarkerEdges(_ marker: Marker) {
        let points = marker.points
        
        // Create lines between points
        let edges = [
            (points[0], points[1]),
            (points[1], points[2]),
            (points[2], points[3]),
            (points[3], points[0])
        ]
        
        for (start, end) in edges {
            let line = createLine(from: start, to: end, color: .yellow)
            
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(line)
            arView.scene.addAnchor(anchor)
        }
    }
    
    private func createLine(from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor) -> ModelEntity {
        let direction = end - start
        let distance = length(direction)
        
        let mesh = MeshResource.generateBox(size: [0.005, 0.005, distance])
        var material = SimpleMaterial()
        material.color = .init(tint: color)
        
        let entity = ModelEntity(mesh: mesh, materials: [material])
        
        // Position and orient the line
        entity.position = (start + end) / 2
        entity.look(at: end, from: start, relativeTo: nil)
        
        return entity
    }
}
```

### Spatial Anchor Persistence

```swift
import ARKit

extension ARViewController {
    
    func saveMarkerAnchors() {
        guard let frame = arView.session.currentFrame else { return }
        
        for (markerId, entity) in markerEntities {
            guard let anchor = entity.anchor as? AnchorEntity else { continue }
            
            // Create AR anchor at marker position
            let arAnchor = ARAnchor(name: markerId.uuidString, transform: anchor.transform.matrix)
            arView.session.add(anchor: arAnchor)
        }
    }
    
    func loadSavedAnchors() {
        // Load anchors from previous session
        // ARKit will automatically relocalize them
    }
}
```

---

## Coordinate System Mapping

### Converting Between Coordinate Systems

```swift
struct CoordinateMapper {
    
    // Convert ARKit world coordinates to API coordinates
    static func arToAPI(_ position: SIMD3<Float>) -> [Double] {
        return [Double(position.x), Double(position.y), Double(position.z)]
    }
    
    // Convert API coordinates to ARKit world coordinates
    static func apiToAR(_ coordinates: [Double]) -> SIMD3<Float> {
        guard coordinates.count == 3 else {
            return .zero
        }
        return SIMD3<Float>(Float(coordinates[0]), Float(coordinates[1]), Float(coordinates[2]))
    }
    
    // Apply transform to align with space model
    static func transformToSpaceOrigin(_ position: SIMD3<Float>, spaceTransform: simd_float4x4) -> SIMD3<Float> {
        let worldPosition = simd_float4(position.x, position.y, position.z, 1.0)
        let transformed = spaceTransform * worldPosition
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}
```

---

## Performance Optimization

### Tips for Smooth AR Experience

```swift
class ARPerformanceManager {
    
    // Limit number of visible markers
    func cullDistantMarkers(cameraPosition: SIMD3<Float>, markers: [Marker], maxDistance: Float = 10.0) -> [Marker] {
        return markers.filter { marker in
            let distance = length(marker.point1 - cameraPosition)
            return distance <= maxDistance
        }
    }
    
    // Use level of detail for distant markers
    func simplifyMarkerMesh(distance: Float) -> MeshResource {
        if distance < 2.0 {
            return .generatePlane(width: 0.1, depth: 0.1, cornerRadius: 0.01)
        } else if distance < 5.0 {
            return .generatePlane(width: 0.1, depth: 0.1)
        } else {
            return .generateBox(size: 0.05) // Simple box for distant markers
        }
    }
    
    // Batch marker updates
    func batchUpdateMarkers(_ updates: [(UUID, Marker)], completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            for (id, marker) in updates {
                // Update marker visualization
            }
            completion()
        }
    }
}
```

---

## Next Steps

- [Real-time Features Guide](./IOS_REALTIME_FEATURES.md) - Sync markers in real-time
- [SwiftUI Views Guide](./IOS_SWIFTUI_VIEWS.md) - Build marker management UI
- [Code Examples](./IOS_CODE_EXAMPLES.md) - Complete AR examples

