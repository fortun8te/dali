// DALI — Settings: a small sidebar and grouped rows, System Settings style.

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var section: Section = Self.initialSection

    /// UI harness only: `DALI_PREVIEW_TAB=room|engine` picks the first pane.
    private static var initialSection: Section {
        guard DALIStore.isPreview,
              let tab = ProcessInfo.processInfo.environment["DALI_PREVIEW_TAB"],
              let s = Section.allCases.first(where: { $0.rawValue.lowercased() == tab }) else { return .general }
        return s
    }

    enum Section: String, CaseIterable {
        case general = "General", room = "Room", engine = "Sound"
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .room: return "hifispeaker.2"
            case .engine: return "waveform"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases, id: \.self) { s in
                    SidebarItem(title: s.rawValue, icon: s.icon, selected: section == s) { section = s }
                }
                Spacer()
            }
            .padding(Space.s)
            .frame(width: 148)

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    Text(section.rawValue).font(.emphasis).foregroundStyle(Color.paper)
                        .padding(.leading, Space.m)
                    Group {
                    switch section {
                    case .general: GeneralSettings()
                    case .room: RoomSettings()
                    case .engine: EngineSettings()
                    }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.l)
            }
            .scrollIndicators(.automatic)
            .modifier(NoScrollEdgeEffect())
        }
        .frame(width: 520, height: 400)
        .background(Color.ink.ignoresSafeArea())
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
    }
}

private struct SidebarItem: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.body13)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.paper : Color.paper62)
            .padding(.horizontal, Space.s)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(hovering && !selected ? 0.05 : 0)))
            .modifier(SelectedGlass(on: selected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
    }
}

/// Title row inside a group: label left, control right.
private struct SettingLine<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body13).foregroundStyle(Color.paper)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Color.paper38)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s)
            trailing()
        }
    }
}

struct GeneralSettings: View {
    @AppStorage("dali.launchAtLogin") private var launchAtLogin = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            SettingsGroup {
                SettingLine(title: "Launch at login") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.accentBlue)
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                if on { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch { launchAtLogin = !on }
                        }
                }
            }
            SettingsGroup {
                SettingLine(title: "Setup guide") {
                    Button("Open") { openWindow(id: "setup") }
                        .buttonStyle(SecondaryButtonStyle(accent: true))
                }
            }
        }
    }
}

struct RoomSettings: View {
    @Environment(DALIStore.self) private var store
    @AppStorage("dali.showFineTuning") private var showFineTuning = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Space.xl) {
            SettingsGroup(title: "Speakers", footer: "Front and Back set the room picture.") {
                if store.speakers.isEmpty {
                    Text("No speakers found yet. Check their power and Wi-Fi.")
                        .font(.body13).foregroundStyle(Color.paper62)
                }
                ForEach(store.speakers) { SpeakerControlRow(speaker: $0) }
                HStack {
                    if let message = store.discoveryMessage {
                        Text(message).font(.caption).foregroundStyle(Color.paper62)
                    }
                    Spacer()
                    Button("Look again") { Task { await store.refreshSpeakers() } }
                        .buttonStyle(SecondaryButtonStyle(accent: true))
                        .disabled(store.isDiscovering)
                }
            }

            SettingsGroup(title: "Room plan") {
                SettingLine(title: "Front") { placementPicker(.front, excluding: store.backName) }
                SettingLine(title: "Back") { placementPicker(.back, excluding: store.frontName) }
                SettingLine(title: "Test each corner", detail: store.speakerTestCorner?.title) {
                    Button(store.isSpeakerTesting ? "Stop" : "Play") {
                        store.toggleSpeakerTest()
                    }
                    .buttonStyle(SecondaryButtonStyle(accent: true))
                    .disabled(!store.canTestSpeakers && !store.isSpeakerTesting)
                    .help(store.canTestSpeakers
                          ? "Play a sound from each corner in turn."
                          : "Press Play in the DALI window first.")
                }
                SettingLine(title: "Send a sound around the room") {
                    Button(store.circleStartedAt != nil ? "Stop" : "Play") {
                        store.toggleCircleTest()
                    }
                    .buttonStyle(SecondaryButtonStyle(accent: true))
                    .disabled(!store.canTestSpeakers && !store.isSpeakerTesting)
                }
            }

            VStack(alignment: .leading, spacing: Space.s) {
                Button {
                    withAnimation(Motion.spring) { showFineTuning.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showFineTuning ? 90 : 0))
                        Text("Fine tuning")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.leading, Space.m)

                if showFineTuning {
                    SettingsGroup {
                        SliderRow(value: $store.volumeLimit, readout: "\(safeInt(store.volumeLimit))%", labelWidth: 96) {
                            Text("Volume limit").font(.body13).foregroundStyle(Color.paper)
                        }
                        Text("100% leaves speaker loudness unchanged.")
                            .font(.caption).foregroundStyle(Color.paper62)
                        ForEach(store.speakers.filter { $0.kind != .extra || $0.enabled }) { sp in
                            if sp.levelCurve != nil {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Space.s) {
                                        Text(sp.name).font(.body13).foregroundStyle(Color.paper).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text("\(safeInt((store.effectiveGain(sp) * 100).rounded()))% now")
                                            .font(.readout).foregroundStyle(Color.paper62)
                                    }
                                    BalanceTrimControl(speaker: sp)
                                    Text("Use − and + to match the other speaker.")
                                        .font(.caption).foregroundStyle(Color.paper62)
                                }
                            } else {
                                HStack(spacing: Space.s) {
                                    SliderRow(value: Binding(get: { (sp.gain - 0.25) / 3.75 * 100 },
                                                             set: { store.setGain(0.25 + $0 / 100 * 3.75, for: sp) }),
                                              readout: "\(safeInt((sp.gain * 100).rounded()))%", labelWidth: 96) {
                                        Text(sp.name).font(.body13).foregroundStyle(Color.paper)
                                            .lineLimit(1).help("\(sp.name) loudness adjustment")
                                    }
                                    .accessibilityLabel("\(sp.name) loudness")
                                    if sp.gain != 1 {
                                        Button("Reset") { store.setGain(1, for: sp) }
                                            .buttonStyle(SecondaryButtonStyle())
                                            .accessibilityLabel("Reset \(sp.name) loudness")
                                    }
                                }
                            }
                        }
                        ForEach(store.speakers.filter { $0.kind != .extra || $0.enabled }) { sp in
                            SpeakerCurveEditor(speaker: sp)
                        }
                    }
                }
            }
        }
        .visibleTask(id: 0) {
            while !Task.isCancelled {
                await store.refreshSpeakers()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func placementPicker(_ kind: RoomSpeaker.Kind, excluding other: String) -> some View {
        Picker(kind == .front ? "Front" : "Back", selection: placementBinding(kind)) {
            Text("None").tag("")
            ForEach(pickerNames.filter { $0 != other }, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 180)
    }

    /// Discovered names plus the saved ones, so a picker never shows blank
    /// for a remembered speaker that is not on the network right now.
    private var pickerNames: [String] {
        var names = Array(Set(store.speakers.map(\.name))).sorted()
        for saved in [store.frontName, store.backName] where !saved.isEmpty && !names.contains(saved) {
            names.append(saved)
        }
        return names
    }

    private func placementBinding(_ kind: RoomSpeaker.Kind) -> Binding<String> {
        Binding(get: { kind == .front ? store.frontName : store.backName },
                set: { name in store.setPlacement(kind, for: store.speakers.first { $0.name == name }) })
    }
}

/// One group row per speaker: a disclosure line that opens a 16-step curve.
/// Step picks the Mac volume point; − and + move that point's speaker level.
private struct SpeakerCurveEditor: View {
    @Environment(DALIStore.self) private var store
    let speaker: RoomSpeaker
    @State private var expanded = false
    @State private var step = 1
    @State private var rejected = false

    private static let range: ClosedRange<Double> = 25...400
    private static let stepSize = 5.0

    private var values: [Double] { store.masterCurveValues(for: speaker) }
    private var current: Double { values[step - 1] }
    private var limited: Bool {
        speaker.relVolume * (Double(step) / 16) * (store.volumeLimit / 100) * (current / 100) >= store.volumeLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withAnimation(Motion.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("\(speaker.name) · Mac volume")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityHint(expanded ? "Hides the curve" : "Shows the curve")

            if expanded {
                SettingLine(title: "Mac volume") {
                    HStack(spacing: Space.s) {
                        Text("Step \(step) of 16")
                            .font(.readout).foregroundStyle(Color.paper62)
                        Stepper("Mac volume step", value: $step, in: 1...16)
                            .labelsHidden()
                            .accessibilityValue("Step \(step) of 16")
                    }
                }

                SettingLine(title: "Speaker level") {
                    levelControl
                }

                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(rejected
                         ? "Adjust a nearby step first to keep volume rising evenly."
                         : limited ? "Volume limit reached at this step." : "Applies to Mac audio. The volume limit still applies.")
                        .font(.caption).foregroundStyle(Color.paper62)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.s)
                    if speaker.masterCurve != nil {
                        Button("Reset") { store.resetMasterCurve(for: speaker); rejected = false }
                            .buttonStyle(SecondaryButtonStyle(accent: true))
                            .accessibilityLabel("Reset \(speaker.name) Mac volume curve")
                    }
                }
            }
        }
    }

    /// Readout plus a capsule − | + pair, the same control as the loudness match row.
    private var levelControl: some View {
        let low = current <= Self.range.lowerBound
        let high = current >= Self.range.upperBound
        return HStack(spacing: Space.s) {
            Text("\(safeInt(current))%")
                .font(.readout).foregroundStyle(Color.paper62)
                .contentTransition(.numericText())
                .animation(Motion.fade, value: current)
            HStack(spacing: 0) {
                Button("\u{2212}") { adjust(-Self.stepSize) }
                    .buttonStyle(.plain).font(.captionMedium)
                    .foregroundStyle(low ? Color.paper38 : Color.paper)
                    .disabled(low)
                    .accessibilityLabel("Lower \(speaker.name) level at step \(step)")
                    .frame(width: 24, height: 18).contentShape(Rectangle())
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5, height: 10)
                Button("+") { adjust(Self.stepSize) }
                    .buttonStyle(.plain).font(.captionMedium)
                    .foregroundStyle(high ? Color.paper38 : Color.paper)
                    .disabled(high)
                    .accessibilityLabel("Raise \(speaker.name) level at step \(step)")
                    .frame(width: 24, height: 18).contentShape(Rectangle())
            }
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .frame(height: 20)
        }
    }

    private func adjust(_ amount: Double) {
        var next = values
        next[step - 1] = min(Self.range.upperBound, max(Self.range.lowerBound, next[step - 1] + amount))
        rejected = !store.setMasterCurve(next, for: speaker)
    }
}

/// Lip sync, settled by ear. The measured delay rests on an assumption about
/// how much output latency the receivers compensate themselves; this is the
/// correction, dragged while a face is talking. Zero is the measurement.
struct LipSyncTrim: View {
    @Environment(DALIStore.self) private var store

    private var trim: Int { safeInt(store.delayTrimMs.rounded()) }

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Lip sync").font(.body13).foregroundStyle(Color.paper)
                Spacer()
                if trim != 0 {
                    Button("Reset") { store.delayTrimMs = 0 }
                        .buttonStyle(SecondaryButtonStyle(accent: true))
                        .font(.caption)
                }
                Text(trim == 0 ? store.roomDelayLabel : "\(trim > 0 ? "+" : "")\(trim) ms · \(store.roomDelayLabel)")
                    .font(.readout)
                    .foregroundStyle(Color.paper62)
                    .contentTransition(.numericText())
                    .animation(Motion.fade, value: trim)
            }
            DALISlider(value: Binding(get: { (store.delayTrimMs + 400) / 800 * 100 },
                                      set: { store.delayTrimMs = ($0 / 100 * 800 - 400).rounded() }))
                .accessibilityLabel("Lip sync trim")
                .help("Drag while a face is talking until the mouth matches the sound. Left shows the picture sooner.")
        }
    }
}

struct EngineSettings: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var apple = AppleSender.shared

    private var senderFooter: String {
        apple.isSelected
            ? "Beta. About two seconds behind. Replaces the DALI sound engine."
            : "Short delay with automatic video sync."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if AppleSender.betaVisible {
            SettingsGroup(title: "Sender", footer: senderFooter) {
                SettingLine(title: "Play with") {
                    Picker("Play with", selection: $apple.isSelected) {
                        Text("DALI").tag(false)
                        Text("Apple (beta)").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: 196)
                    .help("Choose how sound is sent to the room. Switching stops the current sound.")
                }
                if apple.isSelected {
                    SettingLine(title: "Speakers", detail: apple.speakersSummary) {
                        Button("Choose…") { openWindow(id: "apple-test") }
                            .buttonStyle(SecondaryButtonStyle(accent: true))
                    }
                }
            }
            }
            SettingsGroup(title: "Video sync") {
                SettingLine(title: "Automatic video sync") {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentBlue)
                }
                LipSyncTrim()
            }
            SettingsGroup(footer: "DALI \(Self.appVersion) (\(Self.appBuild)) · OwnTone 29.2") {
                SettingLine(title: "Sound engine", detail: "Restart it if speakers stop responding.") {
                    HStack(spacing: Space.l) {
                        Button("Open log") {
                            let log = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("DALI/engine/var/owntone.log")
                            NSWorkspace.shared.open(log)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Restart") { store.restartEngine() }
                            .buttonStyle(SecondaryButtonStyle(accent: true))
                            .disabled(apple.isSelected)
                            .help(apple.isSelected ? "The engine is off while Apple AirPlay is selected" : "Restart the sound engine")
                    }
                }
            }
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

/// macOS 26 tints the titlebar band over a scroll view; on an opaque ink
/// window that reads as a stray grey strip. Plain edge instead.
private struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

private struct SelectedGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glassPill() } else { content }
    }
}
