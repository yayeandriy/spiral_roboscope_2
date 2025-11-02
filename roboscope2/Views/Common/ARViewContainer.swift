//
//  ARViewContainer.swift
//  roboscope2
//
//  Extracted shared ARView container for reuse across screens.
//

import SwiftUI
import RealityKit
import ARKit

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
