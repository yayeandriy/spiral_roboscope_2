//
//  SpaceARView.swift
//  roboscope2
//
//  AR view for visualizing a Space (independent of sessions)
//

import SwiftUI
import RealityKit
import ARKit

struct SpaceARView: View {
    let space: Space
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var captureSession = CaptureSession()
    @State private var arView: ARView?
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ARViewContainer(session: captureSession.session, arView: $arView)
                .ignoresSafeArea()
                .onAppear { captureSession.start() }
                .onDisappear { captureSession.stop() }
                .task { await loadPrimaryModelIfAvailable() }
            
            // Close button
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .padding(.leading, 16)
                
                Spacer()
            }
            .padding(.top, 16)
        }
    }
    
    // MARK: - Model Loading
    
    private func loadPrimaryModelIfAvailable() async {
        guard let urlString = space.primaryModelUrl,
              let url = URL(string: urlString) else {
            return
        }
        
        do {
            let entity = try await Entity.load(contentsOf: url)
            await MainActor.run {
                if let arView {
                    let anchor = AnchorEntity(world: matrix_identity_float4x4)
                    let model = (entity as? ModelEntity) ?? {
                        let wrapper = ModelEntity()
                        wrapper.addChild(entity)
                        return wrapper
                    }()
                    anchor.addChild(model)
                    arView.scene.addAnchor(anchor)
                }
            }
        } catch {
            print("Failed to load space model: \(error)")
        }
    }
}

#Preview {
    SpaceARView(space: Space(
        id: UUID(),
        key: "demo",
        name: "Demo Space",
        description: "",
        modelGlbUrl: nil,
        modelUsdcUrl: nil,
        previewUrl: nil,
        meta: nil,
        createdAt: nil,
        updatedAt: nil
    ))
}
