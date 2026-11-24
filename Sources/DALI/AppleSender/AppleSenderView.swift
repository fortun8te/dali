// DALI — the Apple AirPlay sender window: where the speakers are chosen and the
// state of the stream is shown. Playing starts from here or from DALI's own Play
// button once Apple AirPlay is selected in Settings > Sound.

import SwiftUI
import AVKit

struct AppleSenderView: View {
    @State private var sender = AppleSender.shared
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            if sender.isUnsupported {
                Text("This version of macOS can't send to AirPlay this way. DALI's own engine still works.")
                    .font(.body13).foregroundStyle(Color.amber)
            } else {
                SettingsGroup {
                    speakersRow
                    volumeRow
                }
                statusBlock
                Button(sender.primaryVerb) { sender.primaryTapped() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sender.phase == .starting)
                    .keyboardShortcut(.defaultAction)
                details
            }
        }
        .padding(Space.l)
        .frame(width: 380)
        .background(Color.ink.ignoresSafeArea())
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .onAppear { sender.prepare() }
        .task {
            // Keep the speaker list honest while the window is open.
            while !Task.isCancelled {
                sender.refreshSpeakers()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: pieces

    private var header: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "airplayaudio")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.paper)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple AirPlay").font(.emphasis).foregroundStyle(Color.paper)
                Text("Steadier for music. About 2 seconds behind, so not for video.")
                    .font(.caption).foregroundStyle(Color.paper62)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var speakersRow: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speakers").font(.body13).foregroundStyle(Color.paper)
                Text(sender.speakersSummary)
                    .font(.caption).foregroundStyle(Color.paper38)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s)
            RoutePicker(contextID: sender.contextID, pending: sender.pickerPending) {
                sender.pickerPending = false
            }
            .frame(width: 36, height: 28)
            .help("Choose speakers")
            .accessibilityLabel("Choose AirPlay speakers")
        }
    }

    private var volumeRow: some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Volume").font(.body13).foregroundStyle(Color.paper)
                Text("Follows your Mac's volume keys and the Front and Back sliders in DALI.")
                    .font(.caption).foregroundStyle(Color.paper38)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s)
            if sender.phase == .playing, !sender.volumes.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(sender.volumes) { speaker in
                        Text("\(speaker.name)  \(speaker.value)")
                            .font(.readout).foregroundStyle(Color.paper62)
                    }
                }
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: 6) {
                StatusDot(tone: sender.statusTone, pulsing: sender.statusPulsing)
                Text(sender.statusText).font(.caption).foregroundStyle(Color.paper62)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(sender.statusText)")

            if sender.phase == .choosing {
                Text(sender.canAutoSelect
                     ? "Connecting your speakers…"
                     : "Tick your speakers in the AirPlay list. DALI starts by itself when you're done.")
                    .font(.caption).foregroundStyle(Color.paper62)
                    .fixedSize(horizontal: false, vertical: true)
                if !sender.canAutoSelect {
                    Text("Allow DALI under Accessibility and it will pick your speakers for you.")
                        .font(.caption).foregroundStyle(Color.paper38)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Allow automatic speakers") { sender.allowAutoSelect() }
                        .buttonStyle(SecondaryButtonStyle(accent: true))
                }
                if sender.showNetworkHint {
                    Text("Nothing connecting? Make sure DALI is allowed to use the local network.")
                        .font(.caption).foregroundStyle(Color.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Local Network Settings") { sender.openLocalNetworkSettings() }
                        .buttonStyle(SecondaryButtonStyle(accent: true))
                }
            }
            if sender.phase == .starting, sender.showPermissionHint {
                Text("macOS may be asking to let DALI record system audio. Click Allow in its prompt.")
                    .font(.caption).foregroundStyle(Color.amber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { sender.openAudioPrivacySettings() }
                    .buttonStyle(SecondaryButtonStyle(accent: true))
            }
            if sender.phase == .playing {
                LevelBar(level: sender.level)
                    .accessibilityLabel("Mac audio level")
                    .accessibilityValue("\(Int((sender.level.isFinite ? min(max(sender.level, 0), 1) : 0) * 100)) percent")
                if sender.isQuiet {
                    Text("Waiting for sound. Play something on this Mac.")
                        .font(.caption).foregroundStyle(Color.paper38)
                }
            }
            if let problem = sender.problem {
                Text(problem.message)
                    .font(.caption).foregroundStyle(Color.amber)
                    .fixedSize(horizontal: false, vertical: true)
                if problem.remedy == .openAudioPrivacy {
                    Button("Open System Settings") { sender.openAudioPrivacySettings() }
                        .buttonStyle(SecondaryButtonStyle(accent: true))
                }
            }
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Sent \(sender.stats.enqueued) · skipped \(sender.stats.droppedNotReady) · errors \(sender.stats.rendererFailures)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Color.paper38)
                Button("Show log") { sender.showLog() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, Space.s)
        } label: {
            Text("Details").font(.caption).foregroundStyle(Color.paper38)
        }
    }
}

/// A thin level meter for the Mac audio reaching the sender.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.accentBlue.opacity(0.75))
                    .frame(width: max(3, geo.size.width * CGFloat(min(max(level, 0), 1))))
                    .animation(.linear(duration: 0.12), value: level)
            }
        }
        .frame(height: 4)
    }
}

/// Apple's AirPlay picker, bound to the sender's output context. When `pending`
/// is set it opens itself, so playing with no speakers chosen needs no hunting.
private struct RoutePicker: NSViewRepresentable {
    let contextID: String?
    let pending: Bool
    let onPresented: () -> Void

    final class Coordinator { var scheduled = false }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        if let contextID {
            let selector = NSSelectorFromString("setOutputContextID:")
            if picker.responds(to: selector) { _ = picker.perform(selector, with: contextID) }
        }
        presentIfPending(picker, context.coordinator)
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {
        presentIfPending(picker, context.coordinator)
    }

    private func presentIfPending(_ picker: AVRoutePickerView, _ coordinator: Coordinator) {
        guard pending, !coordinator.scheduled else { return }
        coordinator.scheduled = true
        let done = onPresented
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak picker] in
            coordinator.scheduled = false
            done()
            NSApp.activate(ignoringOtherApps: true)
            picker?.firstButton()?.performClick(nil)
        }
    }
}

private extension NSView {
    func firstButton() -> NSButton? {
        if let button = self as? NSButton { return button }
        for sub in subviews { if let button = sub.firstButton() { return button } }
        return nil
    }
}
