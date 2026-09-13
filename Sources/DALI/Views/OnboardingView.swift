import SwiftUI
import AppKit

struct OnboardingSpeaker: Identifiable {
    let id: String
    let name: String
    let detail: String
    let selected: Bool
    var available = true
}

/// The flow consumes display values and actions. Its preview has no dependency
/// on DALIStore, which would start the real audio engine merely by existing.
struct OnboardingView: View {
    let state: OnboardingState
    var speakers: [OnboardingSpeaker] = []
    var discoveryError: String?
    var discover: () -> Void = {}
    var toggleSpeaker: (String) -> Void = { _ in }
    var finish: () -> Void = {}
    var preview = false
    var previewIcon: NSImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionError: String?
    @State private var audioSettingsOpened = false
    @State private var browserSetupOpened = false
    @State private var helper = AudioPermissionHelper()

    private var selectedCount: Int { speakers.filter { $0.selected && $0.available }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            progress.padding(.top, 16).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    page
                    if let actionError {
                        Text(actionError)
                            .font(.bodySmall).foregroundStyle(Color.amber)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Setup issue: \(actionError)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 18)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 32)
        .padding(.bottom, 26)
        .frame(width: 420, height: state.step == .welcome || state.step == .ready ? 390 : 540)
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: state.step) { _, step in
            actionError = nil
            if step != .audio { helper.close() }
            if step == .speakers && !preview { discover() }
        }
        .onAppear { if state.step == .speakers && !preview { discover() } }
        .onDisappear { helper.close() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("DALI").font(.serifSection).foregroundStyle(Color.paper)
            Spacer()
            Text("\(state.step.rawValue + 1) / \(OnboardingState.Step.allCases.count)").font(.bodySmall).foregroundStyle(Color.paper60)
        }
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                Capsule().fill(step.rawValue <= state.step.rawValue ? Color.accentBlue : Color.paper.opacity(0.10))
                    .frame(height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(state.step.rawValue + 1) of \(OnboardingState.Step.allCases.count)")
    }

    @ViewBuilder private var page: some View {
        switch state.step {
        case .welcome: welcome
        case .audio: audio
        case .speakers: speakerSelection
        case .browser: browser
        case .ready: ready
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            title("Your sound.\nEverywhere.", body: "Play your Mac on one speaker or across your room.")
            HStack(spacing: 9) {
                Image(systemName: "wifi").foregroundStyle(Color.paper60)
                Text("Mac and speakers on the same Wi-Fi.")
                    .font(.bodySmall).foregroundStyle(Color.paper60)
            }
        }
    }

    private var audio: some View {
        VStack(alignment: .leading, spacing: 19) {
            title("Allow Mac audio.", body: "One permission to play sound on your speakers. No microphone access needed.")
            AudioPermissionCard(preview: preview, icon: previewIcon)
            Text("In System Settings, add DALI to Screen & System Audio Recording and turn it on.")
                .font(.bodySmall).foregroundStyle(Color.paper60)
                .fixedSize(horizontal: false, vertical: true)
            Text("Drag the app into the list, or use + to choose it.")
                .font(.bodySmall).foregroundStyle(Color.paper60)
            if audioSettingsOpened {
                smallAction("Open settings again", symbol: "arrow.up.forward") { openAudioSettings() }
            }

        }
    }

    private var speakerSelection: some View {
        VStack(alignment: .leading, spacing: 19) {
            title("Choose your speakers.", body: "Select one or more. You can change this later.")
            if let discoveryError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speakers are not available yet.").font(.bodyMedium).foregroundStyle(Color.paper)
                    Text(discoveryError).font(.bodySmall).foregroundStyle(Color.paper60)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground())
            } else if speakers.isEmpty {
                VStack(spacing: 13) {
                    SpeakerIcon(kind: .pair).scaleEffect(1.15)
                    Text("Looking for AirPlay speakers…").font(.bodyMedium).foregroundStyle(Color.paper)
                    Text("Turn them on and connect to the same Wi-Fi. Allow local network access if asked.")
                        .font(.bodySmall).foregroundStyle(Color.paper60)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22).frame(maxWidth: .infinity)
                .background(CardBackground())
            } else {
                VStack(spacing: 1) {
                    ForEach(speakers) { speaker in
                        Button { toggleSpeaker(speaker.id) } label: {
                            HStack(spacing: 12) {
                                SpeakerIcon(active: speaker.selected)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(speaker.name).font(.bodyMedium).foregroundStyle(Color.paper)
                                    Text(speaker.detail).font(.bodySmall).foregroundStyle(Color.paper60)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: speaker.selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(speaker.selected ? Color.accentBlue : Color.paper35)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!speaker.available)
                        .accessibilityLabel(speaker.name)
                        .accessibilityValue(speaker.selected ? "Selected" : "Not selected")
                        .accessibilityHint("Choose this speaker for room audio")
                    }
                }
                .background(CardBackground())
            }
            smallAction("Look again", symbol: "arrow.clockwise") { if !preview { discover() } }
            Text("Nothing plays until you press Play in DALI.")
                .font(.bodySmall).foregroundStyle(Color.paper60)
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 19) {
            title("Watch in sync.", body: "Optional. Add the Chrome extension to match video with your room audio.")
            VStack(alignment: .leading, spacing: 16) {
                instruction("1", "Turn on Developer mode", detail: "At the top of Chrome’s extensions page.")
                instruction("2", "Click Load unpacked", detail: "Choose the ChromeExtension folder we open for you.")
            }
            if browserSetupOpened {
                HStack(spacing: 20) {
                    smallAction("Open Chrome again", symbol: "arrow.up.forward") { openChrome() }
                    smallAction("Show folder", symbol: "folder") { revealExtension() }
                }
            }
            Text("YouTube, TikTok, Instagram and other video sites. Some protected videos cannot be synced.")
                .font(.bodySmall).foregroundStyle(Color.paper60)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 24) {
            title("Ready when you are.", body: selectedCount > 0
                  ? "\(selectedCount == 1 ? "1 speaker selected" : "\(selectedCount) speakers selected"). Press Play in DALI when you’re ready."
                  : "Choose your speakers in DALI, then press Play.")
            Text("Your Mac’s volume keys work as usual. Setup is always available in Settings.")
                .font(.bodySmall).foregroundStyle(Color.paper60)
                .fixedSize(horizontal: false, vertical: true)

        }
    }

    private func title(_ heading: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.serif(30)).foregroundStyle(Color.paper)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(body).font(.bodyLarge).foregroundStyle(Color.paper60)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func instruction(_ number: String, _ heading: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(number).font(.badge).foregroundStyle(Color.accentBlue)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentBlue.opacity(0.10)))
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.bodyMedium).foregroundStyle(Color.paper)
                Text(detail).font(.bodySmall).foregroundStyle(Color.paper60)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func smallAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.bodySmall).foregroundStyle(Color.accentBlue)
        }
        .buttonStyle(.plain)
    }

    private var primaryLabel: String {
        switch state.step {
        case .welcome: "Set up DALI"
        case .audio: audioSettingsOpened ? "Continue" : "Open System Settings"
        case .browser: browserSetupOpened ? "Continue" : "Set up Chrome"
        case .ready: "Open DALI"
        case .speakers: "Continue"
        }
    }

    private func openAudioSettings() {
        guard !preview else { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        if NSWorkspace.shared.open(url) {
            audioSettingsOpened = true
            helper.show()
        } else {
            actionError = "Open System Settings → Privacy & Security → Screen & System Audio Recording."
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                guard !preview else { return }
                if state.step == .audio && !audioSettingsOpened { openAudioSettings(); return }
                if state.step == .browser && !browserSetupOpened {
                    do {
                        let folder = try ExtensionInstaller.install()
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                        openChrome()
                        browserSetupOpened = true
                    } catch { actionError = error.localizedDescription }
                    return
                }
                if state.step == .ready { finish() }
                else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { state.advance() } }
            } label: {
                HStack {
                    Spacer()
                    Text(primaryLabel)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .font(.bodyMedium).foregroundStyle(Color.paper)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.accentBlue.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(state.step == .speakers && selectedCount == 0)
            .opacity(state.step == .speakers && selectedCount == 0 ? 0.45 : 1)
            HStack {
                if state.step != .welcome {
                    Button("Back") { if !preview { state.goBack() } }
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                }
                Spacer()
                if state.step == .welcome {
                    Text("No account needed").foregroundStyle(Color.paper35)
                } else if state.step != .ready {
                    Button("Skip for now") { if !preview { state.advance() } }
                }
            }
            .font(.bodySmall).foregroundStyle(Color.paper60).buttonStyle(.plain)
            .frame(height: 15)
        }
    }

    private var background: some View {
        ZStack {
            DarkGlassSurface(cornerRadius: DS.panelRadius, tintAlpha: 0.74, clear: false)
            RoundedRectangle(cornerRadius: DS.panelRadius - 2, style: .continuous)
                .inset(by: 3).fill(Color.field.opacity(0.94))
            RadialGradient(colors: [Color.warmWhite.opacity(0.065), .clear], center: .topLeading, startRadius: 4, endRadius: 230)
            RadialGradient(colors: [Color.accentBlue.opacity(0.05), .clear], center: .bottomTrailing, startRadius: 4, endRadius: 280)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.panelRadius, style: .continuous))
    }

    private func revealExtension() {
        guard !preview else { return }
        do {
            let folder = try ExtensionInstaller.install()
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    private func openChrome() {
        guard !preview else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            actionError = "Install Google Chrome, then open chrome://extensions in its address bar. You can also set up video sync later."
            return
        }
        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in actionError = "Open chrome://extensions in Chrome's address bar. \(error.localizedDescription)" }
            }
        }
    }
}

struct AudioPermissionCard: View {
    var preview = false
    var icon: NSImage?
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("DALI").font(.bodyMedium).foregroundStyle(Color.paper)
                Text("Drag into System Settings").font(.bodySmall).foregroundStyle(Color.paper60)
            }
            Spacer(minLength: 0)
            Image(systemName: "hand.draw").font(.system(size: 18)).foregroundStyle(Color.paper60)
        }
        .padding(13).background(CardBackground())
        .onDrag {
            preview ? NSItemProvider() : NSItemProvider(object: Bundle.main.bundleURL as NSURL)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("You can also use the plus button in System Settings to choose DALI from Applications.")
    }
}

/// An explicitly opened, temporary companion panel remains visible over Settings.
/// It only carries the app's file URL; dropping never grants a permission itself.
@MainActor
final class AudioPermissionHelper {
    private var panel: NSPanel?

    func show() {
        if let panel { panel.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 355, height: 114),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Allow DALI audio"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView:
            AudioPermissionCard().padding(14).background(Color.field).preferredColorScheme(.dark))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 178, y: screen.visibleFrame.minY + 50))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() { panel?.close(); panel = nil }
}
