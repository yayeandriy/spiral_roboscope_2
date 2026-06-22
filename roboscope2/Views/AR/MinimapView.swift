//
//  MinimapView.swift
//  roboscope2
//
//  Top-down 3D minimap showing session markers and reference markers.
//

import SwiftUI
import SceneKit

// MARK: - Minimap View

struct MinimapView: View {
    let spaceId: String
    let sessionId: UUID

    @Environment(\.dismiss) private var dismiss
    @StateObject private var refSetService = ReferenceSetService.shared
    @StateObject private var markerService = MarkerService.shared
    @State private var selectedRefSetId: String? = nil
    @State private var showRefMarkers = true
    @State private var showGrid = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MinimapSceneView(
                sessionMarkers: markerService.markers,
                referenceMarkers: filteredRefMarkers,
                showRefMarkers: showRefMarkers,
                showGrid: showGrid
            )

            // Top bar
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.ultraThinMaterial))
                    }

                    Spacer()

                    // Ref set picker
                    if !refSetService.referenceSets.isEmpty {
                        Menu {
                            Button("All Sets") {
                                selectedRefSetId = nil
                            }
                            Divider()
                            ForEach(refSetService.referenceSets) { set in
                                Button(set.name) {
                                    selectedRefSetId = set.id.uuidString
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedRefSetName)
                                    .font(.system(size: 12, weight: .medium))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.ultraThinMaterial))
                        }

                        // Toggle ref markers
                        Button {
                            showRefMarkers.toggle()
                        } label: {
                            Text("Ref")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(showRefMarkers ? .white : .gray)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(showRefMarkers ? Color.green.opacity(0.6) : .ultraThinMaterial)
                                )
                        }
                    }

                    // Grid toggle
                    Button {
                        showGrid.toggle()
                    } label: {
                        Text("Grid")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(showGrid ? .white : .gray)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                // Legend
                HStack(spacing: 16) {
                    legendDot(color: .orange, label: "Session (\(markerService.markers.count))")
                    if showRefMarkers && !filteredRefMarkers.isEmpty {
                        legendDot(color: .green, label: "Ref (\(filteredRefMarkers.count))")
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .padding(.bottom, 16)
            }
        }
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
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
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

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = .black
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        sceneView.scene = scene

        // Camera — top-down orthographic
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.orthographicScale = 10
        cameraNode.camera?.zFar = 1000
        cameraNode.position = SCNVector3(0, 15, 0)
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode

        // Lighting
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 300
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        let directional = SCNNode()
        directional.light = SCNLight()
        directional.light?.type = .directional
        directional.light?.intensity = 500
        directional.position = SCNVector3(0, 10, 0)
        scene.rootNode.addChildNode(directional)

        // Grid
        addGrid(to: scene)
        scene.rootNode.childNode(withName: "grid", recursively: false)?.isHidden = !showGrid

        // Session markers
        addSessionMarkers(to: scene)

        // Reference markers
        addRefMarkers(to: scene)
        scene.rootNode.childNode(withName: "refMarkers", recursively: false)?.isHidden = !showRefMarkers

        context.coordinator.scene = scene
        return sceneView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = context.coordinator.scene else { return }

        // Toggle grid
        scene.rootNode.childNode(withName: "grid", recursively: false)?.isHidden = !showGrid

        // Toggle ref markers
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
            scene.rootNode.childNode(withName: "refMarkers", recursively: false)?.isHidden = !showRefMarkers
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var scene: SCNScene?
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
