//
//  MinimapView.swift
//  roboscope2
//
//  Top-down 3D minimap showing session markers and reference markers.
//

import SwiftUI
import SceneKit

// MARK: - Minimap View

enum MinimapCameraView: String, CaseIterable {
    case top = "Top"
    case front = "Front"
    case side = "Side"
}

struct MinimapView: View {
    let spaceId: String
    let sessionId: UUID

    @Environment(\.dismiss) private var dismiss
    @StateObject private var refSetService = ReferenceSetService.shared
    @StateObject private var markerService = MarkerService.shared
    @State private var selectedRefSetId: String? = nil
    @State private var showRefMarkers = true
    @State private var showGrid = true
    @State private var is3D = false
    @State private var cameraView: MinimapCameraView = .top

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            MinimapSceneView(
                sessionMarkers: markerService.markers,
                referenceMarkers: filteredRefMarkers,
                showRefMarkers: showRefMarkers,
                showGrid: showGrid,
                is3D: is3D,
                cameraView: cameraView
            )

            // Top bar
            VStack {
                HStack(spacing: 8) {
                    IconButton(systemName: "xmark", size: 44, tint: .black, useGlass: false) {
                        dismiss()
                    }

                    Spacer()

                    // 2D/3D toggle
                    HStack(spacing: 2) {
                        Button { is3D = false } label: {
                            Text("2D")
                                .font(.caption).fontWeight(.medium)
                                .frame(width: 40, height: 32)
                                .foregroundColor(!is3D ? .white : .black.opacity(0.5))
                                .background(!is3D ? Color.blue : Color.gray.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button { is3D = true } label: {
                            Text("3D")
                                .font(.caption).fontWeight(.medium)
                                .frame(width: 40, height: 32)
                                .foregroundColor(is3D ? .white : .black.opacity(0.5))
                                .background(is3D ? Color.blue : Color.gray.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    // View selector (2D only)
                    if !is3D {
                        Picker("View", selection: $cameraView) {
                            ForEach(MinimapCameraView.allCases, id: \.self) { v in
                                Text(v.rawValue).tag(v)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }

                    // Ref set picker
                    if !refSetService.referenceSets.isEmpty {
                        Menu {
                            Button("All Sets") { selectedRefSetId = nil }
                            Divider()
                            ForEach(refSetService.referenceSets) { set in
                                Button(set.name) { selectedRefSetId = set.id.uuidString }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedRefSetName).font(.caption).fontWeight(.medium)
                                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.black)
                            .frame(height: 32)
                            .padding(.horizontal, 10)
                            .background(Capsule().stroke(Color.gray.opacity(0.3)))
                        }

                        Button {
                            showRefMarkers.toggle()
                        } label: {
                            Text("Ref")
                                .font(.caption).fontWeight(.medium)
                                .frame(height: 32)
                                .padding(.horizontal, 12)
                                .foregroundColor(showRefMarkers ? .white : .black.opacity(0.5))
                                .background(Capsule().fill(showRefMarkers ? Color.green : Color.gray.opacity(0.15)))
                        }
                    }

                    Button {
                        showGrid.toggle()
                    } label: {
                        Text("Grid")
                            .font(.caption).fontWeight(.medium)
                            .frame(height: 32)
                            .padding(.horizontal, 12)
                            .foregroundColor(showGrid ? .white : .black.opacity(0.5))
                            .background(Capsule().fill(showGrid ? Color.blue : Color.gray.opacity(0.15)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 56)

                Spacer()

                // Legend
                HStack(spacing: 20) {
                    legendDot(color: .orange, label: "Session (\(markerService.markers.count))")
                    if showRefMarkers && !filteredRefMarkers.isEmpty {
                        legendDot(color: .green, label: "Ref (\(filteredRefMarkers.count))")
                    }
                }
                .font(.caption)
                .foregroundColor(.black.opacity(0.6))
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.light)
        .task {
            try? await refSetService.listReferenceSets(spaceId: spaceId)
            try? await markerService.listMarkers(workSessionId: sessionId)
        }
    }

    private var selectedRefSetName: String {
        if let id = selectedRefSetId,
           let set = refSetService.referenceSets.first(where: { $0.id.uuidString == id }) {
            return set.name
        }
        return "All Sets"
    }

    private var filteredRefMarkers: [ReferenceMarker] {
        let sets: [ReferenceSet]
        if let id = selectedRefSetId {
            sets = refSetService.referenceSets.filter { $0.id.uuidString == id }
        } else {
            sets = refSetService.referenceSets
        }
        return sets.flatMap { $0.markers }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

// MARK: - SceneKit Minimap

private struct MinimapSceneView: UIViewRepresentable {
    let sessionMarkers: [Marker]
    let referenceMarkers: [ReferenceMarker]
    let showRefMarkers: Bool
    let showGrid: Bool
    let is3D: Bool
    let cameraView: MinimapCameraView

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        sceneView.allowsCameraControl = is3D
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        sceneView.scene = scene

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = !is3D
        cameraNode.camera?.orthographicScale = 10
        cameraNode.camera?.zFar = 1000
        cameraNode.name = "minimapCamera"
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        applyCameraView(cameraNode)

        // Store camera node
        context.coordinator.cameraNode = cameraNode

        // Lighting
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        // Grid
        addGrid(to: scene)

        // Markers
        addSessionMarkers(to: scene)
        addRefMarkers(to: scene)

        context.coordinator.scene = scene
        return sceneView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = context.coordinator.scene,
              let cameraNode = context.coordinator.cameraNode else { return }

        // Camera mode
        uiView.allowsCameraControl = is3D
        cameraNode.camera?.usesOrthographicProjection = !is3D
        applyCameraView(cameraNode)

        // Grid
        scene.rootNode.childNode(withName: "grid", recursively: false)?.isHidden = !showGrid
        // Ref markers
        scene.rootNode.childNode(withName: "refMarkers", recursively: false)?.isHidden = !showRefMarkers

        // Rebuild markers if count changed
        if context.coordinator.lastSessionCount != sessionMarkers.count ||
           context.coordinator.lastRefCount != referenceMarkers.count {
            context.coordinator.lastSessionCount = sessionMarkers.count
            context.coordinator.lastRefCount = referenceMarkers.count
            scene.rootNode.childNode(withName: "sessionMarkers", recursively: false)?.removeFromParentNode()
            scene.rootNode.childNode(withName: "refMarkers", recursively: false)?.removeFromParentNode()
            addSessionMarkers(to: scene)
            addRefMarkers(to: scene)
        }
    }

    private func applyCameraView(_ camera: SCNNode) {
        let dist: Float = 15
        switch cameraView {
        case .top:
            camera.position = SCNVector3(0, dist, 0)
            camera.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        case .front:
            camera.position = SCNVector3(0, 0, dist)
            camera.eulerAngles = SCNVector3(0, 0, 0)
        case .side:
            camera.position = SCNVector3(dist, 0, 0)
            camera.eulerAngles = SCNVector3(0, Float.pi / 2, 0)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var scene: SCNScene?
        var cameraNode: SCNNode?
        var lastSessionCount = 0
        var lastRefCount = 0
    }

    // MARK: - Grid

    private func addGrid(to scene: SCNScene) {
        let gridNode = SCNNode()
        gridNode.name = "grid"
        let size: Float = 20
        let divisions = 20
        let step = size / Float(divisions)

        for i in 0...divisions {
            let offset = -size / 2 + Float(i) * step
            // X lines
            let lineX = line(from: SCNVector3(-size / 2, 0, offset), to: SCNVector3(size / 2, 0, offset))
            lineX.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(i == divisions / 2 ? 0.3 : 0.1)
            gridNode.addChildNode(SCNNode(geometry: lineX))
            // Z lines
            let lineZ = line(from: SCNVector3(offset, 0, -size / 2), to: SCNVector3(offset, 0, size / 2))
            lineZ.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(i == divisions / 2 ? 0.3 : 0.1)
            gridNode.addChildNode(SCNNode(geometry: lineZ))
        }
        scene.rootNode.addChildNode(gridNode)
    }

    // MARK: - Session Markers

    private func addSessionMarkers(to scene: SCNScene) {
        let parent = SCNNode()
        parent.name = "sessionMarkers"
        for marker in sessionMarkers {
            let corners = [
                SCNVector3(marker.point1.x, marker.point1.y, marker.point1.z),
                SCNVector3(marker.point2.x, marker.point2.y, marker.point2.z),
                SCNVector3(marker.point3.x, marker.point3.y, marker.point3.z),
                SCNVector3(marker.point4.x, marker.point4.y, marker.point4.z),
            ]
            let color = UIColor.orange.withAlphaComponent(0.7)
            parent.addChildNode(markerNode(corners: corners, color: color, dotRadius: 0.08))
        }
        scene.rootNode.addChildNode(parent)
    }

    // MARK: - Reference Markers

    private func addRefMarkers(to scene: SCNScene) {
        let parent = SCNNode()
        parent.name = "refMarkers"
        for ref in referenceMarkers {
            let corners = ref.corners.map { SCNVector3($0.x, $0.y, $0.z) }
            let color = UIColor.green.withAlphaComponent(0.5)
            parent.addChildNode(markerNode(corners: corners, color: color, dotRadius: 0.05))
        }
        scene.rootNode.addChildNode(parent)
    }

    // MARK: - Helpers

    private func markerNode(corners: [SCNVector3], color: UIColor, dotRadius: Float) -> SCNNode {
        let node = SCNNode()

        // Filled quad
        if corners.count == 4 {
            let positions: [SCNVector3] = [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]]
            let source = SCNGeometrySource(vertices: positions)
            let indices: [Int32] = [0, 1, 2, 3, 4, 5]
            let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
            let geo = SCNGeometry(sources: [source], elements: [element])
            geo.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.15)
            geo.firstMaterial?.isDoubleSided = true
            node.addChildNode(SCNNode(geometry: geo))
        }

        // Outline
        for i in 0..<corners.count {
            let next = (i + 1) % corners.count
            let geo = line(from: corners[i], to: corners[next])
            geo.firstMaterial?.diffuse.contents = color
            node.addChildNode(SCNNode(geometry: geo))
        }

        // Corner dots
        for corner in corners {
            let sphere = SCNSphere(radius: CGFloat(dotRadius))
            sphere.firstMaterial?.diffuse.contents = color
            let dotNode = SCNNode(geometry: sphere)
            dotNode.position = corner
            node.addChildNode(dotNode)
        }

        return node
    }

    private func line(from: SCNVector3, to: SCNVector3) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: [from, to])
        let indices: [Int32] = [0, 1]
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        return SCNGeometry(sources: [source], elements: [element])
    }
}
