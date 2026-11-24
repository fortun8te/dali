// DALI — the footer: where the sound comes from, how far behind the room
// plays, the extra speakers, settings. All secondary, all quiet.

import SwiftUI

struct PanelFooter: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: Space.xs) {
            if store.mode == .mirror { SourcePicker() }
            Spacer(minLength: 0)
            if store.hasRoomPlan { ExtrasButton() }
            DelayLabel()
            Button { openSettings() } label: {
                Image(systemName: "gearshape").symbolRenderingMode(.hierarchical)
                    .font(.system(size: 13, weight: .regular))
            }
                .buttonStyle(IconButtonStyle(glass: false))
                .help("Settings")
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 6)
        .frame(height: PanelMetrics.footerHeight)
        .glassPill()
    }
}

/// All system audio, or one running app.
struct SourcePicker: View {
    @Environment(DALIStore.self) private var store
    @State private var apps: [(pid: pid_t, name: String)] = []
    @State private var hovering = false

    var body: some View {
        Menu {
            Button { store.source = .system } label: {
                if store.source == .system { Label("All audio", systemImage: "checkmark") }
                else { Text("All audio") }
            }
            Divider()
            ForEach(apps, id: \.pid) { app in
                Button { store.source = .app(pid: app.pid, name: app.name) } label: {
                    if case .app(let pid, _) = store.source, pid == app.pid {
                        Label(app.name, systemImage: "checkmark")
                    } else {
                        Text(app.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.source.label).font(.body13)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.paper : Color.paper62)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What goes to the room: everything the Mac plays, or one app")
        // Rebuilt as the pointer arrives, so an app launched after the window
        // opened is in the list by the time the menu opens.
        .onHover { over in
            hovering = over
            if over { refreshApps() }
        }
        .animation(Motion.fade, value: hovering)
        .onAppear { refreshApps() }
    }

    private func refreshApps() {
        let me = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .compactMap { app in app.localizedName.map { (app.processIdentifier, $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

/// "540 ms delay", or "540 ms · in sync" while the browser companion is
/// checking in and matching the picture to the room. Click for the why.
struct DelayLabel: View {
    @Environment(DALIStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let apple = AppleSender.shared.isSelected
        let synced = store.videoInSync && !apple
        Button { showing.toggle() } label: {
            HStack(spacing: 3) {
                Text(apple ? "≈2 s" : store.roomDelayLabel)
                    .contentTransition(.numericText())
                Text(synced ? "· in sync" : "delay")
                    .foregroundStyle(synced ? Color.accentBlue.opacity(hovering ? 0.9 : 0.65)
                                            : (hovering || showing ? Color.paper62 : Color.paper38))
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .foregroundStyle(hovering || showing ? Color.paper62 : Color.paper38)
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.fade, value: synced)
        .help("Why the room plays a moment behind the Mac")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(apple
                 ? "Apple's AirPlay plays about two seconds behind the Mac. That suits music, not video."
                 : synced
                 ? "Every speaker waits \(store.roomDelayLabel) before playing, and the browser companion\(store.browserExtensionVersion.map { " (\($0))" } ?? "") holds the picture back by the same amount — so what you see and hear line up."
                 : "Every speaker waits \(store.roomDelayLabel) before playing, so they all start on the same beat. For browser video, the DALI companion matches the picture automatically.")
                .font(.body13)
                .foregroundStyle(Color.paper62)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.m)
                .frame(width: 248)
        }
    }
}

/// Speakers beyond the front/back plan, in a popover.
struct ExtrasButton: View {
    @Environment(DALIStore.self) private var store
    @State private var showing = false

    var body: some View {
        let extras = store.extras
        let enabledCount = extras.filter(\.enabled).count
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle").symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12, weight: .regular))
                Text(enabledCount > 0 ? "+\(enabledCount)" : "Add").font(.caption.monospacedDigit())
            }
        }
        .buttonStyle(IconButtonStyle(glass: false))
        .help("Add or manage more speakers")
        .accessibilityLabel("Add or manage more speakers")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                VStack(spacing: Space.l) {
                    if extras.isEmpty {
                        Text("No other speakers found. Check their power and Wi-Fi.")
                            .font(.caption).foregroundStyle(Color.paper62)
                    }
                    ForEach(extras) { SpeakerControlRow(speaker: $0) }
                    if let message = store.discoveryMessage {
                        Text(message).font(.caption).foregroundStyle(Color.paper62)
                    }
                    Button("Look again") { Task { await store.refreshSpeakers() } }
                        .buttonStyle(SecondaryButtonStyle(accent: true))
                        .disabled(store.isDiscovering)
                }
                .padding(Space.l)
            }
            .scrollIndicators(.never)
            .frame(width: 300)
            .frame(maxHeight: 280)
            .task { await store.refreshSpeakers() }
        }
    }
}
