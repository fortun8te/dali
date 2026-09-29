// DALI — AppKit window plumbing: the opaque hidden-titlebar window, and a
// visibility signal so animation stops when nobody can see it.

import SwiftUI
import AppKit

/// Opaque ink window with a transparent titlebar over full-size content.
/// Native corners and shadow come from the system; nothing is drawn by hand.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfiguratorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Configures the window the moment the view lands in one. The old
    /// `DispatchQueue.main.async { view.window }` ran before SwiftUI had
    /// necessarily attached the view, found no window, and silently left the
    /// titlebar unconfigured — and never retried.
    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // One turn later, as before: SwiftUI finishes its own window setup
            // in the same pass and this must land after it.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.configure() }
            }
        }

        private func configure() {
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.titlebarSeparatorStyle = .none
            w.styleMask.insert(.fullSizeContentView)
            w.isOpaque = true
            w.backgroundColor = .daliInk
            w.hasShadow = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            // Sliders are DragGestures; the header row carries the window drag.
            w.isMovableByWindowBackground = false
        }
    }
}

/// Reports whether the hosting window is actually on screen: not minimised,
/// not fully covered, app not hidden. Drives `paused` on every TimelineView.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return v
    }
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { onChange?(false); return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
            }
            report()
        }

        private func report() {
            guard let window else { onChange?(false); return }
            onChange?(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension View {
    /// `.task(id:)` that only runs while the hosting window is on screen.
    /// A closed or covered window keeps its SwiftUI tree, so a plain `.task`
    /// polling loop went on hitting the engine every few seconds for a window
    /// nobody could see. It starts again by itself when the window returns.
    func visibleTask<ID: Equatable>(id: ID, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(VisibleTask(id: id, action: action))
    }
}

private struct VisibleTask<ID: Equatable>: ViewModifier {
    struct Key: Equatable { let id: ID; let visible: Bool }
    let id: ID
    let action: @MainActor @Sendable () async -> Void
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityReader(isVisible: $visible))
            .task(id: Key(id: id, visible: visible)) {
                if visible { await action() }
            }
    }
}
