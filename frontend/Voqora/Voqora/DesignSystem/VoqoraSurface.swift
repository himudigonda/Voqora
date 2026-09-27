import SwiftUI

enum VoqoraSurface {
    case chrome
    case canvas
    case raised
    case floating
    case control

    var fill: Color {
        switch self {
        case .chrome: Palette.surfaceSunken
        case .canvas: Palette.surfaceBase
        case .raised, .floating: Palette.surfaceRaised
        case .control: Palette.surfaceSunken
        }
    }

    var borderColor: Color? {
        switch self {
        case .chrome, .canvas: nil
        case .raised, .control, .floating: Palette.separator
        }
    }

    var shadow: SurfaceShadow? {
        switch self {
        case .chrome, .canvas, .raised, .control: nil
        case .floating: SurfaceShadow(color: Color.black.opacity(0.18), radius: 28, y: 10)
        }
    }
}

struct SurfaceShadow {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

extension View {
    func voqoraSurface(_ role: VoqoraSurface, in shape: some InsettableShape = .rect) -> some View {
        modifier(VoqoraSurfaceBackground(role: role, shape: shape))
    }
}

private struct VoqoraSurfaceBackground<S: InsettableShape>: ViewModifier {
    let role: VoqoraSurface
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(role.fill, in: shape)
            .overlay {
                if let borderColor = role.borderColor {
                    shape.strokeBorder(borderColor, lineWidth: 1)
                }
            }
            .compositingGroup()
            .shadow(
                color: role.shadow?.color ?? .clear,
                radius: role.shadow?.radius ?? 0,
                y: role.shadow?.y ?? 0
            )
    }
}
