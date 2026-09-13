// DALI — Dock app entry. One small fixed window, the whole app on one screen.

import SwiftUI
import Observation

@main
struct DALIApp: App {
    @State private var session = DALIApplicationSession()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DALI", id: "main") {
            Group {
                if session.onboarding.isPresented {
                    OnboardingHost(session: session, state: session.onboarding) {
                        session.completeSetup()
                    }
                } else if let store = session.store {
                    PanelView().environment(store)
                }
            }
            .background(WindowConfigurator())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Settings {
            if let store = session.store {
                SettingsView().environment(store)
            } else {
                Text("Finish setup in the DALI window to choose your speakers.")
                    .font(.bodyBase).padding(24).frame(width: 330)
            }
        }

        Window("DALI setup", id: "setup") {
            OnboardingGuide(session: session)
                .background(WindowConfigurator())
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        // Menu-bar quick control: the two-touches-a-day actions (start/stop,
        // see status) without a trip through the Dock. The room is fixed, so
        // the menu needs no device list — status, one verb, one shortcut in.
        MenuBarExtra {
            if let store = session.store, !session.onboarding.isPresented {
                MenuBarPanel().environment(store)
            } else {
                SetupMenuBarPanel()
            }
        } label: {
            Image(systemName: session.store?.phase.isOn == true ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
    }
}

@MainActor
@Observable
final class DALIApplicationSession {
    let onboarding: OnboardingState
    private(set) var store: DALIStore?

    init() {
        let defaults = UserDefaults.standard
        let persisted = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.fortun8te.dali") ?? [:]
        let engine = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DALI/engine")
        onboarding = OnboardingState(defaults: defaults, persisted: persisted,
                                     engineExists: FileManager.default.fileExists(atPath: engine.path))
        // Only a previously requested managed extension copy is updated.
        // Existing unpacked installs in other folders are left where they are.
        do { try ExtensionInstaller.updateExistingInstall() }
        catch { NSLog("DALI browser extension update: %@", error.localizedDescription) }
        if !onboarding.isPresented { ensureStore() }
    }

    func ensureStore() {
        guard store == nil else { return }
        DALIExecution.engineStarted = true
        store = DALIStore()
    }

    func completeSetup() {
        onboarding.complete()
        ensureStore()
    }
}

/// Closing an unstarted setup must not kill another running DALI's engine.
@MainActor
private enum DALIExecution { static var engineStarted = false }

private struct OnboardingHost: View {
    let session: DALIApplicationSession
    let state: OnboardingState
    let finish: () -> Void

    var body: some View {
        OnboardingView(state: state,
                       speakers: (session.store?.speakers ?? []).map {
                           OnboardingSpeaker(id: $0.id, name: $0.name,
                                             detail: $0.available ? $0.type : "Not available on this network",
                                             selected: $0.enabled, available: $0.available)
                       },
                       discoveryError: discoveryError,
                       discover: {
                           session.ensureStore()
                           Task { await session.store?.refreshSpeakers() }
                       },
                       toggleSpeaker: { id in
                           guard let store = session.store,
                                 let speaker = store.speakers.first(where: { $0.id == id }) else { return }
                           store.toggle(speaker)
                       }, finish: finish)
            .task(id: state.step) {
                guard state.step == .speakers else { return }
                session.ensureStore()
                while !Task.isCancelled {
                    await session.store?.refreshSpeakers()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
    }

    private var discoveryError: String? {
        if let store = session.store, case .error(let message) = store.phase { return message }
        return session.store?.discoveryMessage
    }
}

private struct OnboardingGuide: View {
    let session: DALIApplicationSession
    @State private var state = OnboardingState(preview: .welcome)
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingHost(session: session, state: state) { dismissWindow(id: "setup") }
    }
}

private struct SetupMenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Continue DALI setup") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit DALI") { NSApp.terminate(nil) }
    }
}

private struct MenuBarPanel: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(store.roomChrome.menuLabel)
                .lineLimit(2)
        }
        Divider()
        Button(verb) { store.bigButtonTapped() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(isError)
        if isError {
            Button("Try again") { store.retryAfterError() }
        }
        Button("Open DALI") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",", modifiers: [.command])
        Divider()
        Button("Quit DALI") { NSApp.terminate(nil) }
    }

    private var isError: Bool {
        if case .error = store.phase { return true }
        return false
    }

    /// The same verb the big button shows, so the menu and the panel never
    /// disagree about what one press does.
    private var verb: String {
        switch store.phase {
        case .starting: return "Stop"
        case .error: return "Fix the issue in DALI"
        case .streaming:
            if store.mode == .player { return store.isPlaying ? "Pause" : "Resume" }
            return "Stop"
        case .idle:
            return store.mode == .player ? "Play to Room" : "Play everywhere"
        }
    }
}

/// Dark titlebar blending + keep the window floating-feel clean.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)   // content flows under the titlebar
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.isMovableByWindowBackground = false
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Clicking the Dock icon with the window closed reopens it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // The main panel, specifically. "First key-able window" could land
            // on the (closed) Settings window instead, so a Dock click brought
            // up Settings and the room stayed hidden. SwiftUI names the scene's
            // window after its id ("main-AppWindow-1").
            let main = sender.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") }
            if let w = main ?? sender.windows.first(where: { $0.canBecomeKey }) {
                w.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard DALIExecution.engineStarted else { return }
        // The supervisor's SIGTERM teardown is async; guarantee no orphan engine
        // keeps the speakers occupied after we quit.
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/owntone/owntone").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", helper]
        try? task.run()
        task.waitUntilExit()
    }
}
