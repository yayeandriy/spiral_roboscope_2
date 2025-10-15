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
    @StateObject private var markerService = SpatialMarkerService()
    
    @State private var isExpanded: Bool = false
    @State private var arView: ARView?
    @Namespace private var namespace
    @State private var isHoldingScreen = false
    @State private var isTwoFingers = false
    @State private var moveUpdateTimer: Timer?
    @State private var markerTrackingTimer: Timer?

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
                
                // Start tracking markers continuously
                markerTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    checkMarkersInTarget()
                }
            }
            .onDisappear {
                markerTrackingTimer?.invalidate()
                markerTrackingTimer = nil
            }
            .onChange(of: arView) { newValue in
                // Connect marker service to AR view
                markerService.arView = newValue
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Single finger - just track holding
                        if !isHoldingScreen {
                            isHoldingScreen = true
                        }
                    }
                    .onEnded { _ in
                        isHoldingScreen = false
                        isTwoFingers = false
                        stopMovingMarker()
                    }
            )
            .simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0)
                    .onChanged { _ in
                        // Two fingers detected
                        if !isTwoFingers {
                            isTwoFingers = true
                            print("Two fingers detected - starting move")
                            // Try to start moving if a marker is selected
                            if markerService.selectedMarkerID != nil {
                                startMovingMarker()
                            }
                        }
                    }
                    .onEnded { _ in
                        isTwoFingers = false
                        print("Two fingers released - stopping move")
                        stopMovingMarker()
                    }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3)
                    .onEnded { _ in
                        selectMarkerInTarget()
                    }
            )
            
            // Target overlay (150pt size, 80px from top)
            TargetOverlayView()
                .allowsHitTesting(false)
            
            // Place Marker Button at bottom - liquid glass style
            VStack {
                Spacer()
                
                Button {
                    placeMarker()
                } label: {
                    Image(systemName: isTwoFingers ? "hand.tap.fill" : (isHoldingScreen ? "hand.point.up.fill" : "plus"))
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                        .frame(width: 90, height: 90)
                }
                .contentShape(Circle())
                .glassEffect(.clear.interactive())
                .clipShape(Circle())
                .buttonStyle(.plain)
                .padding(.bottom, 50)
            }
        }
    }
    
    private func placeMarker() {
        guard let arView = arView else { return }
        
        // Get screen bounds
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        
        // Target size (150x150 points), positioned higher to match visual position
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200  // Adjusted to match where marker appears
        let halfSize = targetSize / 2
        
        // Calculate 4 corner positions in screen space
        let corners = [
            CGPoint(x: centerX - halfSize, y: targetY - halfSize), // Top-left
            CGPoint(x: centerX + halfSize, y: targetY - halfSize), // Top-right
            CGPoint(x: centerX + halfSize, y: targetY + halfSize), // Bottom-right
            CGPoint(x: centerX - halfSize, y: targetY + halfSize)  // Bottom-left
        ]
        
        markerService.placeMarker(targetCorners: corners)
    }
    
    private func getTargetRect() -> CGRect {
        guard let arView = arView else { return .zero }
        
        let screenSize = arView.bounds.size
        let centerX = screenSize.width / 2
        let targetSize: CGFloat = 150
        let targetY: CGFloat = 200
        
        // Expand target by 10% for detection
        let expandedSize = targetSize * 1.1
        
        return CGRect(
            x: centerX - expandedSize / 2,
            y: targetY - expandedSize / 2,
            width: expandedSize,
            height: expandedSize
        )
    }
    
    private func checkMarkersInTarget() {
        guard let arView = arView else { return }
        
        let targetRect = getTargetRect()
        markerService.updateMarkersInTarget(targetRect: targetRect)
    }
    
    private func selectMarkerInTarget() {
        guard let arView = arView else { return }
        
        let targetRect = getTargetRect()
        markerService.selectMarkerInTarget(targetRect: targetRect)
    }
    
    private func startMovingMarker() {
        guard let arView = arView,
              markerService.selectedMarkerID != nil else { return }
        
        // Start moving the selected marker
        if markerService.startMovingSelectedMarker() {
            // Update marker position continuously while holding
            moveUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
                markerService.updateMovingMarker()
            }
            print("Started moving selected marker")
        }
    }
    
    private func stopMovingMarker() {
        moveUpdateTimer?.invalidate()
        moveUpdateTimer = nil
        markerService.stopMovingMarker()
    }
}

// MARK: - Target Overlay View

struct TargetOverlayView: View {
    let targetSize: CGFloat = 150  // Half the original size
    let cornerLength: CGFloat = 20
    let cornerWidth: CGFloat = 4
    
    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let targetY: CGFloat = 80 + targetSize / 2  // 80px from top
            let halfSize = targetSize / 2
            
            ZStack {
                // Four corner brackets
                ForEach(0..<4) { index in
                    CornerBracket(length: cornerLength, width: cornerWidth)
                        .stroke(Color.white, lineWidth: cornerWidth)
                        .frame(width: cornerLength, height: cornerLength)
                        .rotationEffect(.degrees(Double(index * 90)))
                        .position(
                            x: centerX + (index == 1 || index == 2 ? halfSize : -halfSize),
                            y: targetY + (index >= 2 ? halfSize : -halfSize)
                        )
                }
                

            }
        }
    }
}

// MARK: - Corner Bracket Shape

struct CornerBracket: Shape {
    let length: CGFloat
    let width: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        // Draw L-shaped corner (top-left orientation)
        // Horizontal line
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: length, y: 0))
        
        // Vertical line
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: length))
        
        return path
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
