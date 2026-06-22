import SwiftUI

// MARK: - Icon Button Style (44×44 minimum hit area)

/// For toolbar/navigation icon-only buttons. Ensures minimum 44×44 hit area
/// with the icon centered and optional glass background.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    var tint: Color = .white
    var useGlass: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .modifier(IconButtonGlassModifier(tint: tint, useGlass: useGlass, isPressed: configuration.isPressed))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct IconButtonGlassModifier: ViewModifier {
    var tint: Color
    var useGlass: Bool
    var isPressed: Bool

    func body(content: Content) -> some View {
        if useGlass {
            content
                .glassEffect(in: .circle)
                .opacity(isPressed ? 0.7 : 1.0)
        } else {
            content
                .background(Circle().fill(tint.opacity(isPressed ? 0.5 : 0.15)))
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static func iconButton(size: CGFloat = 44, tint: Color = .white, useGlass: Bool = true) -> IconButtonStyle {
        IconButtonStyle(size: size, tint: tint, useGlass: useGlass)
    }
}

// MARK: - Icon Button (convenience view)

/// A ready-to-use icon button with guaranteed 44×44 hit area.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 44
    var tint: Color = .white
    var useGlass: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.45, weight: .medium))
        }
        .buttonStyle(.iconButton(size: size, tint: tint, useGlass: useGlass))
    }
}

// MARK: - Capsule Button Style (min 44 height)

/// For text/icon+text action buttons. Ensures minimum 44pt height.
struct CapsuleButtonStyle: ButtonStyle {
    var tint: Color = .white
    var minHeight: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: minHeight)
            .padding(.horizontal, 20)
            .glassEffect(in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static func capsuleButton(tint: Color = .white, minHeight: CGFloat = 44) -> CapsuleButtonStyle {
        CapsuleButtonStyle(tint: tint, minHeight: minHeight)
    }
}

// MARK: - Circle Action Button (large, for primary actions)

/// For large primary action buttons (add marker, record, etc.)
struct CircleActionButtonStyle: ButtonStyle {
    var size: CGFloat = 80
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .glassEffect(in: .circle)
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == CircleActionButtonStyle {
    static func circleAction(size: CGFloat = 80, tint: Color = .white) -> CircleActionButtonStyle {
        CircleActionButtonStyle(size: size, tint: tint)
    }
}

// MARK: - Row Button Style

/// For tappable row items — ensures full row is tappable.
struct RowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static func rowButton(cornerRadius: CGFloat = 16) -> RowButtonStyle {
        RowButtonStyle(cornerRadius: cornerRadius)
    }
}
