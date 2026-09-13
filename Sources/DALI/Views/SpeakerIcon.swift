import SwiftUI

/// Standard system symbols for device rows, with no decorative illustration.
struct SpeakerIcon: View {
    enum Kind { case compact, tower, pair }
    var kind: Kind = .compact
    var active = false

    var body: some View {
        Image(systemName: kind == .pair ? "hifispeaker.2" : "hifispeaker")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(active ? Color.paper : Color.paper60)
            .frame(width: 36, height: 42)
            .accessibilityHidden(true)
    }
}
