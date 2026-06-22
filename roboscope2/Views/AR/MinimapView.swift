//
//  MinimapView.swift
//  roboscope2
//
//  Top-down 3D minimap showing session markers and reference markers.
//

import SwiftUI
import SceneKit

// MARK: - Pill Button Style

private struct PillButtonStyle: ViewModifier {
    var isActive: Bool
    var activeColor: Color

    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .fontWeight(.medium)
            .frame(height: 40)
            .padding(.horizontal, 16)
            .foregroundStyle(isActive ? .white : .secondary)
            .background(isActive ? activeColor : Color(.systemGray5))
            .clipShape(.rect(cornerRadius: 12))
    }
}

private extension View {
    func pillButtonStyle(isActive: Bool = true, activeColor: Color = .blue) -> some View {
        modifier(PillButtonStyle(isActive: isActive, activeColor: activeColor))
    }
}

// MARK: - Pill Toggle

private struct PillToggle<Label: View>: View {
    @Binding var isOn: Bool
    var activeColor: Color
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { isOn.toggle() } label: {
            label()
                .pillButtonStyle(isActive: isOn, activeColor: activeColor)
        }
        .buttonStyle(.plain)
    }
}

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
    @State private var is3D = false
    @State private var cameraView: MinimapCameraView = .top

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            MinimapSceneView(
                sessionMarkers: markerService.markers,
                referenceMarkers: showRefMarkers ? filteredRefMarkers : [],
                is3D: is3D,
                cameraView: cameraView
            )

            // Top bar
            topBar

            // Bottom bar
            bottomBar
        }
        .task {
            try? await refSetService.listReferenceSets(spaceId: spaceId)
            try? await markerService.listMarkers(workSessionId: sessionId)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color(.systemGray6)))
                }
                .buttonStyle(.plain)

                Spacer()

                modeToggle

                if !is3D {
                    viewPicker
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)

            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                if !refSetService.referenceSets.isEmpty {
                    refSetMenu

                    PillToggle(isOn: $showRefMarkers, activeColor: .green) {
                        Text("Ref")
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        HStack(spacing: 0) {
            Button { is3D = false } label: {
                Text("2D")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(width: 48, height: 36)
                    .foregroundStyle(!is3D ? .white : .secondary)
                    .background(!is3D ? Color.blue : Color(.systemGray5))
            }
            .buttonStyle(.plain)

            Button { is3D = true } label: {
                Text("3D")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(width: 48, height: 36)
                    .foregroundStyle(is3D ? .white : .secondary)
                    .background(is3D ? Color.blue : Color(.systemGray5))
            }
            .buttonStyle(.plain)
        }
        .clipShape(.rect(cornerRadius: 10))
    }

    // MARK: - View Picker

    private var viewPicker: some View {
        Picker("View", selection: $cameraView) {
            ForEach(MinimapCameraView.allCases, id: \.self) { v in
                Text(v.rawValue).tag(v)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 170)
    }

    // MARK: - Ref Set Menu

    private var refSetMenu: some View {
        Menu {
            Button("All Sets") { selectedRefSetId = nil }
            Divider()
            ForEach(refSetService.referenceSets) { set in
                Button(set.name) { selectedRefSetId = set.id.uuidString }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedRefSetName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.primary)
            .frame(height: 40)
            .padding(.horizontal, 16)
            .background(Capsule().stroke(Color(.systemGray4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

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
}

// MARK: - SceneKit Minimap

private struct MinimapSceneView: UIViewRepresentable {
    let sessionMarkers: [Marker]
    let referenceMarkers: [ReferenceMarker]
    let is3D: Bool
    let cameraView: MinimapCameraView

    func makeUIView(context: Context) -> SCNView {
        let sceneView = SCNView()
        sceneView.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        sceneView.scene = scene

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.orthographicScale = 10
        cameraNode.camera?.zFar = 1000
        cameraNode.name = "minimapCamera"
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        applyCameraView(cameraNode)

        context.coordinator.cameraNode = cameraNode
        context.coordinator.sceneView = sceneView

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        ambient.light?.color = UIColor.white
        scene.rootNode.addChildNode(ambient)

        addGrid(to: scene)
        addSessionMarkers(to: scene)
        addRefMarkers(to: scene)

        context.coordinator.scene = scene
        return sceneView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = context.coordinator.scene,
              let cameraNode = context.coordinator.cameraNode else { return }

        cameraNode.camera?.usesOrthographicProjection = !is3D
        applyCameraView(cameraNode)
        uiView.allowsCameraControl = true

        if context.coordinator.lastSessionCount != sessionMarkers.count ||
           context.coordinator.lastRefCount != referenceMarkers.count {
            context.coordinator.lastSessionCount = sessionMarkers.count
            context.coordinator.lastRefCount = referenceMarkers.count
            scene.rootNode.childNode(withName: "sessionMarkers", recursively: false)?.removeFromParentNode()
            scene.rootNode.childNode(withName: "refMarkers", recursively: false)?.removeFromParentNode()
            addSessionMarkers(to: scene)
            addRefMarkers(to: scene)
        }

        scene.rootNode.childNode(withName: "refMarkers", recursively: false)?.isHidden = referenceMarkers.isEmpty
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
        var sceneView: SCNView?
        var cameraNode: SCNNode?
        var lastSessionCount = 0
        var lastRefCount = 0
    }

    // MARK: - Grid

    private func addGrid(to scene: SCNScene) {
        let gridNode = SCNNode()
        gridNode.name = "grid"
        let size: Float = 30
        let step: Float = 1.0

        for i in stride(from: -size, through: size, by: step) {
            let lineX = line(from: SCNVector3(-size, 0, i), to: SCNVector3(size, 0, i))
            let isMajor = Int(i) % 5 == 0
            lineX.firstMaterial?.diffuse.contents = UIColor.darkGray.withAlphaComponent(isMajor ? 0.35 : 0.15)
            gridNode.addChildNode(SCNNode(geometry: lineX))

            let lineZ = line(from: SCNVector3(i, 0, -size), to: SCNVector3(i, 0, size))
            let isMajorZ = Int(i) % 5 == 0
            lineZ.firstMaterial?.diffuse.contents = UIColor.darkGray.withAlphaComponent(isMajorZ ? 0.35 : 0.15)
            gridNode.addChildNode(SCNNode(geometry: lineZ))

            if isMajor && i != 0 {
                gridNode.addChildNode(textNode("\(Int(abs(i)))m", at: SCNVector3(0, 0.05, i)))
            }
            if isMajorZ && i != 0 {
                gridNode.addChildNode(textNode("\(Int(abs(i)))m", at: SCNVector3(i, 0.05, 0)))
            }
        }
        scene.rootNode.addChildNode(gridNode)
    }

    private func textNode(_ text: String, at position: SCNVector3) -> SCNNode {
        let textGeo = SCNText(string: text, extrusionDepth: 0)
        textGeo.font = UIFont.systemFont(ofSize: 0.4, weight: .light)
        textGeo.firstMaterial?.diffuse.contents = UIColor.darkGray.withAlphaComponent(0.5)
        textGeo.firstMaterial?.isDoubleSided = true
        textGeo.flatness = 0.1
        let node = SCNNode(geometry: textGeo)
        node.position = position
        node.scale = SCNVector3(0.02, 0.02, 0.02)
        return node
    }

    // MARK: - Markers

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
            parent.addChildNode(markerNode(corners: corners, color: UIColor.orange.withAlphaComponent(0.7), dotRadius: 0.08))
        }
        scene.rootNode.addChildNode(parent)
    }

    private func addRefMarkers(to scene: SCNScene) {
        let parent = SCNNode()
        parent.name = "refMarkers"
        for ref in referenceMarkers {
            let corners = ref.corners.map { SCNVector3($0.x, $0.y, $0.z) }
            parent.addChildNode(markerNode(corners: corners, color: UIColor.systemGreen.withAlphaComponent(0.5), dotRadius: 0.05))
        }
        scene.rootNode.addChildNode(parent)
    }

    private func markerNode(corners: [SCNVector3], color: UIColor, dotRadius: Float) -> SCNNode {
        let node = SCNNode()

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

        for i in 0..<corners.count {
            let next = (i + 1) % corners.count
            let geo = line(from: corners[i], to: corners[next])
            geo.firstMaterial?.diffuse.contents = color
            node.addChildNode(SCNNode(geometry: geo))
        }

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
