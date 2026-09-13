// DALI — Palette
// Lemon design system: lemon accent, lime = alive, amber = trouble.
// No blue. No pure white or black.

import SwiftUI
import AppKit

extension Color {
    /// Primary accent. A deep electric blue that reads
    /// premium on the near-black panel.
    static let accentBlue = Color(red: 0x4C/255, green: 0x8D/255, blue: 0xFF/255)
    static let lemon   = Color(red: 0xF5/255, green: 0xC5/255, blue: 0x18/255)
    static let lime    = Color(red: 0xA3/255, green: 0xE6/255, blue: 0x35/255)
    static let amber   = Color(red: 0xF5/255, green: 0x9E/255, blue: 0x0B/255)
    static let ink     = Color(red: 0x0E/255, green: 0x0E/255, blue: 0x0C/255)
    static let paper   = Color(red: 0xF5/255, green: 0xF6/255, blue: 0xF8/255)

    // MARK: Meridian
    // The app icon is a dawn horizon: a warm-white core diffusing up through
    // luminous blue into a near-black field, built only from gradients and
    // blur. These two tokens are that icon's endpoints.

    /// The warm-white core of the Meridian arc — the light itself.
    static let warmWhite = Color(red: 0xF2/255, green: 0xED/255, blue: 0xE3/255)
    /// The near-black field the arc dissolves into. A touch cooler and deeper
    /// than `ink`, so a cabinet drawn on an ink card still has somewhere to go.
    static let field     = Color(red: 0x08/255, green: 0x09/255, blue: 0x0B/255)

    static let paper60 = paper.opacity(0.60)
    static let paper35 = paper.opacity(0.35)
    static let hairline = paper.opacity(0.08)
}

/// Golden-ratio constants: the panel's proportion system.
enum Phi {
    static let ratio = 1.618033989
    static let inv:  Double = 0.618   // 1/φ
    static let inv2: Double = 0.382
    static let inv3: Double = 0.236
    static let inv4: Double = 0.146
}

enum DS {
    static let panelRadius: CGFloat = 21
    static let cardRadius: CGFloat = 13
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.8)
}

/// Apple's real macOS 26 Liquid Glass surface, with a material fallback for
/// older systems. The black tint lives inside the optical material, so its rim
/// stays clear and luminous instead of becoming a grey blur under an overlay.
struct DarkGlassSurface: View {
    var cornerRadius: CGFloat
    var tintAlpha: CGFloat = 0.72
    var clear: Bool = true

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            NativeGlassSurface(cornerRadius: cornerRadius, tintAlpha: tintAlpha, clear: clear)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.field.opacity(Double(tintAlpha * 0.68)))
                )
        }
    }
}

@available(macOS 26.0, *)
private struct NativeGlassSurface: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tintAlpha: CGFloat
    let clear: Bool

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        view.style = clear ? .clear : .regular
        view.tintColor = NSColor(calibratedRed: 0.015, green: 0.018, blue: 0.024, alpha: tintAlpha)
    }
}

/// Card background used across the panel.
struct CardBackground: View {
    var body: some View {
        DarkGlassSurface(cornerRadius: DS.cardRadius, tintAlpha: 0.72, clear: false)
            .overlay(
                RoundedRectangle(cornerRadius: DS.cardRadius - 1.5, style: .continuous)
                    .inset(by: 1.5)
                    .fill(Color.field.opacity(0.84))
            )
            .shadow(color: Color.black.opacity(0.46), radius: 20, y: 9)
    }
}

/// Soft hover highlight for interactive rows.
struct RowHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.paper.opacity(hovering ? 0.05 : 0))
            )
            .padding(.horizontal, -6).padding(.vertical, -3)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func rowHover() -> some View { modifier(RowHover()) }
}
