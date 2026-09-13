// DALI — main window content.

import SwiftUI

struct PanelView: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 13) {
            header
            BigSwitch()
            if case .error(let message) = store.phase {
                ErrorCard(message: message)
            } else {
                RoomView()
            }
            // ExtrasDisclosure removed: a drawer of 7 other speakers under the
            // main control argued against the product's own thesis (the room is
            // FIXED — front pair, back pair, done). Extra speakers are still
            // discoverable and assignable in Settings → Room.
            footer
        }
        // The window is `.hiddenTitleBar` + `.fullSizeContentView`, so y=0 of
        // this stack is the top of the WINDOW, not the top of a titlebar. The
        // traffic lights sit at y 9…23 (measured, not guessed: 14pt buttons in
        // a 32pt titlebar) and they overlap the wordmark's column, so the top
        // padding only has to clear 23 — not duplicate a whole titlebar. The
        // old 21+18=39 cleared it twice over, and then the fixed height added
        // centering slack on top of that.
        //
        // 25 puts the "DALI" text frame at y=25 and its cap top at ~30 — two
        // points of breathing room under the lights, ~30pt of air over the cap.
        .padding(.horizontal, 21)
        .padding(.top, 25)
        .padding(.bottom, 21)
        // Height, honestly. Every figure below was measured offscreen at the
        // 318pt content width this padding leaves, not estimated:
        //
        //     header (live, with StatusPill) ....................  28
        //     BigSwitch .........................................  55
        //     footer (the SourcePicker capsule sets it in mirror
        //       mode; 15 in library mode, where it is absent) ...  25
        //     3 × VStack spacing of 13 ..........................  39
        //     room card chrome (13pt card padding ×2, 3 × 13pt
        //       spacing, 2 × 24pt PairRow, 26pt SourceHint) ..... 139
        //     top padding 25 + bottom padding 21 ................  46
        //     ---------------------------------------------------------
        //     fixed total ....................................... 332
        //
        // So the window is 332 + whatever the room canvas is. The old 583 was
        // 360×φ over a fixed 190pt canvas — 61pt more than the content wanted.
        // A VStack whose children are ALL fixed-height centers itself in a
        // fixed frame, so that surplus came out as ~30pt of dead air at BOTH
        // ends: 73pt above the wordmark's cap, 50pt under the footer.
        //
        // 540 = 332 + 208, a clean 360×540 (2:3). The room canvas is now the
        // flexible member of the stack (see RoomView), so it takes the entire
        // remainder and there is no slack left to centre — the two paddings
        // above are the only air at the ends, in every state. It also means the
        // 10pt the footer loses in library mode goes to the canvas rather than
        // reopening a gap.
        //
        // φ is not reachable while keeping this honest: 583 would need a 251pt
        // canvas — 292×251 is nearly square, and the cabinets (drawn at a fixed
        // 22pt) get lost in it. Content fit wins over φ.
        .frame(width: 360, height: 540)
        .background(panelBackground.ignoresSafeArea())
        .task {
            await store.refreshSpeakers()
            await store.loadLibrary()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("DALI")
                .font(.serifSection)
                .foregroundStyle(Color.paper)
            Spacer()
            if store.phase == .streaming || isError {
                StatusPill()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(DS.spring, value: store.phase)
        .animation(DS.spring, value: store.roomChrome)
    }

    private var isError: Bool {
        if case .error = store.phase { return true }
        return false
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if store.mode == .mirror {
                SourcePicker()
            }
            Spacer()
            LatencyHint()
            SettingsGear { openSettings() }
        }
    }

    private var panelBackground: some View {
        ZStack {
            DarkGlassSurface(cornerRadius: DS.panelRadius, tintAlpha: 0.74, clear: false)
            RoundedRectangle(cornerRadius: DS.panelRadius - 2, style: .continuous)
                .inset(by: 3)
                .fill(Color.field.opacity(0.84))
            // Ambient pools of light give the translucent material something to
            // refract, like the smoked Siri surfaces in the new Mac design.
            RadialGradient(colors: [Color.warmWhite.opacity(0.060), .clear], center: .topLeading, startRadius: 4, endRadius: 190)
            RadialGradient(colors: [Color.accentBlue.opacity(0.035), .clear], center: .bottomTrailing, startRadius: 4, endRadius: 250)
            LinearGradient(
                colors: [Color.paper.opacity(0.090), .clear, Color.accentBlue.opacity(0.016)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
    }
}

/// The gear: the only control in the panel that had no hover state at all, so
/// it read as a glyph rather than a button. It lifts and turns a few degrees on
/// hover — the same quiet register as the row hover, nothing more.
struct SettingsGear: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.paper : Color.paper60)
                .rotationEffect(.degrees(hovering ? 22 : 0))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(Color.paper.opacity(hovering ? 0.06 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Settings")
    }
}

struct StatusPill: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            dot
            Text(store.roomChrome.pillLabel)
                .font(.badge)
                .tracking(0.8)
                .foregroundStyle(Color.paper60)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.paper.opacity(0.045)))
    }

    /// Breathing pulse only when speakers are actually healthy — not merely
    /// while the session phase is `.streaming`.
    @ViewBuilder
    private var dot: some View {
        let base = Circle().fill(dotColor).frame(width: 6, height: 6)
        if store.roomChrome.isBreathing && !reduceMotion {
            base.phaseAnimator([0.55, 1.0]) { view, o in
                view.opacity(o)
            } animation: { _ in .easeInOut(duration: 1.3) }
        } else {
            base
        }
    }

    private var dotColor: Color {
        switch store.roomChrome {
        case .live: return .lime
        case .catchingUp: return .accentBlue
        case .speakerOut, .error: return .amber
        default: return .amber
        }
    }
}

/// Source menu: all system audio, or one running app (Spotify-only mode).
struct SourcePicker: View {
    @Environment(DALIStore.self) private var store
    @State private var apps: [(pid: pid_t, name: String)] = []
    @State private var hovering = false

    var body: some View {
        Menu {
            Button {
                store.source = .system
            } label: {
                if store.source == .system {
                    Label("All audio", systemImage: "checkmark")
                } else {
                    Text("All audio")
                }
            }
            Divider()
            ForEach(apps, id: \.pid) { app in
                Button {
                    store.source = .app(pid: app.pid, name: app.name)
                } label: {
                    if case .app(let pid, _) = store.source, pid == app.pid {
                        Label(app.name, systemImage: "checkmark")
                    } else {
                        Text(app.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.source == .system ? "macwindow.on.rectangle" : "app.badge.checkmark")
                    .font(.system(size: 9))
                Text(store.source.label)
                    .font(.bodySmall)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundStyle(hovering ? Color.paper : Color.paper60)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                Capsule().fill(Color.paper.opacity(hovering ? 0.04 : 0))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What goes to the room: everything the Mac plays, or one app")
        // The list was only built once, on appear, so an app launched after the
        // window opened never showed up until the window was reopened. Rebuild
        // it as the pointer arrives — a menu opens on click, so by the time it
        // is open the list is current.
        .onHover { over in
            hovering = over
            if over { refreshApps() }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear { refreshApps() }
    }

    private func refreshApps() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app in app.localizedName.map { (app.processIdentifier, $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

struct LatencyHint: View {
    @Environment(DALIStore.self) private var store
    @State private var showing = false
    @State private var hovering = false
    // Read the real setting rather than printing a constant. The hardcoded
    // "~2s" was inherited from an era when the start buffer WAS 2250ms; a
    // migration has since pulled it to 700, so the lead is ~450ms and the old
    // label overstated it by 4x.
    @AppStorage("dali.startBufferMs") private var startBufferMs = 700.0

    /// OwnTone schedules with lead = start_buffer_ms − 50ms, while the receiver
    /// still contributes its advertised 250ms output latency. The delay heard in
    /// the room is therefore start_buffer_ms + 200ms.
    /// While the room is live this is the MEASURED delay the browser is also
    /// being given; idle, it is the nominal figure for the configured buffer.
    private var leadMs: Int {
        store.phase == .streaming ? max(0, Int((store.roomDelaySec * 1000).rounded()))
                                  : max(0, Int(startBufferMs) + 200)
    }
    private var lead: String {
        leadMs >= 1000 ? String(format: "%.1fs", Double(leadMs) / 1000) : "\(leadMs)ms"
    }
    /// While the browser extension is holding a picture back by this amount,
    /// the delay is no longer a delay to the eye — say so, quietly.
    private var synced: Bool { store.nowPlaying.anyHeld }
    private var label: String { synced ? "\(lead) · in sync" : "\(lead) delay" }

    var body: some View {
        Button { showing.toggle() } label: {
            (Text(lead + (synced ? " · " : " delay"))
             + Text(synced ? "in sync" : "")
                .foregroundStyle(Color.accentBlue.opacity(hovering || showing ? 0.85 : 0.6)))
                .font(.badge)
                .foregroundStyle(hovering || showing ? Color.paper60 : Color.paper35)
        }
        .animation(.easeOut(duration: 0.2), value: synced)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Why the room plays a moment behind the Mac")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(synced
                 ? "Every speaker waits \(lead) before playing, and the browser is holding the picture back by the same amount — so what you see and what you hear line up."
                 : "Every speaker waits \(lead) before playing, so they all start on the same beat.\n\nInaudible for music. For video, Settings → Engine → Video shortens it.")
                .font(.bodySmall)
                .foregroundStyle(Color.paper60)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 240)
        }
    }
}

struct ErrorCard: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(Color.amber)
            Text(message)
                .font(.bodySmall)
                .foregroundStyle(Color.paper60)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                if message.contains("permission") {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .buttonStyle(.plain)
                    .font(.bodyMedium)
                    .foregroundStyle(Color.accentBlue)
                }
                // The cheap way out first. Most errors are a bad moment on the
                // network; a fresh start fixes them in seconds. The engine
                // restart (10 s+ respawn) stays available as the second try.
                Button("Try again") { store.retryAfterError() }
                    .buttonStyle(.plain)
                    .font(.bodyMedium)
                    .foregroundStyle(Color.accentBlue)
                Button("Restart engine") { store.restartEngine() }
                    .buttonStyle(.plain)
                    .font(.bodyMedium)
                    .foregroundStyle(Color.paper60)
            }
        }
        .padding(18)
        // Grows exactly like the room card it replaces, so swapping into the
        // error state keeps the panel's rhythm instead of leaving a hole where
        // the taller card used to be. 200 stays the floor.
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .background(CardBackground())
        // One-shot shake when the message changes: a new problem gets a nudge,
        // not a new layout.
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: message) { view, x in
            view.offset(x: reduceMotion ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-5, duration: 0.08)
                CubicKeyframe(4, duration: 0.09)
                CubicKeyframe(-2, duration: 0.08)
                CubicKeyframe(0, duration: 0.06)
            }
        }
    }
}
