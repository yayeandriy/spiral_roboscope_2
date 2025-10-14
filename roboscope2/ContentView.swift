//
//  ContentView.swift
//  roboscope2
//
//  Created by Andrii Ieroshevych on 14.10.2025.
//

import SwiftUI
import RealityKit

struct ContentView : View {
    @State private var isExpanded: Bool = false
    @Namespace private var namespace

    var body: some View {
        ZStack {
            RealityView { content in

                // Create a cube model
                let model = Entity()
                let mesh = MeshResource.generateBox(size: 0.1, cornerRadius: 0.005)
                let material = SimpleMaterial(color: .gray, roughness: 0.15, isMetallic: true)
                model.components.set(ModelComponent(mesh: mesh, materials: [material]))
                model.position = [0, 0.05, 0]

                // Create horizontal plane anchor for the content
                let anchor = AnchorEntity(.plane(.horizontal, classification: .any, minimumBounds: SIMD2<Float>(0.2, 0.2)))
                anchor.addChild(model)

                // Add the horizontal plane anchor to the scene
                content.add(anchor)

                content.camera = .spatialTracking

            }
            .edgesIgnoringSafeArea(.all)
            
            // Liquid glass buttons with morphing animation
            GlassEffectContainer(spacing: 20) {
                if isExpanded {
                    // Two circular buttons after split - sliding out like liquid drops
                    HStack(spacing: 20) {
                        Button {
                            withAnimation(.smooth(duration: 0.5)) {
                                isExpanded = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                        }
                        .contentShape(Circle())
                        .glassEffect(.clear.interactive())
                        .clipShape(Circle())
                        .glassEffectID("button1", in: namespace)
                        .buttonStyle(.plain)
                        .offset(x: isExpanded ? 0 : 40)
                        
                        Button {
                            print("Play tapped")
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                        }
                        .contentShape(Circle())
                        .glassEffect(.clear.interactive())
                        .clipShape(Circle())
                        .glassEffectID("button2", in: namespace)
                        .buttonStyle(.plain)
                        .offset(x: isExpanded ? 0 : -40)
                    }
                } else {
                    // Single button before split
                    Button {
                        withAnimation(.smooth(duration: 0.5)) {
                            isExpanded = true
                        }
                    } label: {
                        Text("Start inspection")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 16)
                    }
                    .contentShape(Capsule())
                    .glassEffect(.clear.interactive())
                    .clipShape(Capsule())
                    .glassEffectID("mainButton", in: namespace)
                    .buttonStyle(.plain)
                }
            }
        }
    }

}

#Preview {
    ContentView()
}
