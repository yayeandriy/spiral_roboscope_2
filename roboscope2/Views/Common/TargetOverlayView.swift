//
//  TargetOverlayView.swift
//  roboscope2
//
//  Extracted target overlay and corner bracket for reuse.
//

import SwiftUI

struct TargetOverlayView: View {
    enum Style { case brackets, cross }
    let style: Style
    let targetSize: CGFloat = 150
    let cornerLength: CGFloat = 20
    let cornerWidth: CGFloat = 4

    init(style: Style = .brackets) {
        self.style = style
    }
    
    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let centerY = geometry.size.height / 2
            let targetY: CGFloat = 120 + targetSize / 2
            let halfSize = targetSize / 2
            
            ZStack {
                if style == .brackets {
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
                } else {
                    let crossLength: CGFloat = 40
                    let lineWidth: CGFloat = 3
                    Path { path in
                        path.move(to: CGPoint(x: centerX - crossLength/2, y: centerY))
                        path.addLine(to: CGPoint(x: centerX + crossLength/2, y: centerY))
                    }
                    .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    Path { path in
                        path.move(to: CGPoint(x: centerX, y: centerY - crossLength/2))
                        path.addLine(to: CGPoint(x: centerX, y: centerY + crossLength/2))
                    }
                    .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    Circle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 4, height: 4)
                        .position(x: centerX, y: centerY)
                }
            }
        }
    }
}

struct CornerBracket: Shape {
    let length: CGFloat
    let width: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: length, y: 0))
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: length))
        return path
    }
}
