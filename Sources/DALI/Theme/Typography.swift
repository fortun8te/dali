// DALI — Typography Theme (shared with XDR)
// ============================================================
// Two font families with graceful fallback chains:
//
//   SERIF (titles, section headers)
//     Tiempos Headline → Tiempos Text → NewYork → system .serif
//
//   SANS (body, labels, secondary text)
//     ABC Diatype Variable → ABC Diatype → Inter-Regular → system .default
//
// Each named static const lazily resolves via the helper functions
// (`serif`, `sans`), so swapping a font is one place.
//
// Fonts are not bundled in this file — that's a project.yml change.
// `NSFont(name:size:)` returning nil is the macOS-correct check for
// "font not installed" and drives the fallback cascade.
// ============================================================

import SwiftUI
import AppKit

// Typography hierarchy (largest -> smallest)
//   serifTitle   28  Sheet titles ("Settings")
//   serifSection 21  Card titles ("Light", "Casual")
//   bodyLarge    15  Settings descriptions
//   bodyBase     13  Body text
//   bodyMedium   13  Emphasized body (.medium)
//   bodySmall    12  Secondary captions
//   label        11  Uppercase section headers (.semibold)
//   badge        10  Chips, pill badges (.semibold)
//
// Rule of thumb: `.tracking(0.8)` is reserved for uppercase `label` only.
// Body and serif sizes never get explicit tracking.

extension Font {
    // SERIF family (Tiempos / fallback chain)
    static let serifTitle   = serif(28, weight: .regular)   // sheet titles
    static let serifSection = serif(21, weight: .regular)   // card titles

    // SANS family (Diatype / fallback)
    static let bodyLarge    = sans(15, weight: .regular)    // settings descriptions
    static let bodyBase     = sans(13, weight: .regular)    // body text everywhere
    static let bodyMedium   = sans(13, weight: .medium)     // emphasized body
    static let bodySmall    = sans(12, weight: .regular)    // secondary captions
    static let label        = sans(11, weight: .semibold)   // ALL-CAPS section headers
    static let badge        = sans(10, weight: .semibold)   // chips, badges

    // Family helpers (call these for arbitrary sizes)
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "Tiempos Headline", size: size) != nil {
            return Font.custom("Tiempos Headline", size: size).weight(weight)
        }
        if NSFont(name: "Tiempos Text", size: size) != nil {
            return Font.custom("Tiempos Text", size: size).weight(weight)
        }
        if NSFont(name: "NewYork", size: size) != nil {
            return Font.custom("NewYork", size: size).weight(weight)
        }
        // System serif (macOS 13+)
        return Font.system(size: size, weight: weight, design: .serif)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "ABC Diatype Variable", size: size) != nil {
            return Font.custom("ABC Diatype Variable", size: size).weight(weight)
        }
        if NSFont(name: "ABC Diatype", size: size) != nil {
            return Font.custom("ABC Diatype", size: size).weight(weight)
        }
        if NSFont(name: "Inter-Regular", size: size) != nil {
            return Font.custom("Inter-Regular", size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: .default)
    }
}
