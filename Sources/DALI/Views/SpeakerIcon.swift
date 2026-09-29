import SwiftUI

/// System speaker glyph for list rows (the room plan draws the real cabinets).
struct SpeakerIcon: View {
    enum Kind { case compact, pair }
    var kind: Kind = .compact
    var active = false

    var body: some View {
        Image(systemName: kind == .pair ? "hifispeaker.2" : "hifispeaker")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(active ? Color.paper : Color.paper62)
            .frame(width: 32, height: 36)
            .accessibilityHidden(true)
    }
}
