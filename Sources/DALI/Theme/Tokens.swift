// DALI — design tokens. The ecosystem spec (shared with Z1) in code form:
// one ink ground, one surface step, one blue for "live", one amber for
// "trouble", paper text at three strengths, an 8-pt grid, one spring.

import SwiftUI

// MARK: - Colour

extension Color {
    private init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// The window ground. Opaque, near-black.
    static let ink     = Color(hex: 0x0B0C0E)
    /// Cards and controls sit one step up.
    static let surface = Color(hex: 0x141518)
    /// Pressed / selected surfaces.
    static let raised  = Color(hex: 0x1B1C20)

    /// The one accent. Blue means live: running, playing, in sync.
    static let accentBlue = Color(hex: 0x4C8DFF)
    /// The one warning colour.
    static let amber   = Color(hex: 0xF5A524)

    static let paper   = Color(hex: 0xF4F5F7)
    static let paper62 = paper.opacity(0.62)
    static let paper38 = paper.opacity(0.38)
    static let hairline = Color.white.opacity(0.08)

    /// The room's light source (the app icon's warm core). Canvas only.
    static let warmWhite = Color(hex: 0xF2EDE3)

    // Names older call sites still use (VideoMode.swift).
    static let paper60 = paper62
    static let paper35 = paper38
}

extension NSColor {
    static let daliInk = NSColor(srgbRed: 0x0B / 255, green: 0x0C / 255, blue: 0x0E / 255, alpha: 1)
}

// MARK: - Geometry

enum Radius {
    static let card: CGFloat = 14
    static let control: CGFloat = 10
    static let small: CGFloat = 6
}

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// The main window's fixed geometry. Every state lays out inside these
/// numbers, so nothing moves when the room starts, stops or fails.
enum PanelMetrics {
    static let width: CGFloat = 328
    /// Content height under the titlebar. The system adds the titlebar's own
    /// height (32 pt on macOS 26) on top, for a 328 × 540 window.
    static let height: CGFloat = 508
    /// Air between the titlebar (traffic lights) and the wordmark row.
    static let titlebar: CGFloat = 4
    static let headerHeight: CGFloat = 28
    static let buttonHeight: CGFloat = 40
    static let rowHeight: CGFloat = 32
    static let footerHeight: CGFloat = 32
}

// MARK: - Type

extension Font {
    /// 11 — captions, footnotes, units.
    static let caption = Font.system(size: 11, weight: .regular)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    /// 13 — body everywhere.
    static let body13 = Font.system(size: 13, weight: .regular)
    static let body13Medium = Font.system(size: 13, weight: .medium)
    /// 15 — emphasis (settings group titles, onboarding lead).
    static let emphasis = Font.system(size: 15, weight: .semibold)
    /// 22 — section titles.
    static let section = Font.system(size: 22, weight: .semibold)
    /// Live numbers: tabular so they never jitter.
    static let readout = Font.system(size: 13, weight: .regular).monospacedDigit()

    /// Which serif is installed, looked up once: the header re-renders every
    /// second while live, and NSFont(name:) is a font-database query.
    private static let wordmarkFace: String? =
        ["Tiempos Headline", "NewYork"].first { NSFont(name: $0, size: 22) != nil }

    /// The wordmark is the only serif in the app.
    static func wordmark(_ size: CGFloat = 22) -> Font {
        if let face = wordmarkFace { return .custom(face, size: size) }
        return .system(size: size, weight: .regular, design: .serif)
    }

    // Names older call sites still use (VideoMode.swift).
    static let bodyBase = body13
    static let badge = caption
}

// MARK: - Numbers

/// `Int(Double)` traps on NaN, ±inf and out-of-range values, and a level or a
/// volume that came off the wire or out of a division can be any of them.
/// Views format numbers on every render, so they go through this.
func safeInt(_ x: Double) -> Int {
    guard x.isFinite else { return 0 }
    return Int(min(max(x, -1e9), 1e9))
}

// MARK: - Motion

enum Motion {
    /// The one spring.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static let fade = Animation.easeOut(duration: 0.16)
    static let press = Animation.easeOut(duration: 0.12)
    /// Connecting pulse: the only repeating animation, and only while connecting.
    static let pulse = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    /// `animation` unless Reduce Motion is on.
    static func respecting(_ reduce: Bool, _ animation: Animation = spring) -> Animation? {
        reduce ? nil : animation
    }
}
