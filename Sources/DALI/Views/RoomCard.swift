// DALI — the room card: the plan on top, the two pairs and what is playing
// underneath. Every slot has a fixed height so the card never reflows.

import SwiftUI

struct RoomCard: View {
    @Environment(DALIStore.self) private var store

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
                .frame(height: PanelMetrics.rowHeight * 2, alignment: .top)
                .padding(.horizontal, Space.m + 2)
                .padding(.bottom, Space.s)
            } else {
                SpeakerList()
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

/// One pair: status, name (click to switch it on/off), its own volume.
struct PairRow: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker
    let title: String

    var body: some View {
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
