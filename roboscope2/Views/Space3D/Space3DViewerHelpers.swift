//
//  Space3DViewerHelpers.swift
//  roboscope2
//

import SwiftUI
import SceneKit

// MARK: - SCNGeometry Extension for Lines

extension SCNGeometry {
    static func line(from start: SCNVector3, to end: SCNVector3) -> SCNGeometry {
        let vertices: [SCNVector3] = [start, end]
        let indices: [Int32] = [0, 1]
        
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .line,
            primitiveCount: 1,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        return SCNGeometry(sources: [vertexSource], elements: [element])
    }
}

// MARK: - Camera Control Buttons

struct CameraControlButtons: View {
    let onAction: (CameraAction) -> Void
    
    enum CameraAction: Equatable {
        case fitAll
        case topView
        case frontView
        case sideView
        case resetView
        case toggleGrid
        case toggleAxes
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // View presets
            HStack(spacing: 8) {
                controlButton(icon: "cube.fill", title: "Fit All") {
                    onAction(.fitAll)
                }
                
                controlButton(icon: "arrow.up.circle", title: "Top") {
                    onAction(.topView)
                }
                
                controlButton(icon: "arrow.right.circle", title: "Side") {
                    onAction(.sideView)
                }
                
                controlButton(icon: "circle.circle", title: "Front") {
                    onAction(.frontView)
                }
            }
            
            // Display toggles
            HStack(spacing: 8) {
                controlButton(icon: "grid", title: "Grid") {
                    onAction(.toggleGrid)
                }
                
                controlButton(icon: "point.3.connected.trianglepath.dotted", title: "Axes") {
                    onAction(.toggleAxes)
                }
                
                controlButton(icon: "arrow.counterclockwise", title: "Reset") {
                    onAction(.resetView)
                }
            }
        }
        .padding(12)
    }
    
    private func controlButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.15))
            .cornerRadius(8)
            .foregroundColor(.white)
        }
    }
}
