// DALI — the optional Apple-managed AirPlay sender.
//
// An alternative to DALI's own engine: the captured Mac audio goes to Apple's
// AirPlay stack (an AVSampleBufferAudioRenderer on the system's output context),
// which handles the speaker clock itself. It is steadier for music and about two
// seconds behind, so it is not for video. Speakers are chosen in Apple's own
// picker, because macOS does not let an app select AirPlay speakers by code.
//
// One sender at a time: while this plays, DALI's engine must be stopped. Volume
// uses DALI's own rules (Mac volume keys, Front/Back sliders, limit, leveling
// curve, quiet first step) through `DALIStore.roomVolumePlan`.

import SwiftUI
import AVFoundation
import Observation

@MainActor
@Observable
final class AppleSender {
    static let shared = AppleSender()

    struct Problem: Equatable {
        enum Remedy: Equatable { case openAudioPrivacy }
        var message: String
        var remedy: Remedy?
    }

    enum Phase: Equatable { case idle, choosing, starting, playing, failed(Problem) }

    struct SpeakerLevel: Identifiable, Equatable {
        let name: String
        let value: Int
        var id: String { name }
    }

    /// Whether the main Play button uses this sender instead of DALI's engine.
    var isSelected: Bool {
        didSet {
            defaults.set(isSelected, forKey: Key.selected)
            guard isSelected != oldValue else { return }
            let selected = isSelected
            // One switch at a time, in order: a quick toggle back and forth must not
            // leave the engine stopped while DALI is selected.
            let previous = switchTask
            switchTask = Task { @MainActor in
                await previous?.value
                // Either sender may be playing: stop it and hand over, so the switch works any time.
                if !selected {
                    if self.isBusy { self.stop() }
                    // Apple's AirPlay holds the clock ports while speakers are connected.
                    // Let the speakers go before DALI's engine needs the ports back, but only
                    // if this sender ever used the route (never drop a route someone else set).
                    if self.touchedRoute, let id = self.contextID ?? AppleRouteAPI.sharedContextID() {
                        AppleRouteAPI.clearSpeakers(contextID: id)
                        self.touchedRoute = false
                        self.speakers = []
                        try? await Task.sleep(for: .seconds(2.5))
                    }
                }
                guard self.isSelected == selected,
                      let store = DALIApplicationSession.shared.store else { return }
                if selected { await store.releaseEngineForAppleSender() } else { await store.reclaimEngine() }
            }
        }
    }

    /// The Apple sender is a beta: it shows in Settings > Sound as a choice next to DALI.
    /// `defaults write com.fortun8te.dali dali.hideAppleBeta -bool true` hides it again.
    nonisolated static var betaVisible: Bool { !UserDefaults.standard.bool(forKey: "dali.hideAppleBeta") }

    /// The saved choice, readable before the sender exists (at launch).
    nonisolated static var savedSelection: Bool { betaVisible && UserDefaults.standard.bool(forKey: Key.selected) }

    private(set) var phase: Phase = .idle
    private(set) var contextID: String?
    /// Speakers currently in the AirPlay route.
    private(set) var speakers: [String] = []
    /// Speakers that were playing last time, shown as a hint when none are chosen.
    private(set) var remembered: [String]
    /// Per-speaker volume DALI's rules give right now (0...100).
    private(set) var volumes: [SpeakerLevel] = []
    /// Mac audio level reaching the sender, 0...1.
    private(set) var level: Float = 0
    /// Consecutive quarter-seconds with no sound from the Mac.
    private var quietTicks = 0
    /// Nothing has been playing on the Mac for a few seconds.
    var isQuiet: Bool { phase == .playing && quietTicks >= 12 }
    private(set) var stats = AppleRouteSender.Stats()
    /// Set when the AirPlay button should open itself; the view clears it.
    var pickerPending = false
    /// Nothing has connected for a while: most often DALI isn't allowed on the
    /// local network, which also stops speakers from joining.
    private(set) var showNetworkHint = false
    /// DALI may press the AirPlay list for the person (Accessibility). Refreshed while choosing.
    private(set) var canAutoSelect = PickerAutomation.isTrusted
    /// The capture is waiting on macOS: its "record system audio" prompt may be open.
    private(set) var showPermissionHint = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let sender = AppleRouteSender()
    @ObservationIgnored private var tap: ProcessTap?
    @ObservationIgnored private let gain = SharedFloat(1)
    @ObservationIgnored private let meter = LevelMeter()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var showWindow: (() -> Void)?
    @ObservationIgnored private var lastApplied: [String: Int] = [:]
    @ObservationIgnored private var callbacksSeen = 0
    @ObservationIgnored private var healthTicks = 0
    @ObservationIgnored private var lastPressed: [String: Date] = [:]
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private var touchedRoute = false

    fileprivate enum Key {
        static let selected = "dali.sender.apple"
        static let last = "dali.apple.lastSpeakers"
        static let askedAccessibility = "dali.apple.askedAccessibility"
    }

    private init() {
        isSelected = Self.betaVisible && defaults.bool(forKey: Key.selected)
        remembered = defaults.stringArray(forKey: Key.last) ?? []
    }

    // MARK: presentation

    var isUnsupported: Bool { !AppleRouteAPI.missing().isEmpty }

    var isBusy: Bool {
        switch phase {
        case .choosing, .starting, .playing: return true
        case .idle, .failed: return false
        }
    }

    /// Same verbs as DALI's own button, so switching sender never changes the panel.
    var primaryVerb: String {
        switch phase {
        case .idle, .failed: return "Play everywhere"
        case .choosing: return speakers.isEmpty ? "Cancel" : "Start now"
        case .starting: return "Connecting…"
        case .playing: return "Stop"
        }
    }

    var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .choosing: return "Choose speakers"
        case .starting: return "Connecting"
        case .playing: return "Live"
        case .failed: return "Needs you"
        }
    }

    var statusTone: StatusDot.Tone {
        switch phase {
        case .idle: return .idle
        case .choosing, .starting, .playing: return .live
        case .failed: return .trouble
        }
    }

    var statusPulsing: Bool { phase == .choosing || phase == .starting }

    var problem: Problem? {
        if case .failed(let problem) = phase { return problem }
        return nil
    }

    /// One line for the speakers row.
    var speakersSummary: String {
        if !speakers.isEmpty { return speakers.joined(separator: ", ") }
        if !remembered.isEmpty { return "Last time: " + remembered.joined(separator: ", ") }
        return "None chosen yet"
    }

    // MARK: actions

    func prepare() {
        if contextID == nil { contextID = AppleRouteAPI.sharedContextID() }
        refreshSpeakers()
    }

    /// The main Play button, when this sender is selected.
    func primaryTapped(showWindow: (() -> Void)? = nil) {
        switch phase {
        case .playing: stop()
        case .choosing: if speakers.isEmpty { stop() } else { begin() }
        case .starting: break
        case .idle, .failed: start(showWindow: showWindow)
        }
    }

    func start(showWindow: (() -> Void)? = nil) {
        guard Self.betaVisible, !isBusy else { return }
        self.showWindow = showWindow
        guard !isUnsupported else {
            return fail("This version of macOS can't send to AirPlay this way.")
        }
        if DALIApplicationSession.shared.store?.phase.isOn == true {
            return fail("DALI's own engine is playing. Stop it, then play again.")
        }
        prepare()
        guard contextID != nil else { return fail("Couldn't find the AirPlay route.") }
        // The engine holds the AirPlay clock ports; it must be stopped before
        // the speakers can connect. Usually already done when the sender was selected.
        phase = .starting
        task = Task { [weak self] in
            await DALIApplicationSession.shared.store?.releaseEngineForAppleSender()
            guard let self, self.phase == .starting else { return }
            await self.connectSpeakers()
        }
    }

    func stop() {
        task?.cancel(); task = nil
        if let tap {
            self.tap = nil
            DispatchQueue.global(qos: .userInitiated).async { tap.stop() }
        }
        sender.stop()
        level = 0; volumes = []; lastApplied = [:]
        showNetworkHint = false
        showPermissionHint = false
        if case .failed = phase { return }
        phase = .idle
    }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func allowAutoSelect() {
        PickerAutomation.requestTrust()
        PickerAutomation.openAccessibilitySettings()
    }

    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    func showLog() { NSWorkspace.shared.open(AppleSenderLog.url) }

    func refreshSpeakers() {
        guard let contextID else { return }
        let now = AppleRouteAPI.speakerNames(contextID: contextID)
        if now != speakers { AppleSenderLog.write("route: \(now)") }
        speakers = now
    }

    // MARK: connecting

    /// Already in the route: go. Otherwise open Apple's picker, which DALI then
    /// ticks for the person.
    private func connectSpeakers() async {
        refreshSpeakers()
        let wanted = wantedSpeakers
        if !speakers.isEmpty, Set(wanted).isSubset(of: Set(speakers)) { return begin() }
        choose()
    }

    // MARK: choosing

    /// Speakers to wait for: the ones used last time, else those switched on in DALI.
    private var wantedSpeakers: [String] {
        if !remembered.isEmpty { return remembered }
        return DALIApplicationSession.shared.store?.speakers.filter(\.enabled).map(\.name) ?? []
    }

    /// No speakers yet: open Apple's picker and carry on by itself once the person
    /// has ticked them.
    private func choose() {
        phase = .choosing
        touchedRoute = true
        showNetworkHint = false
        lastPressed = [:]
        // First time: ask macOS to let DALI tick the list itself.
        if !PickerAutomation.isTrusted, !defaults.bool(forKey: Key.askedAccessibility) {
            defaults.set(true, forKey: Key.askedAccessibility)
            PickerAutomation.requestTrust()
        }
        showWindow?()
        pickerPending = true
        task = Task { [weak self] in
            var last: [String] = []
            let began = Date()
            var changedAt = Date()
            let deadline = Date().addingTimeInterval(120)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.phase == .choosing else { return }
                self.refreshSpeakers()
                self.autoSelect()
                self.showNetworkHint = self.speakers.isEmpty && Date().timeIntervalSince(began) > 15
                if self.speakers != last { last = self.speakers; changedAt = Date() }
                if SpeakerSelectionPolicy.isFinished(remembered: self.wantedSpeakers, current: self.speakers,
                                                     stableFor: Date().timeIntervalSince(changedAt)) {
                    self.begin()
                    return
                }
            }
            guard let self, self.phase == .choosing else { return }
            self.phase = .idle
        }
    }

    /// With Accessibility allowed, tick the wanted speakers in Apple's list. A box is
    /// pressed again only after a while, so a speaker that is still connecting is
    /// never switched off by a second press.
    private func autoSelect() {
        canAutoSelect = PickerAutomation.isTrusted
        guard canAutoSelect, PickerAutomation.isListOpen() else { return }
        let missing = wantedSpeakers.filter { name in
            !speakers.contains(name) && Date().timeIntervalSince(lastPressed[name] ?? .distantPast) > 12
        }
        guard !missing.isEmpty else { return }
        for name in PickerAutomation.tick(names: missing) {
            lastPressed[name] = Date()
            AppleSenderLog.write("ticked \(name)")
        }
    }

    private func begin() {
        guard let contextID else { return }
        if PickerAutomation.isTrusted { PickerAutomation.closeList() }
        phase = .starting
        task = Task { [weak self] in await self?.run(contextID: contextID) }
    }

    // MARK: starting

    private func run(contextID: String) async {
        touchedRoute = true
        AppleSenderLog.write("start: route=\(speakers)")
        do {
            try sender.start(contextID: contextID)
        } catch AppleRouteSender.Failure.noSpeakersInContext {
            return fail("No speakers are chosen yet.")
        } catch {
            return fail("Couldn't connect to the speakers.")
        }
        // The capture must leave this app out, and the app only becomes an audio
        // client once it has fed the renderer: feed a moment of silence, then wait.
        if let silence = Self.silence() { try? sender.enqueue(silence) }
        var waited = 0.0
        while !ProcessTap.ownProcessObjectExists(), waited < 3, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }
        guard phase == .starting else { return }

        let tap = ProcessTap()
        tap.excludeOwnProcess = true
        let sender = self.sender, gain = self.gain, meter = self.meter
        meter.reset()
        tap.onBuffer = { buffer in
            meter.note(PCMLevel.peak(of: buffer))
            PCMLevel.scale(buffer, by: gain.value)
            try? sender.enqueue(buffer)
        }
        tap.onInvalidated = { [weak self] reason in
            Task { @MainActor in self?.fail("Mac audio capture stopped (\(reason)). Play again.") }
        }
        let hint = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.phase == .starting else { return }
            self.showPermissionHint = true
        }
        let capture = await startCapture(tap)
        hint.cancel()
        showPermissionHint = false
        if let problem = capture {
            DispatchQueue.global(qos: .userInitiated).async { tap.stop() }
            return fail(problem.message, remedy: problem.remedy)
        }
        guard phase == .starting else {
            DispatchQueue.global(qos: .userInitiated).async { tap.stop() }
            return
        }
        self.tap = tap
        remembered = speakers
        defaults.set(speakers, forKey: Key.last)
        callbacksSeen = 0
        phase = .playing
        AppleSenderLog.write("playing")
        monitor()
    }

    /// Starts the capture off the main thread, with a deadline: without System Audio
    /// Recording permission the HAL call blocks instead of failing.
    private func startCapture(_ tap: ProcessTap) async -> Problem? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Problem?, Never>) in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                var problem: Problem?
                do {
                    // The Mac is muted only now that the route is proven and the capture is ours.
                    try tap.start(muteLocal: true, source: .system)
                } catch {
                    problem = Problem(message: "Couldn't capture the Mac's audio. \(error)", remedy: .openAudioPrivacy)
                }
                if once.fire() { continuation.resume(returning: problem) }
            }
            // Long enough for a person to read and answer macOS's permission prompt.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                if once.fire() {
                    continuation.resume(returning: Problem(
                        message: "DALI can't record the Mac's audio yet. Allow it under System Audio Recording, then play again.",
                        remedy: .openAudioPrivacy))
                }
            }
        }
    }

    // MARK: playing

    private func monitor() {
        task = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.phase == .playing else { return }
                ticks += 1
                self.applyVolumes()
                let sample = self.meter.take()
                self.level = max(sample.peak, self.level * 0.85)
                self.callbacksSeen += sample.callbacks
                if sample.peak > 0.0005 { self.quietTicks = 0 } else { self.quietTicks += 1 }
                if ticks % 4 == 0 { self.checkHealth() }
            }
        }
    }

    private func checkHealth() {
        stats = sender.snapshot
        healthTicks += 1
        if healthTicks % 3 == 0 {
            AppleSenderLog.write("health \(stats) level=\(String(format: "%.3f", level)) callbacks=\(callbacksSeen) route=\(speakers) \(sender.diagnostics)")
        }
        refreshSpeakers()
        if speakers.isEmpty {
            return fail("The speakers were switched off. Choose them again to keep playing.")
        }
    }

    /// DALI's volume plan, applied to the Apple route: the shared quiet-floor gain
    /// on the audio and each speaker's own volume.
    private func applyVolumes() {
        guard let store = DALIApplicationSession.shared.store else { return }
        let plan = store.roomVolumePlan
        gain.value = Float(plan.pcmGain)
        var byName: [String: Int] = [:]
        for speaker in store.speakers where speaker.enabled && speakers.contains(speaker.name) {
            if let value = plan.hardware[speaker.id] { byName[speaker.name] = value }
        }
        let shown = byName.sorted { $0.key < $1.key }.map { SpeakerLevel(name: $0.key, value: $0.value) }
        if shown != volumes { volumes = shown }
        guard let contextID, !byName.isEmpty, byName != lastApplied else { return }
        lastApplied = byName
        let applied = AppleRouteAPI.setSpeakerVolumes(contextID: contextID,
                                                      volumes: byName.mapValues { Float($0) / 100 })
        AppleSenderLog.write("volumes \(byName) quietFloorGain=\(String(format: "%.2f", plan.pcmGain)) applied=\(applied)")
    }

    private func fail(_ message: String, remedy: Problem.Remedy? = nil) {
        AppleSenderLog.write("problem: \(message)")
        stop()
        phase = .failed(Problem(message: message, remedy: remedy))
        showWindow?()
    }

    private static func silence() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960) else { return nil }
        buffer.frameLength = 960
        return buffer
    }
}

// MARK: - small thread-safe helpers

private final class SharedFloat: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Float
    init(_ value: Float) { stored = value }
    var value: Float {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var callbacks = 0
    func reset() { lock.withLock { peak = 0; callbacks = 0 } }
    func note(_ value: Float) { lock.withLock { peak = max(peak, value); callbacks += 1 } }
    func take() -> (peak: Float, callbacks: Int) {
        lock.withLock { defer { peak = 0; callbacks = 0 }; return (peak, callbacks) }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// A short plain-text trace for support, next to DALI's other logs.
enum AppleSenderLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DALI/apple-sender.log")
    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.withLock {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > 200_000 { try? FileManager.default.removeItem(at: url) }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
