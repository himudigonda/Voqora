//
//  VoqoraSurface.swift
//  Voqora
//
//  Voqora's surface vocabulary — flat, opaque, and deliberately not Liquid
//  Glass or `.ultraThinMaterial`, matching GRiT's own surface system.
//
//  A material derives its color from whatever happens to be behind it, which
//  is exactly wrong for a design built on a warm neutral ramp: the ivory
//  chrome stops being ivory and becomes a smeared average of whatever is
//  scrolling underneath. Opaque surfaces from `Palette` give up that effect
//  and get back something stable and checkable: a given surface is the same
//  color everywhere it appears, and every foreground/background pair has one
//  answer.
//
//  Depth is carried by a one-step surface change, a hairline border, and a
//  soft shadow — not blur.
//

import SwiftUI

enum VoqoraSurface {
    /// Chrome attached to the window's edges: the sidebar, the window
    /// background under the traffic lights. The ivory in light mode.
    case chrome
    /// The main content canvas the chrome frames.
    case canvas
    /// A card or grouped block sitting on the canvas. Border, no shadow — it
    /// belongs to the page rather than hovering over it.
    case raised
    /// Genuinely floating above everything: sheets, popovers, the now-playing
    /// bar. Border plus a real shadow.
    case floating
    /// A control the pointer acts on. Recessed rather than raised.
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

    var shadow: (color: Color, radius: CGFloat, y: CGFloat)? {
        switch self {
        case .chrome, .canvas, .raised, .control: nil
        // Tuned to read at the same weight in both appearances: a shadow
        // that looks right on the light ivory is invisible on the dark
        // charcoal, so the dark side leans on the border and a wider,
        // softer falloff rather than a darker one.
        case .floating: (Color.black.opacity(0.18), 28, 10)
        }
    }
}

extension View {
    /// Fills `shape` with one of Voqora's surfaces, plus that surface's
    /// border and shadow.
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
