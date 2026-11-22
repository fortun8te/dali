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
            DelayLabel()
            if store.hasRoomPlan { ExtrasButton() }
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
                Text(store.source.label).font(.body13).lineLimit(1).truncationMode(.tail)
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
        .help("Choose all audio or one app")
        .accessibilityLabel("Audio source")
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

/// Only says something when it matters: "Video in sync" while the browser companion
/// is matching the picture to the room, or Apple's longer delay. Click for the why.
struct DelayLabel: View {
    @Environment(DALIStore.self) private var store
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let apple = AppleSender.shared.isSelected
        let synced = store.videoInSync && !apple
        Button { showing.toggle() } label: {
            Text(apple ? "About 2 s behind" : "Video in sync")
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(apple ? (hovering || showing ? Color.paper62 : Color.paper38)
                                       : Color.accentBlue.opacity(hovering || showing ? 0.95 : 0.7))
                .padding(.horizontal, 6)
                .frame(height: 28)
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .opacity(apple || synced ? 1 : 0)
        .allowsHitTesting(apple || synced)
        .accessibilityHidden(!apple && !synced)
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.fade, value: synced)
        .help("About video sync")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(apple
                 ? "Apple AirPlay plays about two seconds behind the Mac."
                 : "The browser companion delays the picture to match the speakers.")
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
            HStack(spacing: 3) {
                Image(systemName: "plus").symbolRenderingMode(.hierarchical)
                    .font(.system(size: 13, weight: .regular))
                if enabledCount > 0 { Text("\(enabledCount)").font(.caption.monospacedDigit()) }
            }
        }
        .buttonStyle(IconButtonStyle(glass: false))
        .help("More speakers")
        .accessibilityLabel("More speakers")
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
