//
//  ContentView.swift
//  roboscope2
//
//  Created by Andrii Ieroshevych on 14.10.2025.
//

import SwiftUI
import RealityKit
import ARKit

struct ContentView : View {
    @StateObject private var captureSession = CaptureSession()
    
    @State private var isExpanded: Bool = false
    @State private var arView: ARView?
    @Namespace private var namespace

    var body: some View {
        ZStack {
            // AR View
            ARViewContainer(
                session: captureSession.session,
                arView: $arView
            )
            .edgesIgnoringSafeArea(.all)
            .onAppear {
                // Start AR immediately when view appears
                captureSession.start()
            }
            
            
            
            // Liquid glass buttons with morphing animation
            GlassEffectContainer(spacing: 20) {
                if isExpanded {
                    // Two circular buttons after split
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
                            withAnimation(.smooth(duration: 0.5)) {
                                isExpanded = false
                            }
                        } label: {
                            Image(systemName: "checkmark")
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
                            handleStartInspection()
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
    
    private func handleStartInspection() {
        // AR already running, just trigger the animation
        print("Inspection started")
    }
}

// MARK: - ARView Container

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    @Binding var arView: ARView?
    
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.session = session
        
        DispatchQueue.main.async {
            arView = view
        }
        
        return view
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
}

#Preview {
    ContentView()
}
