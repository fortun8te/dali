// DALI — the room card: the plan on top, the two pairs and what is playing
// underneath. Every slot has a fixed height so the card never reflows.

import SwiftUI

struct RoomCard: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// Where the pointer is over the card, so the glow's lines can lean toward it.
    @State private var pointer: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            if store.hasRoomPlan {
                RoomCanvas()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NowPlayingSlot()
                    .padding(.horizontal, Space.m + 2)
                VStack(spacing: 0) {
                    if let front = store.front { PairRow(speaker: front, title: "Front") }
                    if let back = store.back { PairRow(speaker: back, title: "Back") }
                }
                .frame(height: PanelMetrics.rowHeight * 2
                    + SpeakerLoudnessAdjustment.height(for: store.front, in: store)
                    + SpeakerLoudnessAdjustment.height(for: store.back, in: store), alignment: .top)
                .padding(.horizontal, Space.m + 2)
                .padding(.bottom, Space.s)
            } else {
                SpeakerList()
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background {
            // Reduce Transparency / Increase Contrast: no light effect, flat card.
            if !reduceTransparency && contrast != .increased {
                ZStack {
                    RoomBloom(lit: store.phase == .streaming).equatable()
                    LivingBloom(pointer: pointer)
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): pointer = point
            case .ended: pointer = nil
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
               clear: true, tint: Color.black.opacity(0.52))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(RadialGradient(colors: [
                    Color.white.opacity(0.035),
                    Color.white.opacity(0.012),
                    .clear,
                ], center: .center, startRadius: 0, endRadius: 190))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(LinearGradient(stops: [
                    .init(color: .white.opacity(0.18), location: 0),
                    .init(color: .white.opacity(0.025), location: 0.3),
                    .init(color: .clear, location: 0.65),
                    .init(color: .white.opacity(0.07), location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

/// The blue bloom pooling along the bottom of the room card: the app icon's light,
/// the same ramp as Z1's card. Three static layers, no state, no animation, no
/// timers, so it costs nothing while the room is idle, and the view is Equatable
/// so store updates never redraw it:
///  - a tall rim band, deep at the top of the glow to periwinkle at the edge,
///  - a wide soft swell under it, so it reads as light pooling and not a stripe,
///  - a bright thin core on the very edge, where the glow is strongest.
/// A faint grain over the glow stops the long dark gradient from banding.
struct RoomBloom: View, Equatable {
    /// The glow warms a little while the room is live. One state change, one fade:
    /// still no timers.
    var lit = false
    private static let rise: CGFloat = 0.44
    private static let rim = Gradient(stops: [
        Gradient.Stop(color: Color.bloomDeep.opacity(0), location: 0),
        Gradient.Stop(color: Color.bloomDeep.opacity(0.10), location: 0.30),
        Gradient.Stop(color: Color.bloomDeep.opacity(0.26), location: 0.55),
        Gradient.Stop(color: Color.bloomMid.opacity(0.46), location: 0.78),
        Gradient.Stop(color: Color.bloomPeriwinkle.opacity(0.66), location: 1),
    ])
    private static let swell = Gradient(stops: [
        Gradient.Stop(color: Color.bloomSwell.opacity(0.42), location: 0),
        Gradient.Stop(color: Color.bloomSwell.opacity(0.17), location: 0.5),
        Gradient.Stop(color: Color.bloomSwell.opacity(0), location: 1),
    ])
    private static let core = Gradient(stops: [
        Gradient.Stop(color: Color.bloomHighlight.opacity(0), location: 0),
        Gradient.Stop(color: Color.bloomHighlight.opacity(0.30), location: 0.5),
        Gradient.Stop(color: Color.bloomHighlight.opacity(0), location: 1),
    ])

    var body: some View {
        GeometryReader { proxy in
            bloom(width: proxy.size.width, height: proxy.size.height * Self.rise)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .opacity(lit ? 1 : 0.88)
                .animation(Motion.fade, value: lit)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func bloom(width: CGFloat, height: CGFloat) -> some View {
        let band = LinearGradient(gradient: Self.rim, startPoint: .top, endPoint: .bottom)
        // Centred on the bottom edge and finished before its frame ends, so the pool
        // dissolves into the card instead of ending in a visible curve.
        let pool = RadialGradient(gradient: Self.swell, center: .bottom, startRadius: 0, endRadius: width * 0.62)
        let edge = LinearGradient(gradient: Self.core, startPoint: .leading, endPoint: .trailing)
        return ZStack(alignment: .bottom) {
            Rectangle().fill(band).frame(height: height)
            Rectangle().fill(pool).frame(width: width * 1.4, height: width * 0.7)
            // Two off-axis tints, a violet-leaning blue low left and an azure low right,
            // so the glow has colour depth like the icon's, not one flat blue. Soft blurred
            // discs, not gradient rectangles, so no edge can show anywhere.
            Circle().fill(Color.bloomViolet.opacity(0.26))
                .frame(width: width * 0.8, height: width * 0.8)
                .blur(radius: width * 0.16)
                .offset(x: -width * 0.36, y: width * 0.30)
            Circle().fill(Color.bloomAzure.opacity(0.30))
                .frame(width: width * 0.7, height: width * 0.7)
                .blur(radius: width * 0.15)
                .offset(x: width * 0.40, y: width * 0.30)
            Rectangle().fill(edge).frame(height: 1.5)
            // Grain only inside the glow, faded in from nothing so it has no top edge.
            GrainOverlay().frame(height: height)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .init(x: 0.5, y: 0.7)))
        }
    }
}

/// A fixed tile of fine monochrome noise, repeated, to dither dark gradients.
private struct GrainOverlay: View {
    private static let tile: Image = {
        let side = 96
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(side * side) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8((seed >> 33) & 0xFF)
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
            bytes[i * 4 + 3] = UInt8(v / 22)    // alpha up to ~5%: a whisper that only breaks up banding
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return Image(decorative: image, scale: 2)
    }()

    var body: some View {
        Self.tile.resizable(resizingMode: .tile).allowsHitTesting(false).blendMode(.plusLighter)
    }
}

/// One pair: status, name (click to switch it on/off), its own volume.
struct PairRow: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                Button { store.toggle(speaker) } label: {
                    HStack(spacing: Space.s) {
                        StatusDot(tone: store.tone(for: speaker),
                                  pulsing: speaker.enabled && speaker.health == .connecting)
                        Text(title)
                            .font(.body13Medium)
                            .foregroundStyle(speaker.enabled ? Color.paper : Color.paper38)
                    }
                    .frame(width: 64, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(speaker.available ? "\(speaker.name) — click to switch \(speaker.enabled ? "off" : "on")"
                                        : "\(speaker.name) is unavailable")
                .accessibilityLabel("\(title) speakers")
                .accessibilityValue(speaker.enabled ? "On" : "Off")

                DALISlider(value: Binding(get: { speaker.relVolume },
                                          set: { store.setRelVolume($0, for: speaker) }),
                           live: store.isLit(speaker), enabled: speaker.enabled)
                    .accessibilityLabel("\(title) volume")

                Text("\(safeInt(speaker.relVolume))")
                    .font(.readout)
                    .foregroundStyle(speaker.enabled ? Color.paper62 : Color.paper38)
                    .contentTransition(.numericText(value: speaker.relVolume))
                    .animation(Motion.fade, value: safeInt(speaker.relVolume))
                    .frame(width: 28, alignment: .trailing)
            }
            .frame(height: PanelMetrics.rowHeight)
            SpeakerLoudnessAdjustment(speaker: speaker)
                .padding(.leading, 64 + Space.m)
        }
    }
}

/// Where the user trims a speaker's loudness, right under its volume slider.
/// A speaker with a leveling curve (MICHAEL D) has exactly one control, Balance,
/// which shifts the whole curve by -30...+30 %. Other speakers show their saved
/// fixed adjustment with Reset, as before.
struct SpeakerLoudnessAdjustment: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker

    @MainActor static func height(for speaker: RoomSpeaker?, in store: DALIStore) -> CGFloat {
        speaker.map { $0.levelCurve == nil && $0.gain != 1 ? 20 : 0 } ?? 0
    }

    var body: some View {
        // A speaker with a leveling curve keeps its trim in Settings > Room > Fine
        // tuning, not under every volume slider. The saved value still applies.
        if speaker.levelCurve != nil {
            EmptyView()
        } else if speaker.gain != 1 {
            HStack(spacing: Space.s) {
                Text("Adjustment: \(safeInt((speaker.gain * 100).rounded()))%")
                    .font(.caption).foregroundStyle(Color.paper62)
                Spacer(minLength: 0)
                Button("Reset") { store.setGain(1, for: speaker) }
                    .buttonStyle(.plain).font(.captionMedium)
                    .foregroundStyle(Color.paper)
                    .accessibilityLabel("Reset \(speaker.name) loudness adjustment")
                    .help("Set this speaker's adjustment to 100%")
            }
            .frame(height: 20)
        }
    }
}

/// "Balance +0%", with small minus/plus steps and a Reset that only appears when
/// the trim is not zero. Reset touches nothing but the trim.
struct BalanceTrimControl: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker
    static let step = 2.0

    static func label(_ trim: Double) -> String {
        let value = Int(trim.rounded())
        return "Loudness match \(value > 0 ? "+" : "")\(value)%"
    }

    var body: some View {
        let low = speaker.balanceTrim <= RoomVolumePolicy.trimRange.lowerBound
        let high = speaker.balanceTrim >= RoomVolumePolicy.trimRange.upperBound
        HStack(spacing: Space.s) {
            Text(Self.label(speaker.balanceTrim))
                .font(.caption).foregroundStyle(Color.paper62)
                .help("Shifts \(speaker.name)'s whole leveling curve up or down, from -30% to +30%")
            Spacer(minLength: 0)
            if speaker.balanceTrim != 0 {
                Button("Reset") { store.setBalanceTrim(0, for: speaker) }
                    .buttonStyle(.plain).font(.captionMedium)
                    .foregroundStyle(Color.paper)
                    .padding(.horizontal, 8).frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .accessibilityLabel("Reset \(speaker.name) balance")
            }
            HStack(spacing: 0) {
                Button("\u{2212}") { store.setBalanceTrim(speaker.balanceTrim - Self.step, for: speaker) }
                    .buttonStyle(.plain).font(.captionMedium)
                    .foregroundStyle(low ? Color.paper38 : Color.paper)
                    .disabled(low)
                    .accessibilityLabel("Lower \(speaker.name) balance")
                    .frame(width: 24, height: 18).contentShape(Rectangle())
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5, height: 10)
                Button("+") { store.setBalanceTrim(speaker.balanceTrim + Self.step, for: speaker) }
                    .buttonStyle(.plain).font(.captionMedium)
                    .foregroundStyle(high ? Color.paper38 : Color.paper)
                    .disabled(high)
                    .accessibilityLabel("Raise \(speaker.name) balance")
                    .frame(width: 24, height: 18).contentShape(Rectangle())
            }
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .frame(height: 20)
    }
}

// MARK: - now playing

/// A reserved line between the room drawing and the speaker controls. It
/// gives each audible source its own compact row.
struct NowPlayingSlot: View {
    @Environment(DALIStore.self) private var store

    var body: some View {
        let items = visibleItems
        ScrollView(.vertical) {
            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    NowPlayingRow(item: item)
                }
            }
        }
        .scrollDisabled(items.count <= 2)
        .frame(height: items.count > 1 ? 68 : 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleItems: [NowItem] {
        if DALIStore.isPreview,
           ProcessInfo.processInfo.environment["DALI_PREVIEW_NOWPLAYING"] == "1" {
            return [NowItem(title: "A Walk · Tycho", source: "Spotify", app: "Spotify",
                            kind: .music, live: false, held: false),
                    NowItem(title: "Live session", source: "YouTube", app: "Chrome",
                            kind: .video, live: true, held: true)]
        }
        return store.audibleNowPlaying
    }
}

/// Artwork and track name at a useful size; artist/source stay secondary.
struct NowPlayingRow: View {
    @Environment(DALIStore.self) private var store
    let item: NowItem

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let art = store.nowPlaying.artwork(item.artURL) {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.kind == .video ? "play.rectangle" : "music.note")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.paper62)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.05))
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.captionMedium)
                    .foregroundStyle(Color.paper)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.paper62)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(Color.paper38)
                    .lineLimit(1)
            }
            if item.held {
                Image(systemName: "equal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentBlue.opacity(0.75))
                    .help("The picture is held back to match the room")
            }
        }
        .frame(height: 32)
        .help(item.title)
    }

    private var title: String {
        guard item.kind == .music,
              let divider = item.title.range(of: " · ", options: .backwards) else {
            return item.title
        }
        return String(item.title[..<divider.lowerBound])
    }

    private var detail: String {
        if item.kind == .music,
           let divider = item.title.range(of: " · ", options: .backwards) {
            return String(item.title[divider.upperBound...])
        }
        return item.source
    }

    private var trailing: String {
        if item.kind == .music {
            return item.title.range(of: " · ", options: .backwards) == nil ? "" : item.source
        }
        return item.live ? "Live" : ""
    }
}

// MARK: - no plan yet

/// Before a front/back plan exists: the actual speakers, as a list.
struct SpeakerList: View {
    @Environment(DALIStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack {
                Text("Your speakers").font(.emphasis).foregroundStyle(Color.paper)
                Spacer()
                Button { Task { await store.refreshSpeakers() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(store.isDiscovering)
                .help("Look for speakers again")
                .accessibilityLabel("Refresh speakers")
            }
            if store.speakers.isEmpty {
                VStack(spacing: Space.m) {
                    SpeakerIcon(kind: .pair)
                    Text("Turn on your AirPlay speakers and join them to this Mac's network.")
                        .font(.caption).foregroundStyle(Color.paper62)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: Space.l) {
                        ForEach(store.speakers) { SpeakerControlRow(speaker: $0) }
                    }
                }
                .scrollIndicators(.never)
            }
            if let message = store.discoveryMessage {
                Text(message).font(.caption).foregroundStyle(Color.paper62)
            }
        }
    }
}

/// A speaker with its switch and, when on, its own volume. Used by the
/// speaker list, the extras popover and Settings.
struct SpeakerControlRow: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker

    /// The last live speaker can't be switched off mid-stream.
    private var mustKeepPlaying: Bool {
        store.phase.isOn && speaker.enabled && speaker.available
            && store.speakers.filter { $0.enabled && $0.available }.count <= 1
    }

    private var status: String {
        guard speaker.available else { return "Unavailable" }
        guard speaker.enabled else { return "Off" }
        switch speaker.health {
        case .off: return "Selected"
        case .connecting: return "Connecting"
        case .live: return store.effectiveVolume(speaker) == 0 || store.captureMasterGain == 0 ? "Muted" : "Connected"
        case .trouble: return "Needs attention"
        }
    }

    var body: some View {
        VStack(spacing: Space.s) {
            HStack(spacing: Space.m) {
                SpeakerIcon(kind: .compact, active: speaker.enabled && speaker.health == .live)
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name).font(.body13Medium).foregroundStyle(Color.paper)
                        .lineLimit(1).help(speaker.name)
                    Text(status).font(.caption)
                        .foregroundStyle(speaker.available ? Color.paper38 : Color.amber)
                }
                Spacer(minLength: Space.xs)
                Toggle(speaker.name, isOn: Binding(
                    get: { speaker.enabled },
                    set: { if $0 != speaker.enabled { store.toggle(speaker) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .tint(Color.white.opacity(0.58))
                    .disabled(store.phase == .starting || mustKeepPlaying
                              || (!speaker.available && !speaker.enabled))
                    .help(mustKeepPlaying ? "Stop the room to switch off the last speaker" : "Use this speaker")
            }
            if speaker.enabled {
                SliderRow(value: Binding(get: { speaker.relVolume },
                                         set: { store.setRelVolume($0, for: speaker) }),
                          live: store.isLit(speaker), enabled: speaker.available,
                          readout: "\(safeInt(speaker.relVolume))", labelWidth: 36) {
                    Text("Vol").font(.caption).foregroundStyle(Color.paper38)
                }
                .accessibilityLabel("\(speaker.name) volume")
                SpeakerLoudnessAdjustment(speaker: speaker)
            }
        }
    }
}

// MARK: - error

/// Takes the room card's exact frame, so failing never moves anything.
struct ErrorCard: View {
    @Environment(DALIStore.self) private var store
    let message: String

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.amber)
            Text(message)
                .font(.body13)
                .foregroundStyle(Color.paper62)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.l)
            HStack(spacing: Space.l) {
                if message.localizedCaseInsensitiveContains("permission") {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .buttonStyle(SecondaryButtonStyle(accent: true))
                }
                // The cheap way out first: a fresh start fixes most network
                // hiccups in seconds. The engine restart is the second try.
                Button("Try again") { store.retryAfterError() }
                    .buttonStyle(SecondaryButtonStyle(accent: true))
                Button("Restart engine") { store.restartEngine() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard()
    }
}
