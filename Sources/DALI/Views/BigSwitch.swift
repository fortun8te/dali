// DALI — the one button that matters.

import SwiftUI

struct BigSwitch: View {
    @Environment(DALIStore.self) private var store
    @State private var hovering = false

    var body: some View {
        Button {
            store.bigButtonTapped()
        } label: {
            HStack(spacing: 9) {
                if store.phase == .starting {
                    ConnectingDots()
                }
                Text(label)
                    .font(.bodyMedium)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(Color.paper)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(background)
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(DS.spring, value: store.phase)
        .animation(DS.spring, value: store.isPlaying)
        .animation(DS.spring, value: hovering)
        .disabled(isError)
    }

    private var isError: Bool {
        if case .error = store.phase { return true }
        return false
    }

    private var label: String {
        if store.mode == .mirror {
            switch store.phase {
            // The promise, not the mechanism. "Mirror my Mac to the Room" named
            // the plumbing; nobody wants to mirror anything — they want the
            // music everywhere. One verb, one place.
            case .idle: return "Play everywhere"
            case .starting: return "Starting…"
            case .streaming: return "Stop"
            case .error: return "Fix the issue below"
            }
        }
        switch store.phase {
        case .idle: return "Play to Room"
        case .starting: return "Starting…"
        case .streaming: return store.isPlaying ? "Pause" : "Resume"
        case .error: return "Fix the issue below"
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        DarkGlassSurface(cornerRadius: 16, tintAlpha: 0.58, clear: false)
            // Keep the control dark, but leave enough of the material exposed
            // for the blur and edge refraction to read. The old 93% black mask
            // flattened the glass into a near-black hole.
            .overlay(shape.fill(Color.field.opacity(hovering ? 0.61 : 0.68)))
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: Color.paper.opacity(hovering ? 0.105 : 0.082), location: 0),
                        .init(color: Color.warmWhite.opacity(hovering ? 0.035 : 0.022), location: 0.32),
                        .init(color: .clear, location: 0.76),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
            )
            .overlay(
                RadialGradient(
                    colors: [Color.warmWhite.opacity(hovering ? 0.052 : 0.034), .clear],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: 210
                )
                .clipShape(shape)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 12, y: 6)
    }
}


/// Plain button that compresses slightly while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}


/// Three dots breathing in sequence; replaces the stock spinner.
struct ConnectingDots: View {
    @State private var on = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.accentBlue)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.55)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.18),
                        value: on)
            }
        }
        .onAppear { on = true }
    }
}
