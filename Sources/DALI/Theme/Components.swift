// DALI — the component library. Every control in the app is one of these,
// so a button, a slider or a status dot looks and moves the same everywhere.

import SwiftUI

// MARK: - Edge light

/// The only "effect": one hairline that catches light along the top edge and
/// fades down the sides.
struct EdgeLight: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: .white.opacity(0.14), location: 0),
            .init(color: .white.opacity(0.07), location: 0.4),
            .init(color: .white.opacity(0.05), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Glass

/// Liquid Glass, the system's own and nothing added: `.glassEffect(.regular)`
/// on the ink ground reads as quiet smoked glass. Three surfaces in the main
/// window — the switch, the room card, the footer. Before macOS 26 it falls
/// back to a thin material.
extension View {
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, clear: Bool = false, tint: Color? = nil,
                         interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Self.glassStyle(clear: clear, tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(tint ?? .clear).allowsHitTesting(false))
        }
    }

    @available(macOS 26.0, *)
    private static func glassStyle(clear: Bool, tint: Color?, interactive: Bool) -> Glass {
        var g: Glass = clear ? .clear : .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    /// A glass card: rounded rect, radius 14. System glass only — no rim,
    /// glow or stroke of our own on top.
    func glassCard(radius: CGFloat = Radius.card) -> some View {
        self.glass(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Native dark glass with the same restrained corners as the window controls.
    func glassPill(clear: Bool = false, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        return self
            .background(shape.fill(Color.black.opacity(0.16)))
            .glass(shape, clear: clear, tint: tint ?? Color.black.opacity(0.32),
                   interactive: interactive)
    }
}

/// Groups glass shapes so they are sampled together (and can blend when they
/// touch). Plain stack before macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Card background as a view (for `.background(CardBackground())` sites).
struct CardBackground: View {
    var radius: CGFloat = Radius.card
    var body: some View {
        Color.clear.glassCard(radius: radius)
    }
}

extension View {
    /// Wrap in a glass card: padding 12 unless told otherwise.
    func card(padding: CGFloat = Space.m) -> some View {
        self.padding(padding).glassCard()
    }
}

// MARK: - Buttons

/// Full-width 40pt dark glass control. Live state is carried by the room and
/// status dot, keeping the button quiet in both playback states.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.body13Medium)
            .foregroundStyle(Color.paper.opacity(enabled ? 1 : 0.38))
            .frame(maxWidth: .infinity)
            .frame(height: PanelMetrics.buttonHeight)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .glassPill(interactive: true)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Plain text action: paper 62 → paper on hover. Blue only when `accent`.
struct SecondaryButtonStyle: ButtonStyle {
    var accent = false
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, accent: accent)
    }
}

private struct SecondaryBody: View {
    let configuration: ButtonStyleConfiguration
    let accent: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.body13)
            .foregroundStyle(color)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.fade, value: hovering)
    }

    private var color: Color {
        guard enabled else { return .paper38 }
        if accent { return .accentBlue.opacity(hovering ? 1 : 0.9) }
        return hovering ? .paper : .paper62
    }
}

/// 28pt glyph button (gear, extras, refresh); a glass pill when `glass`.
struct IconButtonStyle: ButtonStyle {
    var glass = true
    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, glass: glass)
    }
}

private struct OptionalGlassPill: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glassPill(interactive: true) } else { content }
    }
}

private struct IconBody: View {
    let configuration: ButtonStyleConfiguration
    let glass: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? (hovering ? Color.paper : Color.paper.opacity(0.8)) : Color.paper38)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, glass ? 4 : 0)
            .contentShape(Capsule())
            .modifier(OptionalGlassPill(on: glass))
            .onHover { hovering = $0 }
            .animation(Motion.fade, value: hovering)
    }
}

// MARK: - Status dot

struct StatusDot: View {
    enum Tone: Equatable { case live, idle, trouble }
    var tone: Tone
    /// Connecting: the one state with something happening behind it.
    var pulsing = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.4 : 1)
            .animation(Motion.fade, value: tone)
            .onChange(of: pulsing, initial: true) { _, now in
                if now && !reduceMotion {
                    withAnimation(Motion.pulse) { dim = true }
                } else {
                    withAnimation(Motion.fade) { dim = false }
                }
            }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .live: return .accentBlue
        case .idle: return .paper38
        case .trouble: return .amber
        }
    }
}

// MARK: - Slider

/// 4pt track, paper fill (blue only while live), 14pt white knob, no halo.
/// Grab the knob → relative drag, no jump. Click the track → jump there.
struct DALISlider: View {
    @Binding var value: Double          // 0...100
    var live = false
    var enabled = true

    @State private var grab: Double?    // knob-relative offset, or .nan for a track jump
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - knob, 1)
            let x = CGFloat(min(max(value, 0), 100) / 100) * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16)).frame(height: 4)
                Capsule().fill(fill).frame(width: x + knob / 2, height: 4)
                Circle()
                    .fill(Color.white.opacity(enabled ? 1 : 0.45))
                    .frame(width: knob, height: knob)
                    .scaleEffect(grab != nil && !reduceMotion ? 1.1 : 1)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard enabled else { return }
                    if grab == nil {
                        let knobCentre = x + knob / 2
                        grab = abs(g.startLocation.x - knobCentre) <= knob
                            ? Double(knobCentre - g.startLocation.x) : .nan
                    }
                    let offset = grab.flatMap { $0.isNaN ? nil : $0 } ?? 0
                    let centre = g.location.x + offset - knob / 2
                    value = Double(min(max(centre / travel, 0), 1)) * 100
                }
                .onEnded { _ in grab = nil })
            .animation(Motion.press, value: grab != nil)
        }
        .frame(height: 20)
        .animation(Motion.fade, value: live)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(safeInt(value.rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(100, value + 5)
            case .decrement: value = max(0, value - 5)
            @unknown default: break
            }
        }
        .focusable(enabled)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { value = max(0, value - 1); return .handled }
        .onKeyPress(.rightArrow) { value = min(100, value + 1); return .handled }
    }

    private var fill: Color {
        guard enabled else { return .paper38 }
        return live ? .paper.opacity(0.62) : .paper
    }
}

/// Label · slider · value, the one slider layout used across the app.
struct SliderRow<Label: View>: View {
    @Binding var value: Double
    var live = false
    var enabled = true
    var readout: String
    var labelWidth: CGFloat = 72
    @ViewBuilder var label: () -> Label

    var body: some View {
        HStack(spacing: Space.m) {
            label().frame(width: labelWidth, alignment: .leading)
            DALISlider(value: $value, live: live, enabled: enabled)
            Text(readout)
                .font(.readout)
                .foregroundStyle(enabled ? Color.paper62 : Color.paper38)
                .contentTransition(.numericText())
                .animation(Motion.fade, value: readout)
                .frame(minWidth: 30, alignment: .trailing)
        }
    }
}

// MARK: - Settings rows

/// A grouped list in the System Settings manner: one card, rows split by
/// hairlines inset to the text.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let title {
                Text(title).font(.captionMedium).foregroundStyle(Color.paper62)
                    .padding(.leading, Space.m)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 {
                            Rectangle().fill(Color.hairline).frame(height: 0.5)
                                .padding(.leading, Space.m)
                        }
                        row.padding(.horizontal, Space.m).padding(.vertical, 10)
                    }
                }
            }
            .glassCard(radius: Radius.card)
            if let footer {
                Text(footer).font(.caption).foregroundStyle(Color.paper38)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.m)
            }
        }
    }
}
