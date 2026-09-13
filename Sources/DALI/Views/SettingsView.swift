// DALI — Settings (sidebar style, small).

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(DALIStore.self) private var store
    @State private var section: Section = .general

    enum Section: String, CaseIterable {
        case general = "General"
        case room = "Room"
        case engine = "Engine"
        var icon: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .room: return "rectangle.portrait.on.rectangle.portrait"
            case .engine: return "gearshape.2"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Section.allCases, id: \.self) { s in
                    Button {
                        section = s
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: s.icon).font(.system(size: 11))
                            Text(s.rawValue).font(.bodyBase)
                        }
                        .foregroundStyle(section == s ? Color.paper : Color.paper60)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(section == s ? Color.ink.opacity(0.5) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 130)
            .background(Color.ink.opacity(0.3))

            Divider().overlay(Color.hairline)

            ScrollView {
                Group {
                    switch section {
                    case .general: GeneralSettings()
                    case .room: RoomSettings()
                    case .engine: EngineSettings()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // 460 x 284 -> 460/φ. Taller than the old 320 was needed for, but the
        // content no longer clips (the old panes truncated their help text).
        .frame(width: 480, height: 340)
        .background(Color.ink)
    }
}

struct GeneralSettings: View {
    @AppStorage("dali.launchAtLogin") private var launchAtLogin = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General").font(.serifSection).foregroundStyle(Color.paper)
            Toggle("Launch DALI at login", isOn: $launchAtLogin)
                .font(.bodyBase).foregroundStyle(Color.paper)
                .toggleStyle(.switch).controlSize(.small).tint(.accentBlue)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch { launchAtLogin = !on }
                }
            Text("Streaming keeps running while the window is closed. Quit DALI to stop everything.")
                .font(.bodySmall).foregroundStyle(Color.paper60)
            Button("Setup guide") { openWindow(id: "setup") }
                .buttonStyle(.plain).font(.bodyMedium).foregroundStyle(Color.accentBlue)
            Spacer()
        }
    }
}

struct RoomSettings: View {
    @Environment(DALIStore.self) private var store
    @AppStorage("dali.showFineTuning") private var showFineTuning = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Room").font(.serifSection).foregroundStyle(Color.paper)
                Spacer()
                Button("Refresh") { Task { await store.refreshSpeakers() } }
                    .buttonStyle(.plain).font(.bodySmall).foregroundStyle(Color.accentBlue)
                    .disabled(store.isDiscovering)
            }
            Text("Choose any AirPlay speakers on the same network. Each has its own volume.")
                .font(.bodySmall).foregroundStyle(Color.paper60)
            if store.speakers.isEmpty {
                Text("No speakers found yet. Check their power and Wi-Fi, then refresh.")
                    .font(.badge).foregroundStyle(Color.paper60)
            }
            ForEach(store.speakers) { speaker in
                SpeakerControlRow(speaker: speaker)
            }
            if let message = store.discoveryMessage {
                Text(message).font(.badge).foregroundStyle(Color.paper60)
            }
            Divider().overlay(Color.hairline)
            Text("Room layout").font(.bodyMedium).foregroundStyle(Color.paper)
            Text("Optionally place two speakers in the front/back room view.")
                .font(.badge).foregroundStyle(Color.paper60)
            LabeledContent {
                Picker("", selection: placementBinding(.front)) {
                    Text("None").tag("")
                    ForEach(pickerNames.filter { $0 != store.backName }, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 180)
                .disabled(store.phase.isOn)
            } label: {
                Text("Front speakers").font(.bodyBase).foregroundStyle(Color.paper)
            }
            LabeledContent {
                Picker("", selection: placementBinding(.back)) {
                    Text("None").tag("")
                    ForEach(pickerNames.filter { $0 != store.frontName }, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 180)
                .disabled(store.phase.isOn)
            } label: {
                Text("Back speakers").font(.bodyBase).foregroundStyle(Color.paper)
            }

            // Everything below is set-once-and-forget: a ceiling you pick when
            // the room is new, and per-speaker trim you only touch if the pair
            // sounds uneven. None of it belongs in the resting view.
            DisclosureGroup(isExpanded: $showFineTuning) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Volume limit").font(.bodySmall).foregroundStyle(Color.paper)
                            Spacer()
                            let shownLimit = Int(store.volumeLimit)
                            Text("\(shownLimit)%")
                                .font(.serif(11, weight: .medium)).foregroundStyle(Color.paper60)
                                .contentTransition(.numericText(value: Double(shownLimit)))
                                .animation(.snappy(duration: 0.2), value: shownLimit)
                        }
                        HSlider(value: $store.volumeLimit)
                        Text("Nothing is ever sent louder than this.")
                            .font(.badge).foregroundStyle(Color.paper35)
                    }
                    Divider().overlay(Color.hairline)
                    ForEach(store.speakers.filter { $0.kind != .extra || $0.enabled }) { sp in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sp.name)
                                .font(.bodySmall).foregroundStyle(Color.paper)
                            HStack(spacing: 8) {
                                Text("Loudness").font(.badge).foregroundStyle(Color.paper35)
                                    .frame(width: 56, alignment: .leading)
                                HSlider(value: Binding(
                                    get: { (sp.gain - 0.25) / 3.75 * 100 },
                                    set: { store.setGain(0.25 + $0 / 100 * 3.75, for: sp) }))
                                Text(String(format: "%.1fx", sp.gain))
                                    .font(.serif(11, weight: .medium))
                                    .foregroundStyle(Color.paper60)
                                    .frame(width: 30, alignment: .trailing)
                            }
                            // TIMING removed 2026-08-01, along with the Space
                            // slider it shadowed. Both speakers are AirPlay 2 on
                            // a shared PTP grandmaster and already arrive
                            // together (measured: `clock - pts` identical to the
                            // millisecond on both), so the app now enforces a
                            // zero offset — which means this control would have
                            // been reset by the next refreshSpeakers() anyway.
                            // A button that silently undoes itself is worse than
                            // no button.
                        }
                    }
                    Text("Loudness balances speakers that sound quieter or louder than the others.")
                        .font(.badge).foregroundStyle(Color.paper35)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            } label: {
                Text("Fine tuning").font(.bodyBase).foregroundStyle(Color.paper60)
            }
            .tint(Color.paper35)

            Spacer()
        }
        .task {
            while !Task.isCancelled {
                await store.refreshSpeakers()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// The discovered names, plus the saved front/back names even when the
    /// engine has not found those speakers (yet, or at all). A Picker whose
    /// selection is not among its options shows blank and logs a warning;
    /// showing the remembered name is the truth.
    private var pickerNames: [String] {
        var names = Array(Set(store.speakers.map(\.name))).sorted()
        for saved in [store.frontName, store.backName] where !saved.isEmpty && !names.contains(saved) {
            names.append(saved)
        }
        return names
    }

    private func placementBinding(_ kind: RoomSpeaker.Kind) -> Binding<String> {
        Binding(get: { kind == .front ? store.frontName : store.backName },
                set: { name in
                    store.setPlacement(kind, for: store.speakers.first { $0.name == name })
                })
    }
}

/// The one control that settles lip sync by ear.
///
/// The app measures how far the room is behind the Mac and hands that figure to
/// the browser extension, which holds the picture back by exactly that much.
/// The measurement is good to a few tens of milliseconds, but it rests on an
/// assumption about how much output latency the AirPlay receivers compensate
/// for themselves — and that is worth a couple of hundred either way. Rather
/// than argue with it from a log, this is the correction, dragged while a face
/// is talking. Zero is the measurement, untouched.
struct LipSyncTrim: View {
    @Environment(DALIStore.self) private var store

    private var trim: Int { Int(store.delayTrimMs.rounded()) }
    private var totalMs: Int { Int((store.roomDelaySec * 1000).rounded()) }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Color.hairline)
            HStack(spacing: 8) {
                Text("Lip sync").font(.bodyBase).foregroundStyle(Color.paper)
                Spacer()
                if trim != 0 {
                    Button("Reset") { store.delayTrimMs = 0 }
                        .buttonStyle(.plain)
                        .font(.badge)
                        .foregroundStyle(Color.accentBlue)
                }
                Text(trim == 0 ? "\(totalMs) ms" : String(format: "%@%d ms  (%d)", trim > 0 ? "+" : "", trim, totalMs))
                    .font(.serif(11, weight: .medium))
                    .foregroundStyle(Color.paper60)
                    .monospacedDigit()
            }
            HSlider(value: Binding(
                get: { (store.delayTrimMs + 400) / 800 * 100 },
                set: { store.delayTrimMs = ($0 / 100 * 800 - 400).rounded() }))
            Text("Play a video with a face in it and drag until the mouth matches the sound. Left shows the picture sooner. The room's own animation follows it.")
                .font(.badge).foregroundStyle(Color.paper35)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EngineSettings: View {
    @Environment(DALIStore.self) private var store
    // 700 is the migration-blessed value (v10): the deep 2250ms buffer was pure
    // latency once the drift-anchor bug was fixed. Music keeps that headroom for
    // weak Wi-Fi; Video drops to the engine's 500ms practical floor.
    @AppStorage("dali.startBufferMs") private var startBufferMs = 700.0

    /// Two honest modes instead of a millisecond slider plus a toggle that
    /// silently moved the same slider. Music buys stability with delay; Video
    /// spends stability to keep picture and sound together.
    private enum Mode: String, CaseIterable, Identifiable {
        case music = "Music", video = "Video"
        var id: String { rawValue }
        var bufferMs: Double { self == .music ? 700 : 500 }
        var blurb: String {
            self == .music
            ? "450ms of headroom so every speaker starts together and weak Wi-Fi can't stutter it."
            : "Less audio buffering. Pair with the DALI Video Sync browser extension to match video to your speakers."
        }
    }
    private var mode: Mode { startBufferMs <= 600 ? .video : .music }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Engine").font(.serifSection).foregroundStyle(Color.paper)

            Picker("", selection: Binding(
                get: { mode },
                set: { m in startBufferMs = m.bufferMs; store.restartEngine() })) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)

            Text(mode.blurb)
                .font(.badge).foregroundStyle(Color.paper35)
                .fixedSize(horizontal: false, vertical: true)

            LipSyncTrim()

            // Wired lip-sync path. Nothing to do with the buffer picker above —
            // see VideoMode.swift.
            VideoModeControl()

            Spacer()

            HStack(spacing: 14) {
                Button("Restart engine") { store.restartEngine() }
                Button("Open log") {
                    let log = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("DALI/engine/var/owntone.log")
                    NSWorkspace.shared.open(log)
                }
            }
            .font(.bodyMedium).foregroundStyle(Color.accentBlue).buttonStyle(.plain)

            Text("DALI \(Self.appVersion) (build \(Self.appBuild)) · OwnTone 29.2")
                .font(.badge).foregroundStyle(Color.paper35)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
