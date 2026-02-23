//
//  RealityKitModelViewer.swift
//  roboscope2
//

import SwiftUI
import RealityKit
import SceneKit

// MARK: - RealityKit Model Viewer (for GLB and USDC)

struct RealityKitModelViewer: UIViewRepresentable {
    let url: String
    let fileExtension: String
    
    func makeUIView(context: Context) -> ARView {
        // Create ARView without AR session (just 3D rendering)
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.backgroundColor = .black
        arView.environment.background = .color(.black)
        
        // Setup camera for 3D viewing
        let camera = PerspectiveCamera()
        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.position = [0, 0, 3]
        cameraAnchor.look(at: .zero, from: cameraAnchor.position, relativeTo: nil)
        cameraAnchor.addChild(camera)
        
        // Create anchor for the model
        let anchor = AnchorEntity()
        
        // Add anchors to the scene
        arView.scene.addAnchor(anchor)
        arView.scene.addAnchor(cameraAnchor)
        
        // Add lighting
        let directionalLight = DirectionalLight()
        directionalLight.light.intensity = 3000
        directionalLight.look(at: .zero, from: [2, 2, 2], relativeTo: nil)
        let lightAnchor = AnchorEntity(world: .zero)
        lightAnchor.addChild(directionalLight)
        arView.scene.addAnchor(lightAnchor)
        
        Task {
            await loadModel(into: anchor, arView: arView)
        }
        
        // Enable rotation gestures
        let rotationGesture = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
        arView.addGestureRecognizer(rotationGesture)
        
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)
        
        context.coordinator.anchor = anchor
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    private func loadModel(into anchor: AnchorEntity, arView: ARView) async {
        guard let modelURL = URL(string: url) else {
            return
        }
        
        do {
            
            
            // Download the model
            let (data, response) = try await URLSession.shared.data(from: modelURL)
            
            
            
            // Validate minimum file size
            guard data.count > 100 else { return }
            
            // Save to temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)
            try data.write(to: tempURL)
            
            // Verify file was written
            let fileSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64 ?? 0
            
            
            // Check if file is actually USDZ by reading magic bytes
            let fileHandle = try FileHandle(forReadingFrom: tempURL)
            let headerData = fileHandle.readData(ofLength: 4)
            fileHandle.closeFile()
            
            let magic = headerData.map { String(format: "%02x", $0) }.joined()
            
            // Try loading with RealityKit first
            
            
            do {
                let entity = try await Entity.load(contentsOf: tempURL)
                
                // Wrap in ModelEntity if needed
                let modelEntity: ModelEntity
                if let model = entity as? ModelEntity {
                    modelEntity = model
                } else {
                    modelEntity = ModelEntity()
                    modelEntity.addChild(entity)
                }
                
                // Center and scale the model
                let bounds = modelEntity.visualBounds(relativeTo: nil)
                let size = bounds.extents
                let maxDimension = max(size.x, size.y, size.z)
                
                if maxDimension > 0 {
                    let scale = 1.0 / maxDimension
                    modelEntity.scale = [scale, scale, scale]
                    
                    // Center the model
                    let center = bounds.center
                    modelEntity.position = -center * scale
                }
                
                await MainActor.run {
                    anchor.addChild(modelEntity)
                }
                
                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)
                
            } catch {
                
                
                // Fall back to SceneKit which has better USDZ support
                do {
                    let scene = try SCNScene(url: tempURL, options: nil)
                    
                    // Create a wrapper to convert SCNScene to RealityKit
                    // Since we can't easily convert, show an error
                    await MainActor.run {}
                    
                    try? FileManager.default.removeItem(at: tempURL)
                    
                } catch {
                    
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
            
        } catch {
            
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        var anchor: AnchorEntity?
        var lastRotation: Float = 0
        
        @objc func handleRotation(_ gesture: UIRotationGestureRecognizer) {
            guard let anchor = anchor else { return }
            
            if gesture.state == .changed {
                let rotation = Float(gesture.rotation)
                let rotationDiff = rotation - lastRotation
                anchor.transform.rotation *= simd_quatf(angle: rotationDiff, axis: [0, 1, 0])
                lastRotation = rotation
            } else if gesture.state == .ended {
                lastRotation = 0
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let anchor = anchor, let view = gesture.view else { return }
            
            let translation = gesture.translation(in: view)
            let rotationX = Float(translation.y) * 0.01
            let rotationY = Float(translation.x) * 0.01
            
            if gesture.state == .changed {
                anchor.transform.rotation *= simd_quatf(angle: rotationY, axis: [0, 1, 0])
                anchor.transform.rotation *= simd_quatf(angle: rotationX, axis: [1, 0, 0])
            }
        }
    }
}
