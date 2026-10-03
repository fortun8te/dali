// DALI — UI facade over room session, volume and timing owners.
// State machine: idle -> starting -> streaming -> idle, or error.
// Note: phase `.streaming` means the session/pipe is up — not that every
// speaker is audibly healthy. UI chrome must read speaker `health` for that.

import Foundation
import SwiftUI
import Observation
import Network

enum StreamPhase: Equatable {
    case idle
    case starting
    case streaming
    case error(String)

    var isOn: Bool { self == .starting || self == .streaming }
}

struct RoomSpeaker: Identifiable, Equatable {
    enum Kind: Equatable { case front, back, extra }
    enum Health: Equatable { case off, connecting, live, trouble }

    let id: String          // OwnTone output id (session-scoped)
    let name: String
    let type: String        // "AirPlay 2" etc
    var kind: Kind
    var enabled: Bool       // part of the stream set
    var relVolume: Double   // 0...100, the speaker's own slider
    var gain: Double = 1.0  // calibration multiplier (0.25...4): balances an
                            // amp+passive front against a self-amped Sonos
    var offsetMs: Int = 0   // sync trim (±ms, positive = plays later); engine-persisted
    var health: Health
    var available: Bool = true
}

@MainActor
@Observable
final class DALIStore {
    private let preferences: UserDefaults
    private let backendEnabled: Bool
    private let injectedVolumeWrite: RoomVolumeCoordinator.Write?
    // MARK: published state
    var phase: StreamPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            // The beacon was ONLY ever updated from recordFlight(), which runs
            // exclusively while streaming — so the moment the stream stopped it
            // froze on its last value and kept telling the browser extension
            // `streaming:true, delayMs:<stale>` forever. The extension went on
            // holding video back by a delay that no longer existed. Any phase
            // that is not live must say so immediately.
            if phase != .streaming {
                if backendEnabled { syncBeacon.publish(streaming: false, delaySeconds: nil) }
                cancelVolumePush()
            }
            if !phase.isOn {
                sessionMembership.reset()
                resetOffsetCache()
                if backendEnabled { enqueueSessionTeardown() }
            }
            // What-is-playing only matters while the room can hear it.
            if backendEnabled { NowPlayingMonitor.shared.setActive(phase == .streaming) }
        }
    }
    var speakers: [RoomSpeaker] = []
    /// Version of the Chrome extension currently checking in with the sync
    /// beacon (1.2+ reports itself), or nil when none has checked in for 70 s. For the UI:
    /// nil while streaming video = "extension not running / needs reload".
    private(set) var browserExtensionVersion: String?

    var extrasExpanded = false

    /// What goes to the room: all system audio, a single app, or Spotify Connect.
    enum AudioSource: Equatable {
        case system
        case app(pid: pid_t, name: String)
        case spotify  // Spotify Connect receiver — appears as native device in Spotify app

        var label: String {
            switch self {
            case .system: return "All audio"
            case .app(_, let name): return name
            case .spotify: return "Spotify Connect"
            }
        }
        var tapSource: ProcessTap.Source {
            switch self {
            case .system: return .system
            case .app(let pid, _): return .process(pid)
            case .spotify:
                // Prefer tapping the Spotify desktop app if running; fallback to system tap.
                // When librespot is available, audio bypasses the tap entirely (pipe direct).
                if let spotifyApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }) {
                    return .process(spotifyApp.processIdentifier)
                }
                return .system
            }
        }
    }
    var source: AudioSource = .system {
        didSet {
            // Re-assigning the same source (a view re-selecting its current row,
            // the health loop's fallback) must not rebuild the tap — that splices
            // a capture gap into live audio — nor churn the Spotify helper.
            guard oldValue != source else { return }
            switch source {
            case .system: preferences.set("", forKey: "dali.sourceApp")
            case .app(_, let name): preferences.set(name, forKey: "dali.sourceApp")
            case .spotify: preferences.set("Spotify", forKey: "dali.sourceApp")
            }
            scheduleVolumePush()
            guard backendEnabled else { return }
            // A source owns the pipe for its whole session. Invalidate the
            // old writer immediately; replacement startup drains its teardown
            // before admitting either a tap or a Spotify child.
            if phase.isOn, !playerMode {
                stopStream()
                startStream(reason: "source changed")
            }
        }
    }

    /// Re-resolve a remembered app source by name (pids do not survive relaunch).
    func resolveSavedSource() {
        guard case .system = source,
              let saved = preferences.string(forKey: "dali.sourceApp"),
              !saved.isEmpty,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.activationPolicy == .regular && $0.localizedName == saved
              })
        else { return }
        source = .app(pid: app.processIdentifier, name: saved)
    }

    /// The Mac's output volume 0...1 controls a common system-capture PCM gain.
    /// Receiver calibration stays fixed across ordinary nonzero master changes;
    /// zero additionally mutes buffered audio through the receiver controls.
    var systemVolume: Double = 0.5 { didSet { scheduleVolumePush() } }

    /// Music level 0...1 for the room visualization.
    var audioLevel: Double = 0
    var bassLevel: Double = 0
    var trebleLevel: Double = 0
    /// The capture and health loops continue when the window is covered; only
    /// visual state publication pauses with the canvas.
    var roomCanvasVisible = true
    /// Beats heard IN THE ROOM so far. The canvas pulses when it changes.
    var beatCount: Int = 0
    /// Capture onset shifted by the same delay as speaker playback.
    private(set) var beatPlayedAt: Date?

    /// The shared nominal delay for browser video and the room animation.
    /// The engine's relative byte/progress counters cannot measure absolute
    /// capture-to-speaker latency: their first arbitrary polling sample becomes
    /// zero. Feeding that moving estimate to Chrome repeatedly rebuilt its
    /// delay pipeline. Use the engine's scheduling contract and saved ear trim.
    private(set) var roomDelaySec: Double = 0.9

    /// THE EAR'S CORRECTION, in milliseconds.
    ///
    /// `roomDelaySec` is a scheduling estimate, and the estimate rests
    /// on one modelling assumption it cannot check by itself: how much of their
    /// own output latency the receivers compensate before they play. That is
    /// worth a couple of hundred milliseconds either way, and no amount of log
    /// reading settles it — but a person watching a face talk settles it in
    /// five seconds. So this is the number they drag, added on top.
    ///
    /// Negative shows the picture sooner. It moves the room canvas by exactly
    /// the same amount, because both are answers to the same question.
    var delayTrimMs: Double = 0 {
        didSet {
            let clamped = min(max(delayTrimMs, -400), 400)
            // Assigning inside our own didSet does not re-fire it, so do not
            // return here: the save and the beacon push below must still run.
            if clamped != delayTrimMs { delayTrimMs = clamped }
            guard clamped != oldValue else { return }
            preferences.set(clamped, forKey: "dali.delayTrimMs")
            // Straight out to the browser, so dragging moves the picture live
            // instead of waiting for the next flight tick.
            applyRoomDelay()
            if backendEnabled { syncBeacon.publish(streaming: phase == .streaming, delaySeconds: roomDelaySec) }
        }
    }

    /// THE ROOM IS BEHIND THE MAC, AND SO IS ITS PICTURE.
    ///
    /// Every speaker deliberately waits `startBuffer + 200 ms` (≈0.9 s) before
    /// playing what the tap just captured — that lead is the whole reason the
    /// browser extension holds video back. The room canvas was reading the tap
    /// DIRECTLY, so it drew each beat a second before the speakers played it:
    /// the light and the sound were never together, which is exactly what
    /// "it doesn't sync with the music" looks like.
    ///
    /// So the levels go through the same delay the audio does. The canvas then
    /// shows what the room is playing at this instant, not what the Mac made a
    /// second ago. Samples retain their capture timestamps so polling and DSP
    /// queue time do not become another hidden delay.
    private var levelDelayLine = RoomLevelTimeline()
    private var levelTask: Task<Void, Never>?

    private var lastStatsLogAt = Date()
    private var lastDropped = 0
    /// Compact machine-readable health every ~30s. The old 3s prose line repeated
    /// almost-identical state ten times per interval, costing disk space and AI
    /// context without adding evidence. Detailed 1s telemetry remains in the
    /// bounded flight recorder; this file is the cheap index an AI should read.
    private func logCaptureStats() {
        // Wall-clock, not a tick count: the level loop slows down while the
        // canvas is hidden, and a tick modulus would stretch 30 s into 90 s.
        let now = Date()
        guard now.timeIntervalSince(lastStatsLogAt) >= 30 else { return }
        lastStatsLogAt = now
        let st = capture.stats
        let dropDelta = st.dropped - lastDropped
        lastDropped = st.dropped
        let spk = speakers.filter { $0.kind != .extra || $0.enabled }.map {
            let state: String
            switch $0.health {
            case .off: state = "off"; case .connecting: state = "connecting"
            case .live: state = "live"; case .trouble: state = "trouble"
            }
            let role = $0.kind == .front ? "front" : $0.kind == .back ? "back" : "extra"
            return "\(role):state=\(state),vol=\($0.enabled ? "\(effectiveVolume($0))" : "off"),name=\($0.name)"
        }.joined(separator: "|")
        // Never report anomalies=none while an enabled speaker is not live —
        // that was the AI-health false calm during speakerOFF / reconnect.
        var anomaly = lastFlightFlags
        let weak = speakers.filter { $0.enabled && $0.health != .live }
        if !weak.isEmpty {
            let tag = weak.contains(where: { $0.health == .trouble }) ? "speakerDEAD" : "speakerWEAK"
            anomaly = anomaly.isEmpty ? tag : "\(anomaly) \(tag)"
        }
        let fields: [String: Any] = [
            "phase": phaseLabel,
            "source": source.label,
            "speakers": spk,
            "chrome": roomChrome.pillLabel.isEmpty ? phaseLabel : roomChrome.pillLabel.lowercased(),
            "mac_volume": systemVolume.isFinite ? Int(systemVolume * 100) : 0,
            "backlog_ms": Int(Double(st.pending ?? 0) / 176.4),
            "rate_ppm": Int(-refill.eps * 1_000_000),
            "rate_hold": driftFreeze.isEmpty ? "none" : driftFreeze,
            "dropped_30s": dropDelta,
            "clock_anchored": capture.isClockAnchored,
            "anomalies": anomaly.isEmpty ? "none" : anomaly,
        ]
        aiHealth(fields)
        if dropDelta > 0 {
            dlog("capture dropping: +\(dropDelta) frames/30s")
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: return "idle"; case .starting: return "starting"
        case .streaming: return "streaming"; case .error: return "error"
        }
    }

    /// Plain-language room chrome. Never treat session STREAMING as audible health.
    enum RoomChrome: Equatable {
        case idle
        case starting
        case live
        case catchingUp
        case speakerOut
        case error(String)

        var pillLabel: String {
            switch self {
            case .live: return "LIVE"
            case .catchingUp: return "CATCHING UP"
            case .speakerOut: return "SPEAKER OUT"
            case .error: return "NEEDS YOU"
            case .idle, .starting: return ""
            }
        }

        var menuLabel: String {
            switch self {
            case .live: return "Playing in the room"
            case .catchingUp: return "Getting a speaker back…"
            case .speakerOut: return "A speaker dropped out"
            case .starting: return "Connecting…"
            case .error(let m): return m
            case .idle: return "Idle"
            }
        }

        var isBreathing: Bool { self == .live }
        var isAlert: Bool {
            switch self {
            case .speakerOut, .error: return true
            default: return false
            }
        }
    }

    // Cached PTP health — updated after EngineSupervisor.start() (actor hop).
    // Reading supervisor.ptpAvailable directly from MainActor would require await
    // and roomChrome is not async. Cache it.
    private var ptpDegraded = false

    var roomChrome: RoomChrome {
        switch phase {
        case .idle: return .idle
        case .starting: return .starting
        case .error(let m): return .error(m)
        case .streaming:
            // Surface PTP degradation — NTP-only means front/back will drift apart.
            if ptpDegraded, speakers.filter(\.enabled).count > 1 {
                return .error("PTP unavailable — sync degraded")
            }
            let enabled = speakers.filter(\.enabled)
            if enabled.isEmpty { return .error("Choose a speaker in Room settings") }
            if enabled.contains(where: { !$0.available }) { return .speakerOut }
            if enabled.contains(where: { $0.health == .trouble }) { return .speakerOut }
            if enabled.contains(where: { $0.health != .live }) { return .catchingUp }
            return .live
        }
    }

    // MARK: flight recorder
    // Writes a detailed line every second to dali-flight.log so a glitch can be
    // fully diagnosed after the fact: production vs consumption rate, backlog,
    // drops, backpressure, capture gaps, sample rate, and the live AirPlay state.
    private var flightTask: Task<Void, Never>?
    private var lastFlight: CaptureController.Flight?
    private var lastFlightFlags = ""
    private var aiSessionID = String(UUID().uuidString.prefix(8)).lowercased()
    private var timingController = RoomTimingController()
    private var refill: RefillController { timingController.refill }
    private var driftFreeze: String { timingController.hold }
    private var flightApiBackoffUntil = Date.distantPast

    private nonisolated static let flightLogURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DALI/dali-flight.log")

    // One serial writer for every app-owned log. The old implementation opened
    // and seeked the same files on arbitrary global-queue threads, so a flight
    // line and an event line could race, reorder, or overwrite each other right
    // when the machine was under load. It also grew forever. Keep one previous
    // generation so a long session cannot fill the disk or bury the incident.
    private nonisolated static let fileLogQueue = DispatchQueue(label: "dali.file-log", qos: .utility)
    /// Open handle + running size per log file, touched only on `fileLogQueue`.
    /// Reopening and stat-ing the file for every line cost more than the line.
    private nonisolated(unsafe) static var logHandles: [String: (handle: FileHandle, size: UInt64)] = [:]
    private nonisolated static func appendLog(_ line: String, to url: URL, maxBytes: UInt64) {
        // The UI harness must never write into the live room's logs.
        if isPreview { return }
        let data = Data(line.utf8)
        fileLogQueue.async {
            let fm = FileManager.default
            let key = url.path
            var entry = logHandles[key]
            if entry == nil {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: key) { fm.createFile(atPath: key, contents: nil) }
                guard let h = try? FileHandle(forWritingTo: url) else { return }
                let size = (try? h.seekToEnd()) ?? 0
                entry = (h, size)
            }
            guard var e = entry else { return }
            if e.size + UInt64(data.count) > maxBytes {
                try? e.handle.close()
                let previous = URL(fileURLWithPath: key + ".1")
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: url, to: previous)
                fm.createFile(atPath: key, contents: nil)
                guard let h = try? FileHandle(forWritingTo: url) else { logHandles[key] = nil; return }
                e = (h, 0)
            }
            do {
                try e.handle.write(contentsOf: data)
                e.size += UInt64(data.count)
                logHandles[key] = e
            } catch {
                try? e.handle.close()
                logHandles[key] = nil
            }
        }
    }

    private nonisolated static func flog(_ s: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(s)\n"
        appendLog(line, to: flightLogURL, maxBytes: 16 * 1024 * 1024)
    }

    private func startFlightRecorder() {
        guard backendEnabled else { return }
        flightTask?.cancel()
        lastFlight = nil; lastFlightFlags = ""
        aiSessionID = String(UUID().uuidString.prefix(8)).lowercased()
        lastStatsLogAt = Date(); lastDropped = capture.stats.dropped
        flightApiBackoffUntil = .distantPast
        resetDriftAnchors()
        let generation = streamGeneration
        aiEvent("stream_start", fields: ["speakers": sessionSpeakerSummary(),
                                        "start_buffer_ms": config.startBufferMs, "source": source.label])
        flightTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.streamIsCurrent(generation) else { return }
                await self.recordFlight()
            }
        }
    }

    private func sessionSpeakerSummary() -> String {
        speakers.filter { $0.enabled }.map { "\($0.name)" }.joined(separator: "+")
    }

    private func recordFlight() async {
        let generation = streamGeneration
        let f = capture.readMetrics()
        let previous = lastFlight
        lastFlight = f
        let busy = resumeInFlight || !speakerRecoveryInFlight.isEmpty
            || pushInFlight || Date() < flightApiBackoffUntil
        let began = ContinuousClock.now
        let ps = busy ? nil : try? await api.playerState()
        let elapsed = began.duration(to: .now).components
        let queryMs = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        guard streamIsCurrent(generation) else { return }
        if !busy, ps == nil { flightApiBackoffUntil = Date().addingTimeInterval(6) }
        let written = f.written + max(0, capture.totalWritten - f.written) / 2
        let sample = RoomTimingController.Sample(
            dt: f.intervalSec, written: written, pending: f.pending,
            produced: f.outBytes + f.silenceBytes, silence: f.silenceBytes,
            dropped: max(0, f.dropped - (previous?.dropped ?? f.dropped)),
            discontinuity: f.tapRebuilds > 0 || f.recoveries > 0 || f.tapOverruns > 0,
            converterChanged: f.convRebuilds > 0, maximumGapMs: f.maxGapMs,
            player: ps?.state, progressMs: ps?.item_progress_ms, queryMs: queryMs,
            controlBusy: busy || Date().timeIntervalSince(lastVolumeWriteAt) < 15)
        let result = timingController.update(sample, target: Double(config.startBufferMs) / 1_000)
        capture.setTargetRatio(result.ratio)
        if let event = result.event {
            aiEvent("refill_transition", fields: ["event": String(describing: event),
                                                  "state": refill.label, "hold": result.hold])
        }
        let flags = [sample.dropped > 0 ? "DROP" : nil,
                     sample.discontinuity ? "CAPTURE_RESET" : nil,
                     f.maxGapMs > 120 ? "CAPTURE_GAP" : nil,
                     !busy && ps == nil ? "APIHANG" : nil,
                     speakers.contains { $0.enabled && $0.health == .trouble } ? "SPEAKER_OUT" : nil]
            .compactMap { $0 }.joined(separator: " ")
        if flags != lastFlightFlags {
            aiEvent(flags.isEmpty ? "anomaly_clear" : "anomaly_start_or_change",
                    level: flags.isEmpty ? "info" : "warn", fields: ["flags": flags])
            lastFlightFlags = flags
        }
        let links = speakers.filter(\.enabled).map {
            "\($0.name)[\($0.health) ref=\(effectiveVolume($0))]"
        }.joined(separator: " ")
        let fill = result.fill.map { String(format: "%.3f", $0) } ?? "unknown"
        Self.flog("v2 fill_estimate=\(fill)s hold=\(result.hold) refill=\(refill.label) ratio=\(result.ratio) pcm=\(captureMasterGain) pending=\(f.pending) dropped=\(f.dropped) maxgap=\(Int(f.maxGapMs))ms api=\(queryMs)ms \(links) \(flags)")
        applyRoomDelay()
        syncBeacon.publish(streaming: true, delaySeconds: roomDelaySec)
    }

    /// One value drives both video and visualization. Telemetry remains useful
    /// to the engine's rate loop, but never moves the visual delay.
    private func applyRoomDelay() {
        roomDelaySec = RoomDelayPolicy.seconds(startBufferMs: config.startBufferMs,
                                              trimMs: delayTrimMs)
    }

    private func startLevelLoop() {
        levelTask?.cancel()
        levelTask = Task {
            var tick = 0
            while !Task.isCancelled && phase == .streaming {
                tick += 1
                let now = Date()
                let r = capture.readLevels()
                if let capturedAt = r.at {
                    levelDelayLine.append(RoomLevelSample(at: capturedAt, level: r.level,
                                                           bass: r.bass, treble: r.treble,
                                                           beats: r.beats, beatAt: r.beatAt))
                }
                // Publish the newest sample the room has actually reached.
                let newest = levelDelayLine.latestDue(at: now, delay: roomDelaySec)
                let visible = roomCanvasVisible
                if let s = newest, visible {
                    // @Observable fires on every assignment, equal value or not,
                    // so an idle room (all zeros) re-rendered the canvas 30x/s.
                    if audioLevel != s.level { audioLevel = s.level }
                    if bassLevel != s.bass { bassLevel = s.bass }
                    if trebleLevel != s.treble { trebleLevel = s.treble }
                    if s.beats != beatCount {
                        beatPlayedAt = s.beatAt?.addingTimeInterval(roomDelaySec)
                        beatCount = s.beats
                    }
                }
                // Cheap, and it is the only thing standing between a browser bug
                // and a room that stays silent while the Mac is playing.
                if !visible || tick.isMultiple(of: 2) { reviewCutCredibility() }
                logCaptureStats()
                // ~30 Hz to match the canvas; nothing is drawn while it is
                // hidden, so 10 Hz is plenty for the cut rail and saves wakeups.
                try? await Task.sleep(nanoseconds: visible ? 33_000_000 : 100_000_000)
            }
            audioLevel = 0
            bassLevel = 0
            trebleLevel = 0
            beatPlayedAt = nil
            levelDelayLine.clear()
        }
    }

    /// Stream generation that currently owns the tap-rebuild lane, if any.
    private var captureRebuildGeneration: Int?

    /// Watchdog rebuilds replace only the tap token captured here. Source
    /// changes use a complete room handoff; a stale watchdog never starts a
    /// new tap after Stop or alongside a direct Spotify pipe writer.
    private func rebuildTapSerialized(generation: Int) async -> Bool? {
        while captureRebuildGeneration == generation {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard phase == .streaming, streamGeneration == generation else { return nil }
        }
        guard phase == .streaming, streamGeneration == generation else { return nil }
        captureRebuildGeneration = generation
        defer { if captureRebuildGeneration == generation { captureRebuildGeneration = nil } }
        let fifo = config.pipePath.path
        let src = source.tapSource
        let cap = capture
        let captureSession = cap.sessionID
        guard cap.isRunning else { return false }
        return await cap.rebuildAsync(fifoPath: fifo, muteLocal: true, source: src,
                                      expectedSession: captureSession)
    }

    /// Recover a tap that starts successfully but produces no IOProc callbacks.
    /// The ordinary source-switch rebuild remains tap-only; this stronger path
    /// is reserved for a confirmed >10s callback outage reported by the health
    /// loop.
    private func rebuildStarvedCapture(expectedGeneration: Int) {
        guard phase == .streaming,
              streamGeneration == expectedGeneration,
              !captureWatchdogInFlight else { return }
        captureWatchdogInFlight = true
        let cap = capture

        Task { @MainActor [weak self] in
            guard let self,
                  let rebuilt = await self.rebuildTapSerialized(generation: expectedGeneration),
                  self.streamGeneration == expectedGeneration,
                  self.phase == .streaming else { return }

            guard rebuilt else {
                await self.failCaptureRecovery(expectedGeneration: expectedGeneration,
                                               reason: "tap rebuild failed")
                return
            }

            // Audio callbacks normally resume immediately after AudioDeviceStart.
            // Wait briefly so a slow HAL transition does not restart a healthy room.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard self.streamGeneration == expectedGeneration,
                  self.phase == .streaming else { return }

            let silenceAfterRebuild = cap.secondsSinceLastBuffer
            guard silenceAfterRebuild > 2 else {
                self.captureWatchdogInFlight = false
                self.captureStallRestartUsed = false
                self.dlog("tap callbacks recovered after rebuild")
                self.aiEvent("capture_recovered", fields: ["path": "tap_rebuild"])
                return
            }

            self.dlog(String(format: "tap still has no callbacks %.0fs after rebuild", silenceAfterRebuild))
            self.aiEvent("capture_rebuild_no_callbacks", level: "error", fields: [
                "seconds": Int(silenceAfterRebuild),
            ])
            if self.captureStallRestartUsed {
                await self.failCaptureRecovery(expectedGeneration: expectedGeneration,
                                               reason: "capture stayed silent after restart")
            } else {
                self.captureStallRestartUsed = true
                await self.restartStreamForCaptureRecovery(expectedGeneration: expectedGeneration)
            }
        }
    }

    /// Stop invalidates capture immediately and queues HAL teardown. Retained
    /// for recovery call sites; hardware work is owned by CaptureController.
    private func stopCaptureOffMain() async {
        capture.stop()
    }

    /// Tap-only retries left OwnTone playing a starved pipe. One ordered room
    /// restart resets both the capture tap and the pipe clock.
    private func restartStreamForCaptureRecovery(expectedGeneration: Int) async {
        guard phase == .streaming, streamGeneration == expectedGeneration,
              captureWatchdogInFlight else { return }
        dlog("capture stayed silent after tap rebuild -> restarting room stream")
        aiEvent("capture_restart", level: "warn", fields: ["reason": "tap callbacks missing"])
        stopStream()
        captureStallRestartUsed = true
        startStream(reason: "capture recovery")
    }

    private func failCaptureRecovery(expectedGeneration: Int, reason: String) async {
        guard phase == .streaming, streamGeneration == expectedGeneration else { return }
        dlog("capture recovery gave up: \(reason)")
        aiEvent("capture_recovery_failed", level: "error", fields: ["reason": reason])
        stopStream()
        phase = .error("Mac audio capture stopped. Press Play to retry.")
    }

    var frontName: String
    var backName: String

    var front: RoomSpeaker? { speakers.first { $0.kind == .front } }
    var back: RoomSpeaker?  { speakers.first { $0.kind == .back } }
    var extras: [RoomSpeaker] { speakers.filter { $0.kind == .extra } }
    var liveCount: Int { speakers.filter { $0.enabled }.count }
    private var sessionMembership = SpeakerSessionMembership()
    private var readyOutputIDs: Set<String> = []
    private(set) var discoveryMessage: String?
    private(set) var isDiscovering = false

    /// Placement is optional. It keeps the original front/back room drawing for
    /// configured rooms; other speakers have the same playback controls.
    func setPlacement(_ kind: RoomSpeaker.Kind, for speaker: RoomSpeaker?) {
        guard !phase.isOn, kind != .extra else { return }
        let name = speaker?.name ?? ""
        // Layout changes do not change the playback selection. Persist implicit
        // legacy front/back selections before changing what counts as primary.
        for current in speakers {
            preferences.set(current.enabled, forKey: "dali.on.\(current.name)")
        }
        if kind == .front {
            frontName = name
            if !name.isEmpty, backName == name { backName = "" }
        } else {
            backName = name
            if !name.isEmpty, frontName == name { frontName = "" }
        }
        preferences.set(frontName, forKey: "dali.frontName")
        preferences.set(backName, forKey: "dali.backName")
        for i in speakers.indices {
            speakers[i].kind = speakers[i].name == frontName ? .front
                : speakers[i].name == backName ? .back : .extra
        }
    }

    // MARK: engine plumbing (supervisor MUST be retained here)
    private var config: OwnToneConfig
    private let supervisor: EngineSupervisor
    private let spotifySupervisor: SpotifySupervisor
    private let api = BeamAPI()
    private let capture = CaptureController()
    private let roomSession = RoomSessionController()
    private var healthTask: Task<Void, Never>?

    // MARK: debug log
    // Timestamped trace of every state-affecting event (device stop, resume,
    // volume push, drift correction). Written to ~/Library/Application Support/
    // DALI/dali-debug.log so any glitch leaves a precise, readable trail.
    private nonisolated static let debugLogURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DALI/dali-debug.log")
    private nonisolated static let aiLogURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DALI/dali-ai.jsonl")
    private nonisolated static let aiHealthURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DALI/dali-health.json")

    /// JSONL incident index for tools/AI. Keys are stable, records are
    /// independently parseable, and sorted keys make diffs deterministic.
    /// At 2 MB + one previous generation this stays cheap to attach wholesale.
    private nonisolated static func writeAIEvent(_ event: String, level: String, fields: [String: Any]) {
        var payload = fields
        payload["schema"] = 1
        payload["ts_ms"] = Int(Date().timeIntervalSince1970 * 1000)
        payload["event"] = event
        payload["level"] = level
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        appendLog(line + "\n", to: aiLogURL, maxBytes: 2 * 1024 * 1024)
    }

    /// One tiny overwrite-in-place snapshot means an AI can answer "what is
    /// happening now?" without reading any history at all.
    private nonisolated static func writeAIHealth(_ fields: [String: Any]) {
        var payload = fields
        payload["schema"] = 1
        payload["ts_ms"] = Int(Date().timeIntervalSince1970 * 1000)
        payload["event"] = "health"
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        fileLogQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: aiHealthURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: aiHealthURL, options: .atomic)
        }
    }

    private func aiEvent(_ event: String, level: String = "info", fields: [String: Any] = [:]) {
        guard backendEnabled else { return }
        var tagged = fields
        tagged["session"] = aiSessionID
        Self.writeAIEvent(event, level: level, fields: tagged)
    }

    private func aiHealth(_ fields: [String: Any]) {
        guard backendEnabled else { return }
        var tagged = fields
        tagged["session"] = aiSessionID
        Self.writeAIEvent("health", level: "info", fields: tagged)
        Self.writeAIHealth(tagged)
    }

    private nonisolated static func dlog(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(msg)\n"
        appendLog(line, to: debugLogURL, maxBytes: 8 * 1024 * 1024)
    }
    func dlog(_ msg: String) { if backendEnabled { Self.dlog(msg) } }

    /// DALI has one automatic buffer. Video synchronization happens in the
    /// browser companion by delaying the picture to the room's published
    /// delay; changing the audio buffer is not a video-sync mode.
    static func savedStartBufferMs() -> Int { RoomDelayPolicy.automaticStartBufferMs }

    init(defaults: UserDefaults = .standard, backendEnabled: Bool = true,
         volumeWrite: RoomVolumeCoordinator.Write? = nil) {
        self.preferences = defaults
        self.backendEnabled = backendEnabled
        self.injectedVolumeWrite = volumeWrite
        // One-time volume sanity migration: old builds defaulted speakers to 80
        // and had a hidden balance multiplier. Big speakers deserve respect.
        if !defaults.bool(forKey: "dali.migrated.v2") {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("dali.vol.") {
                defaults.removeObject(forKey: key)
            }
            defaults.removeObject(forKey: "dali.balance")
            defaults.set(25.0, forKey: "dali.master")
            defaults.set(true, forKey: "dali.migrated.v2")
        }
        // v5: an earlier build let the start-buffer slider reach 2250ms, and that
        // stale value persists and gives clock drift a huge runway before the
        // controller can correct. Pull any deep stored buffer down to 1200.
        if !defaults.bool(forKey: "dali.migrated.v5") {
            if let v = defaults.object(forKey: "dali.startBufferMs") as? Double, v > 1600 {
                defaults.set(1200.0, forKey: "dali.startBufferMs")
            }
            defaults.set(true, forKey: "dali.migrated.v5")
        }
        // v8: stability over latency (user accepts delay, hates the pitch warble).
        // Force a DEEP buffer so the drift corrector never has to swing hard.
        if !defaults.bool(forKey: "dali.migrated.v8") {
            if let v = defaults.object(forKey: "dali.startBufferMs") as? Double, v < 1500 {
                defaults.set(2000.0, forKey: "dali.startBufferMs")
            }
            defaults.set(true, forKey: "dali.migrated.v8")
        }
        // v9: paired with the OwnTone re-anchor patch (sync every 250ms), go to the
        // max 3s buffer so the slowest device in the cross-brand group has the most
        // cushion to ride out a momentary AirPlay desync before it is audible.
        if !defaults.bool(forKey: "dali.migrated.v9") {
            if let v = defaults.object(forKey: "dali.startBufferMs") as? Double, v < 3000 {
                defaults.set(3000.0, forKey: "dali.startBufferMs")
            }
            defaults.set(true, forKey: "dali.migrated.v9")
        }
        // v10: the drift-controller anchor bug is fixed (it, not the shallow
        // buffer, caused the pitch swings and the ~4-min backlog blowout), so the
        // deep v9 buffer is now pure latency. Bring everyone down to 700ms —
        // video becomes watchable; stability is handled by the controller.
        if !defaults.bool(forKey: "dali.migrated.v10") {
            if let v = defaults.object(forKey: "dali.startBufferMs") as? Double, v > 1500 {
                defaults.set(700.0, forKey: "dali.startBufferMs")
            }
            defaults.set(true, forKey: "dali.migrated.v10")
        }
        // v3: per-speaker volumes are absolute now (AirPlay style). Bake the
        // old master multiplier in once so loudness does not jump.
        if !defaults.bool(forKey: "dali.migrated.v3") {
            let oldMaster = defaults.object(forKey: "dali.master") as? Double ?? 25
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("dali.vol.") {
                if let v = defaults.object(forKey: key) as? Double {
                    defaults.set((v * oldMaster / 100).rounded(), forKey: key)
                }
            }
            defaults.removeObject(forKey: "dali.master")
            defaults.set(true, forKey: "dali.migrated.v3")
        }
        // v4: gain calibration arrived; an earlier build shipped an over-aggressive
        // 1.6x front boost that made the front saturate. Reset gains and per-speaker
        // volumes so everyone starts at a clean, balanced 1:1 (equal slider = equal
        // output); the calibration slider then fine-tunes any real device gap.
        if !defaults.bool(forKey: "dali.migrated.v4") {
            for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("dali.gain.") || key.hasPrefix("dali.vol.") {
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: "dali.migrated.v4")
        }
        // Quiet by default. Older installs saved 80 and blasted the room during
        // agent/debug work — migrate that ceiling down once.
        if !defaults.bool(forKey: "dali.migrated.volumeLimit20") {
            // Prior defaults (40/80) were loud enough to blast the room when
            // Mac volume keys spiked. Cap everyone at 20 once.
            if let saved = defaults.object(forKey: "dali.volumeLimit") as? Double, saved > 20 {
                defaults.set(20.0, forKey: "dali.volumeLimit")
            }
            defaults.set(true, forKey: "dali.migrated.volumeLimit20")
        }
        let preferences = SpeakerPreferences(defaults: defaults)
        volumeLimit = preferences.volumeLimit
        frontName = preferences.frontName
        backName = preferences.backName

        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DALI/engine")
        let cfg = OwnToneConfig(rootDir: root, startBufferMs: Self.savedStartBufferMs())
        config = cfg

        // Use this product's helper. Development overrides are explicit; never
        // silently run a helper from another checkout or the installed V1 app.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/owntone/owntone")
        let override = ProcessInfo.processInfo.environment["DALI_ENGINE_BINARY"]
        let binary = override.map { URL(fileURLWithPath: $0) } ?? bundled
        supervisor = EngineSupervisor(binary: binary, config: cfg)
        // Spotify Connect device — shares the same pipe so front/back stay PTP-synced.
        let spotifyCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DALI/spotify-cache")
        spotifySupervisor = SpotifySupervisor(
            deviceName: "DALI",
            pipePath: cfg.pipePath,
            cacheDir: spotifyCache
        )
        delayTrimMs = defaults.double(forKey: "dali.delayTrimMs")
        mode = RoomMode(rawValue: defaults.string(forKey: "dali.mode") ?? "") ?? .mirror
        applyRoomDelay()
        applyMasterGain()
        if !backendEnabled { return }

        if Self.isPreview {
            applyPreviewState()
            return
        }

        Task { await bootEngine() }
        reapEngineOnQuit(confPath: cfg.confFile.path)
        startIdleGuard()
        observeSleepWake()
        observeNetwork()
        syncBeacon.onCut = { [weak self] cut in self?.setExtensionCut(cut) }
        syncBeacon.onNow = { NowPlayingMonitor.shared.browserReport(json: $0) }
        syncBeacon.onExtensionSeen = { [weak self] v in self?.browserExtensionVersion = v }
        // Digital silence is already carried as harmless zero samples. Do not
        // translate a 200 ms silent gap into two network volume commands for
        // every speaker: live logs proved those mute/unmute round trips can land
        // beside a scheduler delay and become the glitch themselves. The browser
        // beacon still performs an explicit cut when video really stops.
        //
        // The tap's silence is not ignored, though — reviewCutCredibility()
        // reads it once per level tick to decide whether a browser cut is still
        // telling the truth. That path only ever changes volume when a cut is
        // already armed, so an ordinary quiet passage still costs nothing.
        capture.onEvent = { [weak self] msg in
            Task { @MainActor in
                self?.dlog("capture: \(msg)")
                self?.aiEvent("capture_event", fields: ["message": msg])
            }
        }
        capture.onSourceSilenceChanged = { [weak self] silent in
            self?.dlog("source digital silence \(silent ? "began" : "ended") — keepalive only; speaker volume unchanged")
        }
        syncBeacon.start()
        // Volume keys: when the Mac itself is silent (room-only), the hardware
        // volume keys steer the ROOM master via the system volume they change.
        // Apply one shared PCM gain; the capture layer ramps it over 15 ms.
        // Ordinary keys change no receiver controls. Zero additionally sends
        // urgent receiver mute to cover audio already in the AirPlay pipeline.
        // @Sendable: CoreAudio invokes this on its own queue, so it must not
        // inherit this initializer's main-actor isolation (a runtime trap).
        volumeObserver.onChange = { @Sendable [weak self] new, prev in
            Task { @MainActor in
                guard let self, new.isFinite, prev.isFinite else { return }
                self.desiredSystemVolume = min(max(new, 0), 1)
                if new < prev - 0.001 {
                    self.systemVolume = self.desiredSystemVolume
                } else {
                    self.startSysVolRamp()
                }
            }
        }
        let initial = volumeObserver.current() ?? 0.5
        systemVolume = initial
        desiredSystemVolume = initial
    }

    /// UI harness only (`DALI_PREVIEW=1`): no engine, no capture, no beacon,
    /// no network, never touches the live room. Renders a streaming room with
    /// the real two pairs so the chrome can be screenshotted.
    /// Cached: `ProcessInfo.environment` rebuilds a full dictionary on every read,
    /// and this was read per log line and per view body evaluation.
    nonisolated static let isPreview: Bool = ProcessInfo.processInfo.environment["DALI_PREVIEW"] == "1"

    private func applyPreviewState() {
        let env = ProcessInfo.processInfo.environment
        speakers = [
            RoomSpeaker(id: "preview-front", name: "MICHAEL D", type: "AirPlay 2",
                        kind: .front, enabled: true, relVolume: 100, health: .live),
            RoomSpeaker(id: "preview-back", name: "MICHAEL S", type: "AirPlay 2",
                        kind: .back, enabled: true, relVolume: 100, health: .live),
        ]
        audioLevel = 0.62; bassLevel = 0.5; trebleLevel = 0.4
        if env["DALI_PREVIEW_PHASE"] != "idle" { phase = .streaming }
    }

    @ObservationIgnored private lazy var volumeObserver = SystemVolumeObserver()
    /// Latest Mac master intent; PCM smoothing is owned by capture.
    private var desiredSystemVolume: Double = 0.5

    private func startSysVolRamp() {
        systemVolume = desiredSystemVolume
        scheduleVolumePush()
    }

    // MARK: engine lifecycle

    private func bootEngine() async {
        do {
            try await supervisor.start()
            lastEngineStartAt = Date()
            ptpDegraded = await supervisor.ptpAvailable == false
            if ptpDegraded { dlog("PTP degraded — front/back sync may drift (NTP-only)") }
            await refreshSpeakers()
            await reconcileEngineState()
            await loadLibrary()
        } catch {
            // A late boot failure must not overwrite a session the user has
            // already started (startStream boots the engine itself if needed).
            guard !phase.isOn else { return }
            phase = .error("The audio engine could not start.\n\(error)")
        }
    }

    /// The engine can resume pipe playback on its own after a restart, holding
    /// the speakers while the app shows OFF. The app's state wins: if we are
    /// not streaming, the engine must not play.
    private func reconcileEngineState() async {
        guard !phase.isOn else { return }
        let generation = streamGeneration
        if let st = try? await api.playerState(), st.state == "play" {
            // The read took time: the user may have pressed Play meanwhile, and
            // that playback is legitimate — stopping it would kill the session
            // that just started.
            guard !phase.isOn, generation == streamGeneration else { return }
            try? await api.stop()
        }
    }

    func shutdown() async {
        guard backendEnabled else { return }
        stopStream()
        await teardownTask?.value
        await supervisor.stop()
    }

    /// One engine restart at a time. This is wired straight to a Picker setter, so
    /// two quick clicks used to run two overlapping kill/relaunch cycles.
    private var engineRestartInFlight = false

    func restartEngine() {
        guard backendEnabled else { return }
        guard !engineRestartInFlight else {
            dlog("engine restart ignored: one already in flight")
            return
        }
        // A restart is a deliberate, disruptive act (kills the engine and, if
        // streaming, rebuilds the room). It used to also run in the middle of a
        // start, killing it. It is logged here because it was silent: the
        // pause -> SIGTERM -> relaunch -> second "stream started" sequence in the
        // logs was this function.
        guard phase != .starting else {
            dlog("engine restart ignored: a start is in progress")
            return
        }
        dlog("engine restart requested (phase \(phase == .streaming ? "streaming" : "idle/error"))")
        aiEvent("engine_restart", level: "warn", fields: ["phase": phase == .streaming ? "streaming" : "other"])
        lastTeardownAt = Date()
        engineRestartInFlight = true
        let resumeMirror = phase == .streaming && !playerMode
        streamGeneration += 1
        let generation = streamGeneration
        healthTask?.cancel(); healthTask = nil
        levelTask?.cancel(); levelTask = nil
        flightTask?.cancel(); flightTask = nil
        nowTask?.cancel(); nowTask = nil
        fading = false
        // The old capture watchdog belongs to the session being torn down; left
        // set, it would disable the tap watchdog for the whole next session.
        captureWatchdogInFlight = false
        captureStallRestartUsed = false
        // A restarted engine has an empty queue; a stale "has queue / playing"
        // would make the player button resume nothing.
        if playerMode { hasQueue = false; isPlaying = false }
        for i in speakers.indices { speakers[i].health = .off }
        phase = .starting
        let sessionCleanup = roomSession.invalidateAndStop()
        Task { @MainActor in
            defer { engineRestartInFlight = false }
            await sessionCleanup.value
            await teardownTask?.value
            await stopSpotify()
            guard generation == streamGeneration else { return }
            await stopCaptureOffMain()
            // Rebuild config so a changed audio-delay pref takes effect.
            config = OwnToneConfig(rootDir: config.rootDir,
                                   startBufferMs: Self.savedStartBufferMs())
            await supervisor.updateConfig(config)
            await supervisor.setResumePlayback(false)
            try? await api.stop()
            // The user may have pressed Stop (or started a new session) while we
            // waited; do not kill an engine that now belongs to someone else.
            guard generation == streamGeneration else { return }
            do {
                try await supervisor.restart()
                lastEngineStartAt = Date()
                guard generation == streamGeneration else { return }
                await refreshSpeakers()
                guard generation == streamGeneration else { return }
                phase = .idle
                // startStream waits for engineRestartInFlight; release it first.
                engineRestartInFlight = false
                if resumeMirror { startStream(reason: "engine restart") }
            } catch {
                guard generation == streamGeneration else { return }
                phase = .error("The audio engine could not restart.\n\(error)")
            }
        }
    }

    // MARK: discovery

    /// The discovery already in flight, so a second caller can wait for it.
    private var discoveryTask: Task<Void, Never>?

    func refreshSpeakers() async {
        guard backendEnabled, !Self.isPreview else { return }
        // Join a discovery already running instead of returning at once: boot
        // discovery is slow, and a Play pressed during it used to read the still
        // EMPTY speaker list and fail with "Choose at least one speaker".
        if let inFlight = discoveryTask { await inFlight.value; return }
        isDiscovering = true
        // Unstructured, so the caller being cancelled cannot cancel (and thereby
        // slam shut) the request mid-flight.
        let task = Task { @MainActor in
            defer { isDiscovering = false; discoveryTask = nil }
            do {
                let outputs = try await api.outputs()
                discoveryMessage = nil
                applyDiscoveredSpeakers(outputs)
            } catch {
                discoveryMessage = "Speakers could not be refreshed. Try again in a moment."
            }
        }
        discoveryTask = task
        await task.value
    }

    /// Shared discovery application also used by the offline app fixture.
    func applyDiscoveredSpeakers(_ outputs: [Output]) {
        let preferences = SpeakerPreferences(defaults: preferences)
        var list: [RoomSpeaker] = []
        let host = hostName()
        let discovered = outputs.filter { $0.name != host && $0.type.localizedCaseInsensitiveContains("AirPlay") }
        readyOutputIDs = Set(discovered.filter(\.isSessionReady).map(\.id))
        for o in discovered {
            let kind: RoomSpeaker.Kind =
                o.name == frontName ? .front :
                o.name == backName ? .back : .extra
            let wasEnabled = preferences.enabled(name: o.name, primary: kind != .extra)
            // Keep live health when re-discovering mid-stream (window reopen etc).
            let existing = speakers.first { $0.name == o.name }
            list.append(RoomSpeaker(
                id: o.id, name: o.name, type: o.type, kind: kind,
                enabled: wasEnabled,
                relVolume: preferences.volume(name: o.name),
                gain: preferences.gain(name: o.name),
                offsetMs: o.offset_ms ?? 0,   // engine persists this in its own DB
                health: existing?.health ?? .off))
        }
        // rememberedNames walks all of UserDefaults; this runs on every poll.
        if Date().timeIntervalSince(rememberedNamesAt) > 30 {
            rememberedNamesCache = preferences.rememberedNames
            rememberedNamesAt = Date()
        }
        let remembered = rememberedNamesCache.union(speakers.filter { $0.enabled }.map(\.name))
        let presentNames = Set(list.map(\.name))
        for name in remembered.subtracting(presentNames) {
            let kind: RoomSpeaker.Kind = name == frontName ? .front : name == backName ? .back : .extra
            let enabled = preferences.enabled(name: name, primary: kind != .extra)
            list.append(RoomSpeaker(
                id: "unavailable:\(name)", name: name, type: "AirPlay", kind: kind,
                enabled: enabled, relVolume: preferences.volume(name: name),
                gain: preferences.gain(name: name), health: enabled && phase.isOn ? .trouble : .off,
                available: false))
        }
        // Front, back, then extras alphabetically.
        let sorted = list.sorted {
            rank($0.kind) == rank($1.kind) ? $0.name < $1.name : rank($0.kind) < rank($1.kind)
        }
        // The health loop calls this every 3 s; an unchanged room must not
        // invalidate every view reading `speakers`.
        if sorted != speakers { speakers = sorted }
        // Seed the offset cache from what the engine ACTUALLY reports, so the
        // dedupe is anchored to truth rather than to our own memory of writes.
        // Then re-assert zero: this method overwrites offsetMs from the engine,
        // and without a re-assert a discovery (boot, a name change, a network
        // path restore) silently reverted the model to the engine's value while
        // the slider still claimed otherwise.
        for o in outputs {
            if let ms = o.offset_ms { lastSentOffset[o.id] = ms }
        }
        enforceZeroOffsets()
    }

    private func rank(_ k: RoomSpeaker.Kind) -> Int { k == .front ? 0 : k == .back ? 1 : 2 }

    private var hostNameCache: (name: String, at: Date)?

    /// `Host.current()` can block on name resolution for seconds and this runs on
    /// the main actor every health poll — cache it.
    private func hostName() -> String {
        if let c = hostNameCache, Date().timeIntervalSince(c.at) < 300 { return c.name }
        let name = Host.current().localizedName ?? ""
        hostNameCache = (name, Date())
        return name
    }

    // MARK: the big switch

    /// Bumped on every start/stop so an in-flight startStream Task cannot keep
    /// hard-rejoining or flipping phase after the user stopped / a prior attempt
    /// already failed cleanly.
    private var streamGeneration = 0

    /// When the room was last torn down (stop, capture-recovery restart, engine
    /// restart, failed start). A new start waits out the speakers' own teardown
    /// of that session (`settleAfterTeardown`) instead of racing it.
    private var lastTeardownAt = Date.distantPast
    /// When the engine process last came up. A fresh engine has no mDNS view and
    /// no sessions yet; selecting outputs into that gap is what failed BOTH
    /// speakers at once (owntone.log: 5 of 6 "failed to activate" episodes on
    /// 2026-09-30 came 3-37 s after an engine (re)start, none after a plain
    /// stop -> start on a running engine).
    private var lastEngineStartAt = Date.distantPast

    /// Wait until the speakers have let go of the previous session: at least
    /// `minSettle` s after the teardown was issued, then until the engine
    /// reports none of this room's outputs connected/streaming (bounded).
    private func settleAfterTeardown(gen: Int) async {
        let minSettle = 2.5, maxWait = 6.0
        let sinceTeardown = Date().timeIntervalSince(lastTeardownAt)
        let sinceEngine = Date().timeIntervalSince(lastEngineStartAt)
        let floor = max(sinceTeardown < 30 ? minSettle - sinceTeardown : 0,
                        sinceEngine < 30 ? 3.0 - sinceEngine : 0)
        if floor > 0 { try? await Task.sleep(nanoseconds: UInt64(floor * 1_000_000_000)) }
        guard sinceTeardown < 30 else { return }
        let names = Set(sessionSpeakers().map(\.name))
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline, phase == .starting, gen == streamGeneration {
            guard let outs = try? await api.outputs() else { break }
            // Wait for `connected` to clear as well as `streaming`. AirPlay 2 receivers
            // keep `connected` for a few seconds while they tear the old session
            // down; a new SETUP that lands inside that window leaves the engine
            // reporting "streaming" while one receiver (random: front, back or
            // both) plays nothing. Shortening this wait caused exactly that.
            let busy = outs.filter { names.contains($0.name) && ($0.streaming == true || $0.connected == true) }
            if busy.isEmpty { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if phase == .starting, gen == streamGeneration {
            dlog("start settle: previous session still reported after \(Int(maxWait)) s; proceeding")
        }
    }

    func toggleStream() {
        phase.isOn ? stopStream() : startStream()
    }

    /// Leave `.error` the cheap way. Most errors ("no speakers found", "did
    /// not start playing", "speakers did not connect") are a bad moment on the
    /// network, not a broken engine — a fresh start is the honest first try,
    /// and a 10 s+ engine respawn should be the second, not the only, option.
    func retryAfterError() {
        guard case .error = phase else { return }
        phase = .idle
        dlog("retry after error")
        switch mode {
        case .mirror: startStream(reason: "retry after error")
        case .player: shuffleAll()
        }
    }

    /// Single-flight and idempotent: a start while `.starting`/`.streaming` is a
    /// no-op (the phase flips synchronously on the main actor, so two callers
    /// can never both pass this guard). `reason` names the caller in the log so
    /// an unexpected second start is attributable.
    func startStream(reason: String = "user") {
        guard backendEnabled else { return }
        guard !phase.isOn else {
            dlog("start ignored (\(reason)): already \(phase == .streaming ? "streaming" : "starting")")
            return
        }
        resolveSavedSource()
        let sessionSource = source
        let precedingTeardown = teardownTask
        dlog("start requested (\(reason))")
        sessionMembership.reset()
        streamGeneration += 1
        let gen = streamGeneration
        phase = .starting
        // Never inherit a cut from the last session: a room that starts up
        // already muted looks exactly like a broken stream. If the browser
        // still wants silence it re-asserts within ~1s.
        resetCutState()
        speakerRecoveryInFlight.removeAll()
        recoveryCooldownUntil.removeAll()
        recoveryFailCounts.removeAll()
        // A settle task from the previous session must not run its recovery
        // against this one.
        networkSettleTask?.cancel(); networkSettleTask = nil
        let dependencies = RoomSessionController.Dependencies(
            prepare: { context in
                while self.engineRestartInFlight {
                    try context.check()
                    try await Task.sleep(for: .milliseconds(250))
                }
                if await !self.api.isUp() {
                    try await self.supervisor.start()
                    self.lastEngineStartAt = Date()
                }
                try context.check()
                let ptpAvailable = await self.supervisor.ptpAvailable
                try context.check()
                self.ptpDegraded = !ptpAvailable
                // Never join a teardown created by Stop during this startup:
                // that teardown itself waits for this startup to drain.
                await precedingTeardown?.value
                try context.check()
                await self.refreshSpeakers()
                try context.check()
                if Date().timeIntervalSince(self.lastEngineStartAt) < 30 {
                    for _ in 0..<8 {
                        guard self.speakers.contains(where: { $0.enabled && !$0.available }) else { break }
                        try await Task.sleep(for: .milliseconds(750))
                        try context.check()
                        await self.refreshSpeakers()
                        try context.check()
                    }
                }
                let chosen = self.sessionSpeakers()
                guard chosen.contains(where: \.enabled) else {
                    throw BeamAPIError(what: self.speakers.contains(where: \.enabled)
                        ? "Your selected speakers are unavailable. Check their power and Wi-Fi."
                        : "Choose at least one speaker in Room settings.")
                }
                for speaker in chosen { self.sessionMembership.retain(speaker.name) }
                self.markHealth(of: chosen.map(\.id), .connecting)
                self.updateVolumeIntent()
                return RoomSessionController.Plan(speakers: chosen.map {
                    RoomSessionController.Speaker(id: $0.id, name: $0.name)
                }, allowsCaptureReset: sessionSource != .spotify)
            },
            isCurrent: { self.phase == .starting && self.streamGeneration == gen },
            settle: { context in
                await self.settleAfterTeardown(gen: gen)
                try context.check()
            },
            setOutputs: { try await self.api.setOutputs(ids: $0) },
            setSelected: { try await self.api.setSelected(outputID: $0, selected: $1) },
            outputs: { try await self.api.outputs() },
            silenceOutputs: { ids in
                for id in ids { try await self.silenceOutput(id) }
            },
            startCapture: { context in
                // The source is frozen at admission. Source changes replace
                // the session and the preceding teardown owns the old child.
                guard await self.stopSpotify() else {
                    throw BeamAPIError(what: "The previous Spotify audio producer did not exit. Retry after it has stopped.")
                }
                try context.check()
                if sessionSource == .spotify {
                    try await self.startSpotifyIfNeeded(context: context)
                    try context.check()
                    let direct = await self.spotifySupervisor.isLibrespotAvailable
                    try context.check()
                    if direct { return }
                }
                // Set the latest shared gain before admission and preserve it
                // while HAL setup waits. The capture layer rechecks it at frame1.
                self.applyMasterGain()
                try context.check()
                try await self.capture.startAsync(fifoPath: self.config.pipePath.path,
                                                  muteLocal: true, source: sessionSource.tapSource)
                try context.check()
            },
            stopCapture: { self.capture.stop() },
            stopPlayback: { try await self.api.stop() },
            setResumePlayback: { await self.supervisor.setResumePlayback($0) },
            isPlaying: { try await self.api.playerState().state == "play" },
            rescan: { try await self.api.rescan() },
            pipeTrackURI: { try await self.api.pipeTrackURI(named: "beam.pipe") },
            playPipe: { try await self.api.playPipe(uri: $0) },
            didTearDown: { self.lastTeardownAt = Date() },
            event: { self.aiEvent("startup_recovery", level: "warn", fields: ["event": String(describing: $0)]) }
        )
        Task { @MainActor in
            guard phase == .starting, gen == streamGeneration else { return }
            do {
                guard let result = try await roomSession.start(using: dependencies),
                      phase == .starting, gen == streamGeneration else { return }
                readyOutputIDs = result.readyIDs
                markHealth(of: result.plan.ids, .live)
                markHealth(of: Array(result.missing), .trouble)
                if !result.missing.isEmpty {
                    aiEvent("start_partial", level: "warn", fields: ["missing_ids": Array(result.missing)])
                }
                resetOffsetCache()
                enforceZeroOffsets(force: true)
                phase = .streaming
                startHealthLoop(); startLevelLoop(); startFlightRecorder()
                await fadeIn()
            } catch let error as ProcessTap.TapError {
                guard gen == streamGeneration else { return }
                markHealth(of: sessionSpeakers().map(\.id), .off)
                phase = .error("DALI needs permission to capture your Mac's audio. (\(error.stage))")
            } catch {
                guard gen == streamGeneration else { return }
                markHealth(of: sessionSpeakers().map(\.id), .off)
                phase = .error("Could not start the stream.\n\(error.localizedDescription)")
            }
        }
    }

    private var teardownTask: Task<Void, Never>?

    /// All terminal phases drain startup and the previous producer before a
    /// replacement can use the same FIFO. Next generation never skips teardown.
    private func enqueueSessionTeardown() {
        capture.stop()
        let sessionCleanup = roomSession.invalidateAndStop()
        let previousTeardown = teardownTask
        teardownTask = Task {
            await previousTeardown?.value
            await sessionCleanup.value
            await stopSpotify()
            // Player sessions have no RoomSession startup dependency snapshot.
            // Their stop lives in this same barrier, before any replacement.
            try? await api.stop()
            await supervisor.setResumePlayback(false)
        }
    }

    func stopStream() {
        guard backendEnabled else { phase = .idle; return }
        lastTeardownAt = Date()
        streamGeneration += 1
        _ = api.invalidateSession()
        captureWatchdogInFlight = false
        captureStallRestartUsed = false
        healthTask?.cancel()
        levelTask?.cancel()
        flightTask?.cancel()
        speakerRecoveryInFlight.removeAll()
        recoveryCooldownUntil.removeAll()
        recoveryFailCounts.removeAll()
        fading = false
        audioLevel = 0
        resetCutState()
        networkSettleTask?.cancel(); networkSettleTask = nil
        capture.stop()
        for i in speakers.indices { speakers[i].health = .off }
        dlog("stream stopped by user")
        aiEvent("stream_stop", fields: ["reason": "user"])
        phase = .idle
        aiHealth(["phase": "idle", "status": "stopped"])
    }

    // MARK: Spotify Connect
    private func startSpotifyIfNeeded(context: RoomSessionController.Context) async throws {
        try context.check()
        dlog("Spotify Connect starting")
        aiEvent("spotify_start", fields: ["device": "DALI"])
        try await spotifySupervisor.start()
        try context.check()
        if await spotifySupervisor.state == .running {
            try context.check()
            dlog("Spotify Connect ready")
        }
    }

    @discardableResult
    private func stopSpotify() async -> Bool {
        let stopped = await spotifySupervisor.stopConfirmed()
        dlog(stopped ? "Spotify Connect stopped" : "Spotify producer shutdown not confirmed")
        return stopped
    }

    private func markHealth(of ids: [String], _ h: RoomSpeaker.Health) {
        for i in speakers.indices where ids.contains(speakers[i].id) {
            speakers[i].health = h
        }
    }

    // MARK: player model (sourced audio -> both rooms, no capture)
    // OwnTone plays from its own library (your ~/Music) straight to the AirPlay
    // group. There is no system-audio capture and no pipe, so the two-clock drift
    // that caused the glitching cannot happen: the engine reads a file at the
    // speakers' own clock, exactly like AirPlaying a song natively.

    /// Mirror = capture the Mac's audio (Chrome, YouTube, anything) and relay it.
    /// Player = the engine sources music from your library itself (no capture).
    enum RoomMode: String, Hashable { case mirror, player }
    var mode: RoomMode = .mirror {
        didSet {
            guard oldValue != mode else { return }
            preferences.set(mode.rawValue, forKey: "dali.mode")
            // Switching mode stops whatever the other mode was doing.
            if phase.isOn { oldValue == .player ? stopPlayback() : stopStream() }
        }
    }
    /// True only in player mode: changes volume math + recovery so a pause is not
    /// "rescued" and the Mac's own volume is ignored.
    var playerMode: Bool { mode == .player }
    var library: [LibraryAlbum] = []
    private(set) var hasQueue = false
    var isPlaying = false
    var nowTitle = ""
    var nowArtist = ""
    var nowProgress: Double = 0          // 0...1 through the current track
    private var nowTask: Task<Void, Never>?
    private var playerCommandGeneration = 0
    private var startingPlayback = false

    /// Load the album list from the engine's library (best-effort).
    func loadLibrary() async {
        guard backendEnabled else { return }
        guard !Self.isPreview else { return }
        guard await api.isUp() else { return }
        library = (try? await api.albums()) ?? []
    }

    /// What the big button does, depending on mode + phase.
    func bigButtonTapped() {
        switch mode {
        case .mirror:
            toggleStream()   // capture system audio (Chrome and everything)
        case .player:
            switch phase {
            case .idle:      shuffleAll()
            case .streaming: togglePlayPause()
            case .starting, .error: break
            }
        }
    }

    /// Shuffle the whole music library into the room.
    func shuffleAll() {
        playToRoom { try await $0.playExpression("media_kind is music", shuffle: true) }
    }

    /// Play one album into the room.
    func play(_ album: LibraryAlbum) {
        playToRoom { try await $0.playUris(album.uri) }
    }

    /// Select the speakers, make sure the engine is up, and start silent.
    private func prepareRoom(current: @MainActor () -> Bool) async -> Bool {
        guard current() else { return false }
        if await !api.isUp() {
            guard current() else { return false }
            try? await supervisor.start()
        }
        guard current() else { return false }
        await refreshSpeakers()
        guard current() else { return false }
        let chosen = sessionSpeakers()
        guard chosen.contains(where: \.enabled) else {
            phase = .error("Choose an available speaker in Settings → Room.")
            return false
        }
        for speaker in chosen { sessionMembership.retain(speaker.name) }
        markHealth(of: chosen.map(\.id), .connecting)
        updateVolumeIntent()
        do {
            try await api.setOutputs(ids: chosen.map(\.id))
            guard current() else { return false }
            for sp in chosen {
                guard current() else { return false }
                try await silenceOutput(sp.id)
                guard current() else { return false }
            }
            return current()
        } catch {
            guard current() else { return false }
            phase = .error("Could not prepare the selected speakers.\n\(error.localizedDescription)")
            return false
        }
    }

    private func playToRoom(_ start: @escaping (BeamAPI) async throws -> Void) {
        guard backendEnabled, playerMode else { return }
        guard !startingPlayback else { return }
        streamGeneration += 1
        playerCommandGeneration += 1
        let command = playerCommandGeneration
        let stream = streamGeneration
        let precedingTeardown = teardownTask
        startingPlayback = true
        phase = .starting
        Task {
            defer { if command == playerCommandGeneration { startingPlayback = false } }
            // stopPlayback() bumps both counters. Every await below is a window
            // for it; without these checks a stopped room flipped itself back
            // to `.streaming` and kept playing under an idle UI.
            @MainActor func current() -> Bool {
                playerMode && command == playerCommandGeneration && stream == streamGeneration && phase == .starting
            }
            guard current() else { return }
            await precedingTeardown?.value
            guard current() else { return }
            let producerStopped = await stopSpotify()
            guard current() else { return }
            guard producerStopped else {
                phase = .error("The previous Spotify audio producer did not exit. Retry after it has stopped.")
                return
            }
            guard await prepareRoom(current: current), current() else { return }
            do { try await start(api) }
            catch {
                guard current() else { return }
                markHealth(of: sessionSpeakers().map(\.id), .off)
                phase = .error("Could not start playback.\n\(error)")
                return
            }
            guard current() else { return }
            // A rejected selection must not be presented as a live room.
            do { try await api.setOutputs(ids: sessionSpeakers().map(\.id)) }
            catch {
                guard current() else { return }
                phase = .error("Could not select the room speakers.\n\(error.localizedDescription)")
                return
            }
            guard current() else { return }
            hasQueue = true
            isPlaying = true
            phase = .streaming
            markHealth(of: sessionSpeakers().map(\.id), .live)
            dlog("player: started -> \(sessionSpeakers().map(\.name).joined(separator: ", "))")
            startHealthLoop()
            startNowPlayingLoop()
            await fadeIn()
        }
    }

    func togglePlayPause() {
        if !hasQueue { shuffleAll(); return }
        issuePlayerPlaybackCommand(shouldPlay: !isPlaying)
    }

    /// Reflect play/pause immediately, then correct the UI only if the engine
    /// rejects the command. Waiting for the HTTP reply before changing the
    /// button made a local tap feel stuck during a slow AirPlay control reply.
    private func issuePlayerPlaybackCommand(shouldPlay: Bool) {
        playerCommandGeneration += 1
        let command = playerCommandGeneration
        let previous = isPlaying
        let stream = streamGeneration
        nowTask?.cancel(); nowTask = nil
        isPlaying = shouldPlay
        if !shouldPlay {
            audioLevel = 0; bassLevel = 0; trebleLevel = 0
        }
        Task { @MainActor in
            guard playerMode, command == playerCommandGeneration,
                  stream == streamGeneration, phase == .streaming else { return }
            do {
                if shouldPlay { try await api.play() }
                else { try await api.pause() }
                guard command == playerCommandGeneration,
                      stream == streamGeneration,
                      phase == .streaming else { return }
                if shouldPlay { startNowPlayingLoop() }
            } catch {
                guard command == playerCommandGeneration,
                      stream == streamGeneration,
                      phase == .streaming else { return }
                isPlaying = previous
                startNowPlayingLoop()
                dlog("player \(shouldPlay ? "resume" : "pause") failed: \(error)")
            }
        }
    }

    func next()     { Task { try? await api.next() } }
    func previous() { Task { try? await api.previous() } }

    func stopPlayback() {
        guard backendEnabled else { phase = .idle; return }
        streamGeneration += 1
        playerCommandGeneration += 1
        _ = api.invalidateSession()
        startingPlayback = false
        nowTask?.cancel(); nowTask = nil
        healthTask?.cancel()
        networkSettleTask?.cancel(); networkSettleTask = nil
        fading = false
        resetCutState()
        isPlaying = false; hasQueue = false; phase = .idle
        nowTitle = ""; nowArtist = ""; nowProgress = 0; audioLevel = 0
        for i in speakers.indices { speakers[i].health = .off }
        dlog("player: stopped by user")
        aiEvent("stream_stop", fields: ["reason": "user", "mode": "player"])
        aiHealth(["phase": "idle", "status": "stopped", "mode": "player"])
    }

    /// Poll the engine for now-playing + keep the room visualization alive.
    private func startNowPlayingLoop() {
        nowTask?.cancel()
        nowTask = Task {
            // /api/queue returns EVERY queued item — after "shuffle all" that is
            // the whole library — and this loop used to fetch and decode it every
            // 0.7 s. The queue only matters when the current item changes.
            var metaItemID: Int?
            var metaLengthMs: Int?
            while !Task.isCancelled && phase == .streaming {
                if let ps = try? await api.playerState(), !Task.isCancelled {
                    let playing = (ps.state == "play")
                    if isPlaying != playing { isPlaying = playing }
                    if let itemID = ps.item_id, itemID != metaItemID,
                       let items = try? await api.queue(), !Task.isCancelled,
                       let cur = items.first(where: { $0.id == itemID }) {
                        metaItemID = itemID
                        metaLengthMs = cur.length_ms
                        nowTitle = cur.title ?? ""
                        nowArtist = cur.artist ?? ""
                    }
                    if let len = ps.item_length_ms ?? metaLengthMs, len > 0,
                       let p = ps.item_progress_ms {
                        let progress = min(1, max(0, Double(p) / Double(len)))
                        if progress != nowProgress { nowProgress = progress }
                    }
                }
                // No capture to measure, so feed the room canvas a gentle pulse.
                let a = isPlaying ? 0.5 : 0, b = isPlaying ? 0.4 : 0, t = isPlaying ? 0.3 : 0
                if audioLevel != a { audioLevel = a }
                if bassLevel != b { bassLevel = b }
                if trebleLevel != t { trebleLevel = t }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            audioLevel = 0; bassLevel = 0; trebleLevel = 0
        }
    }

    // MARK: speaker toggles

    func toggle(_ speaker: RoomSpeaker) {
        guard let idx = speakers.firstIndex(where: { $0.id == speaker.id }) else { return }
        let enabling = !speakers[idx].enabled
        guard !enabling || speaker.available else { return }
        guard phase != .starting else { return }
        if !enabling && speaker.available
            && speakers.filter({ $0.enabled && $0.available }).count <= 1 && phase.isOn { return }
        let alreadyJoined = sessionMembership.contains(name: speaker.name, enabled: false,
                                                       primary: speaker.kind != .extra)
        speakers[idx].enabled = enabling
        preferences.set(enabling, forKey: "dali.on.\(speaker.name)")
        guard phase == .streaming else { return }
        let sp = speakers[idx]
        if enabling && !alreadyJoined {
            guard backendEnabled else {
                speakers[idx].health = .connecting
                scheduleVolumePush()
                return
            }
            sessionMembership.retain(sp.name)
            speakers[idx].health = .connecting
            let generation = streamGeneration
            speakerRecoveryInFlight.insert(sp.id)
            Task { @MainActor in
                defer {
                    if generation == streamGeneration { speakerRecoveryInFlight.remove(sp.id) }
                }
                do {
                    // Join quietly. Reading readiness before restoring volume
                    // avoids reporting a selected-but-disconnected device live.
                    try await silenceOutput(sp.id)
                    guard streamIsCurrent(generation) else { return }
                    try await api.setSelected(outputID: sp.id, selected: true)
                    guard streamIsCurrent(generation) else { return }
                    let missing = await awaitOutputsReady(ids: [sp.id], timeoutMs: 8_000)
                    guard streamIsCurrent(generation),
                          let current = speakers.firstIndex(where: { $0.id == sp.id }) else { return }
                    if missing.isEmpty { readyOutputIDs.insert(sp.id) }
                    speakers[current].health = !speakers[current].enabled ? .off
                        : missing.isEmpty ? .live : .trouble
                    speakerRecoveryInFlight.remove(sp.id)
                    enforceZeroOffsets(force: true)
                    forceVolumeResync(ids: [sp.id])
                } catch {
                    guard streamIsCurrent(generation),
                          let current = speakers.firstIndex(where: { $0.id == sp.id }) else { return }
                    speakers[current].health = speakers[current].enabled ? .trouble : .off
                    dlog("Could not join \(sp.name): \(error)")
                }
            }
        } else {
            // Every joined member stays in the group. "Off" is volume zero,
            // preserving the shared clock for both primary and extra speakers.
            let ready = readyOutputIDs.contains(sp.id)
            speakers[idx].health = enabling ? (ready ? .live : .connecting) : .off
            if enabling { readyStrikes[sp.id] = ready ? 2 : 0; troubleStrikes[sp.id] = 0 }
            scheduleVolumePush()
        }
    }

    /// Speakers that are part of the live AirPlay session: the front/back pair is
    /// always in the group while streaming (muted when "off" to preserve sync);
    /// extras join when enabled and remain silently joined until playback stops.
    private func sessionSpeakers() -> [RoomSpeaker] {
        speakers.filter {
            $0.available && sessionMembership.contains(name: $0.name, enabled: $0.enabled,
                                                       primary: $0.kind != .extra)
        }
    }

    // MARK: volume model
    // Receiver references and shared PCM master are planned together.

    func setRelVolume(_ v: Double, for speaker: RoomSpeaker) {
        guard let idx = speakers.firstIndex(where: { $0.id == speaker.id }) else { return }
        guard v.isFinite else { return }
        let clamped = min(max(v, 0), 100)
        speakers[idx].relVolume = clamped
        preferences.set(clamped, forKey: "dali.vol.\(speaker.name)")
        scheduleVolumePush()
    }

    /// Per-speaker calibration gain (0.25...4). Lets the underpowered front
    /// (amp + passive Opticons) be brought up to match the self-amped Sonos so
    /// the slider ratio actually balances the room.
    func setGain(_ g: Double, for speaker: RoomSpeaker) {
        guard let idx = speakers.firstIndex(where: { $0.id == speaker.id }) else { return }
        guard g.isFinite else { return }
        let clamped = min(max(g, 0.25), 4)
        speakers[idx].gain = clamped
        preferences.set(clamped, forKey: "dali.gain.\(speaker.name)")
        scheduleVolumePush()
    }

    /// Hard ceiling for what any speaker is ever sent (big speakers, small room).
    var volumeLimit: Double {
        didSet {
            // Assigning inside didSet does not re-enter it, so the old early
            // `return` after clamping skipped both the save and the push and
            // left the stored ceiling out of step with the live one. A
            // non-finite value would also have poisoned every Int() below.
            let clamped = volumeLimit.isFinite ? min(max(volumeLimit, 1), 100) : oldValue
            if clamped != volumeLimit { volumeLimit = clamped }
            guard clamped != oldValue else { return }
            preferences.set(volumeLimit, forKey: "dali.volumeLimit")
            scheduleVolumePush()
        }
    }

    /// What we have CONFIRMED the engine holds. Only written after a PUT
    /// actually succeeded — see scheduleOffsetPush().
    private var lastSentOffset: [String: Int] = [:]
    private var offsetPushTask: Task<Void, Never>?
    private var offsetPushAgain = false
    private var offsetPushEpoch = 0

    /// Drive both pair members to a timing offset of zero.
    ///
    /// This replaces the Space control (see the note where SpaceRow used to live
    /// in RoomView). Both speakers are AirPlay 2 and both lock to the same PTP
    /// grandmaster, so each receiver already compensates its own output latency
    /// against the presentation timestamp — measured live, the engine reported
    /// `clock - pts` identical to the millisecond for both. Any nonzero offset
    /// here IS the audible gap, not a cure for one.
    ///
    /// Still pushed rather than merely assumed, for two reasons: output ids are
    /// session-scoped so a new stream can inherit whatever the engine last
    /// stored (the DB held a stale `MICHAEL D = 60` from the old control long
    /// after the app had moved on), and a muted pair member stays in the AirPlay
    /// group, so skipping it would leave a wrong value to surface on unmute.
    ///
    /// `force` pushes even when the model already holds zero — used after
    /// resetOffsetCache(), where the model is right but our record of what the
    /// ENGINE holds has deliberately been thrown away.
    func enforceZeroOffsets(force: Bool = false) {
        var changed = force
        for i in speakers.indices where speakers[i].available
            && sessionMembership.contains(name: speakers[i].name, enabled: speakers[i].enabled,
                                          primary: speakers[i].kind != .extra) {
            if speakers[i].offsetMs != 0 {
                speakers[i].offsetMs = 0
                changed = true
            }
        }
        guard changed else { return }
        dlog("offsets -> 0 ms on room speakers\(force ? " (forced after session change)" : "")")
        scheduleOffsetPush()
    }

    /// Zero-offset assertions are serialized and fenced by session and epoch.
    /// A canceled HTTP request drains through BeamAPI, but its late receipt
    /// cannot populate a replacement engine/session's offset cache.
    private func scheduleOffsetPush() {
        guard backendEnabled, phase.isOn else { return }
        if offsetPushTask != nil { offsetPushAgain = true; return }
        let generation = streamGeneration
        let epoch = offsetPushEpoch
        offsetPushTask = Task {
            defer { if offsetPushEpoch == epoch { offsetPushTask = nil } }
            repeat {
                guard phase.isOn, generation == streamGeneration,
                      epoch == offsetPushEpoch, !Task.isCancelled else { return }
                offsetPushAgain = false
                let snapshot = sessionSpeakers().map { ($0.id, $0.offsetMs) }
                for (id, ms) in snapshot where lastSentOffset[id] != ms {
                    guard phase.isOn, generation == streamGeneration,
                          epoch == offsetPushEpoch, !Task.isCancelled else { return }
                    if let last = lastOffsetWriteAt[id], Date().timeIntervalSince(last) < 20,
                       phase == .streaming { continue }
                    lastOffsetWriteAt[id] = Date()
                    do {
                        try await api.setOffset(outputID: id, offsetMs: ms)
                        guard generation == streamGeneration, epoch == offsetPushEpoch,
                              !Task.isCancelled else { return }
                        lastSentOffset[id] = ms
                    } catch {
                        guard generation == streamGeneration, epoch == offsetPushEpoch else { return }
                        lastSentOffset[id] = nil
                    }
                }
            } while offsetPushAgain
        }
    }

    func resetOffsetCache() {
        offsetPushEpoch += 1
        offsetPushTask?.cancel(); offsetPushTask = nil; offsetPushAgain = false
        lastSentOffset.removeAll(); lastOffsetWriteAt.removeAll()
    }

    /// INSTANT CUT-OFF.
    ///
    /// The problem: when a video stops, the ~1 s already in flight keeps playing.
    /// That second lives in three places we do not control from here — our FIFO,
    /// OwnTone's input reserve, and the receivers' own buffers — and the browser
    /// extension has no way to reach any of them. It is the pipeline depth; it is
    /// the same second that BUYS the glitch-free playback, so it cannot simply be
    /// made smaller.
    ///
    /// So we do not try to recall the audio — we silence it. A volume push is one
    /// RTSP SET_PARAMETER per speaker (~10 ms on the LAN) and the receivers apply
    /// it to whatever they are about to play, including what is already buffered.
    ///
    /// WHY NOT FLUSH (pause the engine). It would genuinely discard the audio,
    /// but: OwnTone auto-starts the pipe the moment it has data, so a pause is
    /// undone within a tick unless we also stop feeding — and coming back then
    /// costs a full start-buffer refill (~700 ms of missing audio) on every
    /// un-pause. Muting keeps the stream running, so resume is instantaneous and
    /// nothing has to re-converge. The silence the tap captures while the video
    /// is paused simply flows through the pipe, and by the time you press play
    /// the pipe is delivering real audio again.
    private(set) var audioCut = false

    /// Dead-man timer. A cut is a browser telling us to silence the room, so the
    /// room must never outlive the browser: if Chrome crashes, the tab dies, the
    /// extension is disabled or the machine sleeps while a cut is armed, nothing
    /// would ever send /resume and the speakers would stay silent with no visible
    /// cause and no control in the app that explains it. So the cut EXPIRES. The
    /// extension re-arms it roughly every second for as long as the video is
    /// stopped; miss a few and we restore ourselves.
    private var cutExpiry: Task<Void, Never>?
    private static let cutHoldSec: UInt64 = 4

    /// Called from the sync beacon when the browser reports the video stopped
    /// (or started again). Idempotent, and safe to call repeatedly — a repeated
    /// `true` renews the dead-man timer without re-pushing volumes.
    /// The two independent reasons the room can be silenced. Either is enough;
    /// both must clear before sound returns.
    ///
    /// They cover different things and neither subsumes the other. The browser
    /// knows a video stopped even when its audio track was already silent, and
    /// it knows a fraction of a second earlier than the tap can. The tap knows
    /// about EVERYTHING ELSE — Spotify, Apple Music, a game, a video in an app
    /// no extension will ever see — which is most of what actually plays here.
    private var extensionCut = false
    private var silenceCut = false

    /// When the cut was armed, and whether we have stopped believing it.
    ///
    /// THE RAIL, AND THE BUG IT ANSWERS. A cut is an *assertion by the browser*
    /// that nothing is playing, and the app used to obey it unconditionally, for
    /// as long as it was re-asserted. Every way the browser can be wrong
    /// therefore ended in a silent room with a healthy stream, nothing in the UI
    /// to explain it, and no way back except pausing something:
    ///   * the extension's heartbeat bug (fixed in content.js this session):
    ///     a playing video stopped checking in, the worker aged the frame out
    ///     and cut a room that was mid-song;
    ///   * a paused YouTube tab while Spotify, Apple Music or a game plays —
    ///     the browser is telling the truth about ITSELF and is still wrong
    ///     about the room;
    ///   * any future bug in code that ships separately from this app.
    ///
    /// The fix is to make the cut falsifiable instead of trusted. A cut exists
    /// for exactly one purpose: to silence the audio ALREADY in flight when a
    /// video stops — our FIFO, OwnTone's reserve and the receivers' buffers,
    /// whose total depth is the delay we publish to the extension. That tail is
    /// finite. So if real, non-zero audio is still arriving from the tap once
    /// the cut is older than that tail, the tail theory is disproved: the Mac is
    /// making sound NOW, and muting it is simply wrong. We drop the cut and say
    /// so in the log.
    ///
    /// The override is not sticky. The moment the source genuinely goes digitally
    /// silent, the browser's claim becomes consistent with what the tap hears and
    /// the cut takes effect again — so the instant cut-off keeps working exactly
    /// as designed for the case it was built for.
    private var cutArmedAt: Date?
    private var cutOverridden = false
    private var cutDisbeliefLogged = false
    /// When the room last came back from a cut. Muting and un-muting is a
    /// volume round trip to every speaker, and the log shows scrubbing a video
    /// firing cut/restore pairs a second apart — each one a chance for the
    /// un-mute to land beside a scheduler tick and be heard as a dropout. So a
    /// fresh cut waits this long after the last restore; a real pause is still
    /// cut, just fractionally later, and a scrub is not cut at all.
    private var lastCutReleasedAt: Date?
    private static let cutCooldownSec: TimeInterval = 0.6
    /// The mute we have actually pushed to the speakers: `audioCut` filtered
    /// through the rail above. Everything that computes a volume reads this.
    private var roomMutedByCut = false
    /// Grace on top of the published delay before a cut is disbelieved.
    private static let cutCredibilityMarginSec = 1.0
    /// Digital silence this deep means the source really has stopped.
    private static let cutSilenceConfirmSec = 0.15

    /// Forget everything about the current cut. Called at both ends of a
    /// stream's life so no session can start or end wearing the last one's mute.
    private func resetCutState() {
        cutExpiry?.cancel()
        cutExpiry = nil
        applyRoomDelay()
        extensionCut = false
        silenceCut = false
        audioCut = false
        cutArmedAt = nil
        cutOverridden = false
        lastCutReleasedAt = nil
        roomMutedByCut = false
    }

    /// Called from the sync beacon (browser) — see setAudioCut.
    func setExtensionCut(_ cut: Bool) {
        if cut, !audioCut, let released = lastCutReleasedAt,
           Date().timeIntervalSince(released) < Self.cutCooldownSec {
            // The browser re-asserts a live cut about once a second, so a pause
            // that is real still gets cut on the next re-assert.
            dlog("browser cut held off — the room only just came back")
            return
        }
        extensionCut = cut
        setAudioCut(extensionCut || silenceCut, renewTimer: cut)
    }

    /// Called from CaptureController when the captured audio goes silent or
    /// comes back. No dead-man timer: this signal is generated locally and
    /// cannot be orphaned by a browser dying.
    func setSilenceCut(_ cut: Bool) {
        guard silenceCut != cut else { return }
        silenceCut = cut
        setAudioCut(extensionCut || silenceCut, renewTimer: false)
    }

    func setAudioCut(_ cut: Bool, renewTimer: Bool = true) {
        // Tear the dead-man down whenever the cut is RELEASED, whoever released
        // it. The old code only touched the timer on the arming path (callers
        // passed `renewTimer: cut`), so a /resume left a live 4 s task behind
        // whose only saving grace was that its body re-read `audioCut`.
        if !cut {
            cutExpiry?.cancel()
            cutExpiry = nil
        } else if renewTimer {
            cutExpiry?.cancel()
            cutExpiry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.cutHoldSec * 1_000_000_000)
                guard !Task.isCancelled, let self, self.audioCut else { return }
                self.dlog("audio cut expired (no refresh from the browser) — dropping the browser's request")
                self.setExtensionCut(false)
            }
        }
        if audioCut != cut {
            audioCut = cut
            if !cut { lastCutReleasedAt = Date() }
            cutArmedAt = cut ? Date() : nil
            // A browser cut is NOT believed until the tap agrees. Pausing a
            // YouTube tab while Spotify plays used to mute the whole room for
            // ~2 s (the old rail only disbelieved a cut after pipeline depth +
            // 1 s) — that was the "sound cuts out sometimes". The tap goes
            // digitally silent within a buffer of a real pause, so waiting for
            // it costs the tail cut ~150 ms and costs Spotify nothing.
            // A cut the tap itself raised (silenceCut) is believed at once.
            cutOverridden = cut && extensionCut && !silenceCut
            cutDisbeliefLogged = false
            dlog("audio \(cut ? "CUT" : "restored") (browser=\(extensionCut) silence=\(silenceCut))\(cutOverridden ? " — waiting for the tap to agree" : "")")
        }
        applyCutMute()
    }

    /// Push the room's mute state if — and only if — it actually changed.
    private func applyCutMute() {
        let muted = audioCut && !cutOverridden
        guard muted != roomMutedByCut else { return }
        roomMutedByCut = muted
        guard phase == .streaming else { return }
        // Pause/seek/play can flip this repeatedly while a volume request is
        // still waiting on AirPlay. One task per flip queued stale mute commands
        // behind newer restores. Share the slider's coalescing lane, which reads
        // the CURRENT target immediately before each write.
        // Do NOT invalidate the sent-volume cache here (forceVolumeResync did):
        // that re-sent a value the engine already held on every flip — 569
        // CUT/restore pairs in the log, each up to four redundant PUTs. The
        // target crossing zero is already treated as urgent by the push lane,
        // and a flip that reverts before the pass runs sends nothing at all.
        scheduleVolumePush()
    }

    /// The rail itself, run from the level loop (~15 Hz) while streaming. Cheap:
    /// one lock read and two comparisons unless a cut is actually armed.
    ///
    /// The invariant it buys, in one line: THE ROOM CANNOT BE SILENT FOR MORE
    /// THAN THE PIPELINE DEPTH WHILE THE MAC IS MAKING SOUND.
    func reviewCutCredibility() {
        guard audioCut, phase == .streaming else { return }
        if capture.digitalSilenceSeconds >= Self.cutSilenceConfirmSec {
            // The tap agrees with the browser. Believe the cut again (this is
            // also how a room re-mutes after an override, once whatever was
            // playing over the top of it stops).
            if cutOverridden {
                cutOverridden = false
                dlog("audio cut believed again — the source really did go silent")
                applyCutMute()
            }
            return
        }
        // Not silent. A cut that was never believed stays that way; log it
        // once so the flight record shows the browser was overruled.
        guard cutOverridden, !cutDisbeliefLogged, let armed = cutArmedAt else { return }
        let age = Date().timeIntervalSince(armed)
        guard age > 0.4 else { return }
        cutDisbeliefLogged = true
        dlog(String(format: "audio cut IGNORED: the Mac is still making sound %.1fs after the browser's cut — something else is playing", age))
        aiEvent("audio_cut_overridden", level: "info", fields: ["age_s": Int(age)])
    }

    var roomVolumePlan: RoomVolumePlan {
        RoomVolumePolicy.plan(speakers: speakers.filter {
            $0.kind != .extra || $0.enabled
                || sessionMembership.contains(name: $0.name, enabled: false, primary: false)
        }.map {
            RoomVolumeSpeaker(id: $0.id, slider: $0.relVolume, gain: $0.gain, enabled: $0.enabled)
        }, ceiling: volumeLimit, systemMaster: !playerMode && source == .system ? systemVolume : nil,
           muted: roomMutedByCut)
    }

    func effectiveVolume(_ speaker: RoomSpeaker) -> Int { roomVolumePlan.hardware[speaker.id] ?? 0 }
    private(set) var captureMasterGain = 1.0
    @ObservationIgnored private lazy var volumeController = RoomVolumeCoordinator(write: injectedVolumeWrite ?? { [api] id, value in
        switch await api.setVolumeConfirmed(outputID: id, volume: value) {
        case .applied: return .applied
        case .superseded: return .superseded
        case .unknown: return .unknown
        }
    })
    private var pushInFlight: Bool { volumeController.isWriting }
    private var lastVolumeWriteAt: Date { volumeController.lastCompletionAt }
    private var healthPollDeferrals = 0
    private var lastWriteReportAt = Date()
    private var lastWriteReportTotal = 0
    private var lastOffsetWriteAt: [String: Date] = [:]

    private func applyMasterGain() {
        let gain = roomVolumePlan.pcmGain
        captureMasterGain = gain
        if backendEnabled { capture.setMasterGain(gain) }
    }

    private func updateVolumeIntent(force: Set<String> = []) {
        applyMasterGain()
        guard backendEnabled || injectedVolumeWrite != nil else { return }
        let members = sessionSpeakers()
        let plan = roomVolumePlan
        let targets = Dictionary(members.map { ($0.id, plan.hardware[$0.id] ?? 0) },
                                 uniquingKeysWith: { a, _ in a })
        let eligible = Set(members.filter {
            phase == .streaming && (!$0.enabled || $0.health == .live)
                && !speakerRecoveryInFlight.contains($0.id)
        }.map(\.id))
        volumeController.update(session: streamGeneration, active: phase.isOn,
                                targets: targets, eligible: eligible,
                                urgent: targets.values.contains(0), force: force)
    }

    private func silenceOutput(_ id: String) async throws {
        let generation = streamGeneration
        updateVolumeIntent()
        guard await volumeController.silence(id, session: generation) else {
            throw BeamAPIError(what: "Speaker silence was not accepted by the engine")
        }
    }

    private func restoreOutput(_ id: String) async throws {
        let generation = streamGeneration
        updateVolumeIntent()
        guard await volumeController.restore(id, session: generation) else {
            throw BeamAPIError(what: "Speaker volume was not accepted by the engine")
        }
    }

    private func reportEngineWrites() {
        let now = Date()
        guard now.timeIntervalSince(lastWriteReportAt) >= 60 else { return }
        let total = api.totalWrites
        let count = total - lastWriteReportTotal
        engineWritesPerMin = Double(count) / max(now.timeIntervalSince(lastWriteReportAt) / 60, 0.001)
        lastWriteReportTotal = total; lastWriteReportAt = now
        aiEvent("engine_writes", fields: ["per_min": engineWritesPerMin,
                                           "counts": api.recentWrites(window: 60)])
    }

    /// Engine writes per minute over the last report window (0 until first report).
    /// Public so the flight-recorder line can append it: `w/min=\(engineWritesPerMin)`.
    private(set) var engineWritesPerMin: Double = 0

    private var troubleStrikes: [String: Int] = [:]
    /// Resume attempts in a row that did not bring the room back. Drives a
    /// cool-off between resumes and, past a limit, a visible error — an engine
    /// that answers but never plays used to be re-resumed (muted, re-selected,
    /// faded) every ~15 s forever.
    private var resumeFailStreak = 0
    private var resumeCooldownUntil = Date.distantPast
    /// Times the engine was force-killed recently; see forceRespawn's budget.
    private var respawnTimes: [Date] = []
    private var speakerRecoveryInFlight: Set<String> = []
    /// A ProcessTap can report a successful start while its Core Audio callback
    /// remains silent. Allow one tap rebuild, then escalate once to a clean room
    /// restart if callbacks still do not return. This prevents endless retries.
    private var captureWatchdogInFlight = false
    private var rememberedNamesCache: Set<String> = []
    private var rememberedNamesAt = Date.distantPast
    private var captureStallRestartUsed = false
    /// After a failed hard rejoin, back off before trying again — endless
    /// deselect/select every poll is what thrash-kills AirPlay 2 sessions.
    private var recoveryCooldownUntil: [String: Date] = [:]
    private var recoveryFailCounts: [String: Int] = [:]
    private var notPlayStrikes = 0
    private var apiDeadStrikes = 0      // consecutive health polls where OwnTone's API didn't answer (wedge detector)
    private var apiDeadSince: Date?      // first failed poll of the current dead-API run
    /// Last time DALI itself drove a speaker deselect/select or a full resume.
    /// OwnTone's API blocks on the RTSP handshake those commands start.
    private var lastRecoveryActivityAt = Date.distantPast
    private var lastProgressMs: Int?     // OwnTone playback clock at the previous health poll
    private var progressStallStrikes = 0 // consecutive polls where the clock did NOT advance while we intend to play
    /// Consecutive STREAMING-ready polls before leaving `.trouble`/`.connecting`.
    private var readyStrikes: [String: Int] = [:]

    /// A selected output is only requested, not necessarily alive. Newer DALI
    /// engines expose the backend session state; the fallback keeps development
    /// builds using an older engine functional until it is replaced.
    private func outputIsReady(_ output: Output?) -> Bool {
        output?.isSessionReady ?? false
    }

    /// Returns the ids that did not become genuinely ready before the deadline.
    private func awaitOutputsReady(ids: Set<String>, timeoutMs: Int, failFast: Bool = false) async -> Set<String> {
        let client = api
        return await OutputReadiness.missing(ids: ids, timeout: .milliseconds(timeoutMs),
                                             failFastAfter: failFast ? .milliseconds(1_500) : nil) {
            try await client.outputs()
        }
    }

    /// Hard-cycle one dead-but-still-selected output. Re-sending selected=true
    /// is a no-op in OwnTone, which is why the old auto-rejoin never fixed this
    /// failure. The healthy partner is left untouched and the recovered speaker
    /// is faded back in quietly after its backend says connected/streaming.
    private func streamIsCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && phase == .streaming && generation == streamGeneration
    }

    private func recoverSpeaker(_ sp: RoomSpeaker) async {
        let generation = streamGeneration
        guard sp.available, streamIsCurrent(generation), !speakerRecoveryInFlight.contains(sp.id) else { return }
        if let until = recoveryCooldownUntil[sp.id], until > Date() { return }
        let fails = recoveryFailCounts[sp.id] ?? 0
        // Never give up for good: a speaker abandoned after a few failures stayed
        // silent until the user restarted the stream. Failures back off instead
        // (20 s, 60 s, then every 5 min) so a dead speaker cannot thrash the engine.
        speakerRecoveryInFlight.insert(sp.id)
        lastRecoveryActivityAt = Date()
        defer {
            // Stamp the END too: the engine API stalls on the RTSP handshake
            // this deselect/select started (see noteEngineAPIFailure).
            lastRecoveryActivityAt = Date()
            if generation == streamGeneration { speakerRecoveryInFlight.remove(sp.id) }
        }
        speakers.indices.filter { speakers[$0].id == sp.id }.forEach { speakers[$0].health = .connecting }
        // Silence first so a mid-rejoin device never blasts at its own default.
        try? await silenceOutput(sp.id)
        guard streamIsCurrent(generation) else { return }
        // GENTLE FIRST. Re-asserting the whole output list keeps the shared
        // AirPlay 2 session (a per-member deselect can take the PARTNER down
        // with it: the "it plays one or the other" failure). Only after two
        // gentle failures is this one member hard-cycled, and then both are
        // re-added together.
        let sessionIDs = sessionSpeakers().filter(\.available).map(\.id)
        if fails < 2 {
            try? await api.setOutputs(ids: sessionIDs)
        } else {
            dlog("\(sp.name) gentle re-assert failed \(fails)x -> per-member rejoin")
            try? await api.setSelected(outputID: sp.id, selected: false)
            guard streamIsCurrent(generation) else { return }
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard streamIsCurrent(generation) else { return }
            try? await api.setOutputs(ids: sessionIDs)
        }
        guard streamIsCurrent(generation) else { return }
        let missing = await awaitOutputsReady(ids: Set([sp.id]), timeoutMs: 8_000)
        guard streamIsCurrent(generation) else { return }
        guard missing.isEmpty else {
            speakers.indices.filter { speakers[$0].id == sp.id }.forEach { speakers[$0].health = .trouble }
            let nextFails = fails + 1
            recoveryFailCounts[sp.id] = nextFails
            // Back off harder each failure so we don't thrash-kill the partner.
            let cooldown: TimeInterval = nextFails >= 5 ? 300 : nextFails >= 3 ? 60 : nextFails == 1 ? 10 : 20
            recoveryCooldownUntil[sp.id] = Date().addingTimeInterval(cooldown)
            aiEvent("speaker_rejoin_failed", level: "error", fields: [
                "speaker": sp.name, "fails": nextFails, "cooldown_s": Int(cooldown)
            ])
            dlog("\(sp.name) rejoin failed (x\(nextFails)); cooldown \(Int(cooldown))s")
            return
        }
        // Restore the bounded target with one command. Multi-step fades were a
        // command storm and one ignored receiver reply can block OwnTone's
        // global command lane.
        try? await silenceOutput(sp.id)
        guard streamIsCurrent(generation) else { return }
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard streamIsCurrent(generation),
              let current = speakers.first(where: { $0.id == sp.id }) else { return }
        let target = min(effectiveVolume(current), Int(volumeLimit.rounded()))
        do {
            try await restoreOutput(sp.id)
            guard streamIsCurrent(generation) else { return }
        } catch {
            guard streamIsCurrent(generation) else { return }
            dlog("\(sp.name) setVolume(\(target)) failed after rejoin: \(error)")
        }
        troubleStrikes[sp.id] = 0
        readyStrikes[sp.id] = 2
        recoveryFailCounts[sp.id] = 0
        recoveryCooldownUntil[sp.id] = nil
        speakers.indices.filter { speakers[$0].id == sp.id }.forEach {
            speakers[$0].health = speakers[$0].enabled ? .live : .off
        }
        aiEvent("speaker_rejoin_ok", fields: ["speaker": sp.name])
        dlog("\(sp.name) rejoin succeeded")
        speakerRecoveryInFlight.remove(sp.id)
        // Mac/slider may have moved while we owned volume during recovery.
        guard let latest = speakers.first(where: { $0.id == sp.id }) else { return }
        _ = latest
        scheduleVolumePush()
    }


    private func forceVolumeResync(ids: [String]? = nil) {
        updateVolumeIntent(force: Set(ids ?? sessionSpeakers().map(\.id)))
    }

    private func cancelVolumePush() { volumeController.stop(session: streamGeneration) }
    private func scheduleVolumePush() { updateVolumeIntent() }

    private var fading = false

    /// Release setup/recovery silence only after readiness, using current intent.
    private func fadeIn() async {
        let generation = streamGeneration
        fading = true
        defer { if generation == streamGeneration { fading = false; scheduleVolumePush() } }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        for id in sessionSpeakers().map(\.id) {
            guard streamIsCurrent(generation) else { return }
            guard speakers.first(where: { $0.id == id })?.health != .trouble else { continue }
            try? await restoreOutput(id)
        }
    }

    /// Re-establish playback after the devices ended the session on their own.
    /// Re-selects every enabled output, re-plays the pipe, and re-pushes volumes
    /// TWICE (once now, once after the session settles) so a device that rejoins
    /// at its own default volume gets corrected instead of sitting quiet.
    /// One resume at a time. A flapping network path used to launch a second
    /// full resume while the first was still muting and re-selecting outputs;
    /// the two fought over the engine until its API hung and it was respawned
    /// (the "engine resets" seen 2026-09-22 21:27, eleven path flips in 60 s).
    private var resumeInFlight = false

    private func resumePlaybackOnce(reason: String) async {
        guard !resumeInFlight else {
            dlog("resume (\(reason)) skipped: one already in flight")
            return
        }
        resumeInFlight = true
        lastRecoveryActivityAt = Date()
        defer { resumeInFlight = false; lastRecoveryActivityAt = Date() }
        await resumePlayback()
    }

    private func resumePlayback() async {
        let generation = streamGeneration
        guard streamIsCurrent(generation) else { return }
        let ids = sessionSpeakers().map(\.id)
        guard !ids.isEmpty else { return }
        // Replaying the pipe resets item_progress_ms to ~0. Without re-anchoring,
        // the fill diagnostic computes rendered-bytes from a stale anchor and
        // reads absurd values for the rest of the session — exactly the numbers
        // we need trustworthy when diagnosing whatever caused this resume.
        resetDriftAnchors()
        markHealth(of: ids, .connecting)
        try? await api.setOutputs(ids: ids)
        guard streamIsCurrent(generation) else { return }
        if playerMode {
            // Player model: the queue is intact; just resume it. Never clear/replay.
            try? await api.play()
        } else {
            var uri = (try? await api.pipeTrackURI(named: "beam.pipe")) ?? nil
            if uri == nil {
                // A freshly spawned engine has not indexed the pipe yet. Without
                // this the resume did nothing, reported "did NOT reach play
                // state", and the health loop re-ran the whole mute/reselect
                // cycle every few seconds until autostart happened to win.
                guard streamIsCurrent(generation) else { return }
                try? await api.rescan()
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard streamIsCurrent(generation) else { return }
                    if let u = (try? await api.pipeTrackURI(named: "beam.pipe")) ?? nil { uri = u; break }
                }
            }
            guard streamIsCurrent(generation) else { return }
            if let uri { try? await api.playPipe(uri: uri) }
        }
        guard streamIsCurrent(generation) else { return }
        // Silence first, settle, then FADE IN (the old double pushVolumes landed
        // as a loud jump mid-session whenever a rejoined device came back at its
        // own default volume and ignored the pre-session volume set). Only the
        // session's own outputs: an enabled-but-unavailable speaker has a
        // placeholder id the engine has never heard of.
        for id in ids {
            guard streamIsCurrent(generation) else { return }
            try? await silenceOutput(id)
        }
        guard streamIsCurrent(generation) else { return }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard streamIsCurrent(generation) else { return }
        var missing = await awaitOutputsReady(ids: Set(ids), timeoutMs: 8_000)
        guard streamIsCurrent(generation) else { return }
        if !missing.isEmpty {
            for sp in sessionSpeakers() where missing.contains(sp.id) {
                await recoverSpeaker(sp)
                guard streamIsCurrent(generation) else { return }
            }
            missing = await awaitOutputsReady(ids: Set(ids), timeoutMs: 3_000)
        }
        guard streamIsCurrent(generation) else { return }
        guard missing.isEmpty else {
            let names = sessionSpeakers().filter { missing.contains($0.id) }.map(\.name).joined(separator: ", ")
            dlog("resume incomplete; not all speakers streaming: \(names)")
            aiEvent("resume_incomplete", level: "error", fields: ["speakers": names])
            // Keep phase streaming (pipe may still be up) but surface the dead
            // outputs so chrome stops claiming LIVE / healthy.
            markHealth(of: Array(missing), .trouble)
            for id in missing { readyStrikes[id] = 0 }
            // A dead speaker beside a playing engine is recoverSpeaker's job and
            // must not count as a failed resume; a silent engine must.
            let enginePlaying = (try? await api.playerState())?.state == "play"
            guard streamIsCurrent(generation) else { return }
            noteResumeOutcome(ok: enginePlaying)
            return
        }
        await fadeIn()
        guard streamIsCurrent(generation) else { return }
        let st = try? await api.playerState()
        guard streamIsCurrent(generation) else { return }
        if st?.state == "play" {
            markHealth(of: ids, .live)
            for id in ids { readyStrikes[id] = 2; troubleStrikes[id] = 0 }
            dlog("resume succeeded, volumes faded in")
            noteResumeOutcome(ok: true)
        } else {
            dlog("resume did NOT reach play state")
            markHealth(of: ids, .connecting)
            noteResumeOutcome(ok: false)
        }
    }

    /// Bookkeeping for the resume back-off. The health loop only starts another
    /// resume once `resumeCooldownUntil` has passed, and after five failures in
    /// a row it stops trying and says so — the alternative was an endless
    /// mute/re-select/fade cycle against an engine that cannot play.
    private func noteResumeOutcome(ok: Bool) {
        if ok {
            resumeFailStreak = 0
            resumeCooldownUntil = .distantPast
            return
        }
        resumeFailStreak += 1
        let cooldown = min(Double(resumeFailStreak) * 10, 60)
        resumeCooldownUntil = Date().addingTimeInterval(cooldown)
        dlog("resume failed x\(resumeFailStreak); next automatic attempt in \(Int(cooldown))s")
        if resumeFailStreak >= 5 {
            abortWithError("The room stopped playing and could not be restored. Press Play to retry.",
                           event: "resume_gave_up")
        }
    }

    /// Stop everything and surface a retry state. Used when automatic recovery
    /// has demonstrably not worked, instead of cycling forever.
    private func abortWithError(_ message: String, event: String) {
        dlog("giving up: \(message)")
        aiEvent(event, level: "error", fields: ["message": message])
        if playerMode { stopPlayback() } else { stopStream() }
        phase = .error(message)
    }

    // MARK: wedge recovery

    private func resetDriftAnchors() {
        timingController.reset()
        capture.setTargetRatio(1)
    }

    /// Force the wedged engine to be replaced and wait for it to come back. Used
    /// for BOTH wedge kinds: a dead HTTP API, and a frozen playback clock while the
    /// API still answers. Clears every strike counter and re-anchors the controller
    /// so the recovered stream starts clean. The long wait covers the supervisor's
    /// SIGTERM grace plus the up-to-10s engine relaunch, so the loop does not kill a
    /// child that is still in the middle of starting.
    private func forceRespawn(_ reason: String) async {
        // Budget. The supervisor parks a persistently wedging engine in .failed,
        // but forceRespawn's own fallback below restarts it from .failed, so
        // between them an engine that wedges every minute was killed and
        // relaunched forever with nothing on screen. Four in ten minutes is a
        // broken engine, not a transient: say so and stop.
        let now = Date()
        respawnTimes = respawnTimes.filter { now.timeIntervalSince($0) < 600 }
        guard respawnTimes.count < 4 else {
            abortWithError("The audio engine keeps freezing. Press Play to retry.",
                           event: "engine_respawn_gave_up")
            return
        }
        respawnTimes.append(now)
        dlog("force respawn: \(reason)")
        aiEvent("engine_respawn", level: "error", fields: ["reason": reason])
        apiDeadStrikes = 0; apiDeadSince = nil; notPlayStrikes = 0
        progressStallStrikes = 0; lastProgressMs = nil
        resetDriftAnchors()
        markHealth(of: speakers.filter(\.enabled).map(\.id), .connecting)
        let generation = streamGeneration
        // The store re-plays the session itself once the engine is back. With
        // the supervisor's own resume left on, BOTH fired pipeTrackURI +
        // playPipe (queue clear + play) at a just-spawned engine within the same
        // second — an overlapping burst at the moment it is least able to take
        // one. Hand the flag back afterwards.
        let resumeFlag = await supervisor.resumePlaybackOnRestart
        await supervisor.setResumePlayback(false)
        await supervisor.killForRespawn()
        // Poll for the replacement instead of a blind 8 s sleep + 2 s steps.
        // killForRespawn waits for process exit and transport drain, so the old engine no longer
        // answers; "running AND the API answers" can only be the new child. The
        // 1 s floor lets handleDeath observe the exit before we read `state`.
        // The 30 s ceiling covers the supervisor's PTP-port wait (≤12 s) plus
        // its API-up poll (≤10 s), so we still never kill a child mid-start.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let deadline = Date().addingTimeInterval(30)
        var engineBack = false
        while Date() < deadline, streamIsCurrent(generation) {
            let s = await supervisor.state
            if s == .running, await api.isUp() { engineBack = true; break }
            // killForRespawn assumes the crash path auto-recovers — but if the
            // death budget (3 crashes/60s) was just exhausted, the supervisor is
            // parked in .failed with no auto-retry.
            // `resettingBudgets: false` — see EngineSupervisor.restart(). This is
            // an AUTOMATIC recovery attempt, not the user asking for a clean
            // slate; resetting the wedge/crash budgets here is what let a
            // persistently-wedging engine loop kill->respawn->wedge forever,
            // each cycle getting a fresh breaker.
            if case .failed = s {
                try? await supervisor.restart(resettingBudgets: false)
                engineBack = await supervisor.state == .running
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // A fresh engine has no AirPlay sessions: every respawn in the log was
        // followed by "PLAYER=pause speakerOFF" until the health loop's 3-strike
        // rejoin fired 13-19 s later (2026-09-22 00:43:52->00:44:08,
        // 02:14:03->02:14:20, 02:16:20->02:16:39, 02:21:53->02:22:06), and the
        // rejoin itself then took 1-3 s. Rebuild the session now instead.
        if generation == streamGeneration { await supervisor.setResumePlayback(resumeFlag) }
        guard engineBack, streamIsCurrent(generation) else { return }
        dlog("engine back after respawn -> resuming session")
        // Output ids belong to the engine that issued them; re-read them from
        // the new one before re-selecting, and re-assert the trim it forgot.
        await refreshSpeakers()
        guard streamIsCurrent(generation) else { return }
        resetOffsetCache()
        enforceZeroOffsets(force: true)
        resumeFailStreak = 0; resumeCooldownUntil = .distantPast
        await resumePlaybackOnce(reason: "engine respawned")
    }

    // MARK: health loop (websocket-lite: poll while streaming)

    /// Count failures from either half of the health snapshot. Previously only
    /// /api/outputs failures counted, so repeated /api/player timeouts could hold
    /// the engine for long enough to overflow the FIFO while a later outputs call
    /// happened to clear the strike counter.
    private func noteEngineAPIFailure(_ endpoint: String) async {
        apiDeadStrikes += 1
        dlog("\(endpoint) query failed (\(apiDeadStrikes)) -> engine unreachable")
        if apiDeadStrikes == 1 {
            aiEvent("engine_api_unreachable", level: "warn", fields: [
                "strike": apiDeadStrikes, "endpoint": endpoint,
            ])
        }
        markHealth(of: speakers.filter(\.enabled).map(\.id), .connecting)
        let now = Date()
        if apiDeadSince == nil { apiDeadSince = now }
        let deadFor = now.timeIntervalSince(apiDeadSince ?? now)
        // Right after a network change the engine's loopback API stalls for a
        // few seconds while it tears down RTSP sessions. That is not a dead
        // engine; respawning it then is what turned a blip into a reset.
        //
        // The same stall follows DALI's OWN speaker rejoins/resumes: OwnTone's
        // command lane blocks on the RTSP handshake to the device being
        // re-selected. Log evidence (dali-debug.log 2026-09-22 02:14-02:25): the
        // 02:16:20 respawn fired 10 s after "MICHAEL S hard rejoin succeeded"
        // and threw that recovered session away.
        let settling = now.timeIntervalSince(lastNetworkChangeAt) < 20
            || now.timeIntervalSince(lastRecoveryActivityAt) < 20
            || resumeInFlight || !speakerRecoveryInFlight.isEmpty
        // Strike count alone (2 polls ≈ 5-7 s) is shorter than the ~15 s an
        // ignored RTSP reply holds OwnTone's command lane. Measured in the flight
        // anomalies: 21 API-hang episodes of 5-34 s cleared on their own with no
        // respawn, while all 6 respawns came 5-10 s after a speaker session died
        // (speakerOFF), a network flip, or our own rejoin — and 3 of them hit the
        // same hang again within a minute. The kill cured nothing and added an
        // engine restart (plus FIFO drops) to every speaker blip.
        // Require the API to stay dead past that window before killing it.
        //
        // The window is 45 s (60 s while settling), not 16/25: the measured
        // stalls reach 34 s, so anything shorter can still SIGKILL an engine
        // that was about to answer — and killing OwnTone while it is blocked on
        // an RTSP reply is itself the crash trigger. Only an engine silent past
        // the longest stall it has ever survived is treated as frozen.
        let needStrikes = settling ? 4 : 3
        let needDeadSec: TimeInterval = settling ? 60 : 45
        if apiDeadStrikes >= needStrikes, deadFor >= needDeadSec {
            await forceRespawn(String(format: "HTTP API dead x%d over %.0fs (last: %@) while process alive",
                                      apiDeadStrikes, deadFor, endpoint))
        }
    }

    private func startHealthLoop() {
        healthTask?.cancel()
        apiDeadStrikes = 0; apiDeadSince = nil; notPlayStrikes = 0
        progressStallStrikes = 0; lastProgressMs = nil
        readyStrikes.removeAll()
        troubleStrikes.removeAll()
        speakerRecoveryInFlight.removeAll()
        recoveryCooldownUntil.removeAll()
        recoveryFailCounts.removeAll()
        // Stale echo entries from a previous session would suppress the first
        // volume reconciliation of this one (review finding L6).
        healthPollDeferrals = 0
        lastWriteReportAt = Date(); lastWriteReportTotal = api.totalWrites
        resumeFailStreak = 0; resumeCooldownUntil = .distantPast
        healthTask = Task {
            while !Task.isCancelled && phase == .streaming {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // A cancelled sleep returns at once. Without the isCancelled
                // check a REPLACED loop ran one more pass, its cancelled API
                // calls all "failed", and those strikes landed on the new loop's
                // counters.
                guard !Task.isCancelled, phase == .streaming else { break }
                // If the single-app source quit, fall back to all system audio.
                if case .app(let pid, _) = source, kill(pid, 0) != 0 {
                    dlog("source app pid \(pid) gone -> All audio")
                    source = .system
                }

                // TAP WATCHDOG. Only rebuild when buffers STOP arriving entirely
                // — the
                //    anchor device was unplugged, or a rebuild's tap.start()
                //    silently failed (it is try?). The canary is blind to this
                //    (it counts arrivals), so check wall-clock starvation too.
                //    Re-fires every poll until buffers flow again, which also
                //    retries a failed rebuild.
                //
                // Do NOT rebuild for all-zero buffers. Zero samples are
                // indistinguishable from a legitimate pause/silent source. Even
                // the former four-minute threshold fired during real use at
                // 17:55:23 on 2026-08-02, creating a 242ms capture gap and a
                // measured 218ms sync jump on both speakers — the reported echo.
                // A speculative recovery must not manufacture the audible fault.
                let starvedSec = capture.secondsSinceLastBuffer
                if capture.isRunning && starvedSec <= 1 {
                    // A real callback proves the capture path has recovered.
                    captureStallRestartUsed = false
                }
                if capture.isRunning && starvedSec > 10 && !captureWatchdogInFlight {
                    dlog(String(format: "tap: no buffers for %.0fs -> rebuilding tap", starvedSec))
                    aiEvent("capture_no_buffers", level: "warn", fields: ["seconds": Int(starvedSec)])
                    rebuildStarvedCapture(expectedGeneration: streamGeneration)
                }

                // Do NOT rebuild the tap for all-zero buffers. Quiet passages and
                // paused sources deliver digital zeros while the tap is healthy;
                // rebuilding spliced a measured ~300ms capture gap into live audio
                // (tonight: captureGap296–302ms). The no-buffers watchdog above
                // already recovers a truly dead tap.

                // RECOVERY FROM A FULL STOP: when the player is not playing while
                // we intend to stream, re-play the pipe. Require TWO consecutive
                // non-play polls (~6s) first: a single transient read mid-playback
                // must not trigger the disruptive queue-clear+replay (that itself
                // caused a stutter every few minutes).
                // A resume started elsewhere (network settle) owns the engine
                // while it runs: it deliberately mutes, re-selects and re-plays,
                // so polling now only manufactures "not playing" / "speaker
                // down" strikes against work that is already in progress.
                if resumeInFlight { continue }
                reportEngineWrites()
                // Do not stack read polls on top of a volume write (in flight,
                // waiting out its spacing window, or finished < 2 s ago): the
                // GETs share OwnTone's single HTTP/command thread with the
                // RTSP SET_PARAMETER, and a poll answered mid-write is also a
                // stale reading (it produced the "drift engine=18 want=0"
                // resends). Bounded: at most two ticks (~6 s) are skipped in a
                // row so wedge detection is delayed, never disabled.
                if (pushInFlight || Date().timeIntervalSince(lastVolumeWriteAt) < 2),
                   healthPollDeferrals < 2 {
                    healthPollDeferrals += 1
                    continue
                }
                healthPollDeferrals = 0
                // What each speaker SHOULD be at when this poll goes out; a
                // reading is only evidence of drift if that did not move
                // while the request was in flight.
                let volumeToken = volumeController.observationToken
                guard let st = try? await api.playerState() else {
                    guard !Task.isCancelled else { break }
                    await noteEngineAPIFailure("player")
                    continue
                }
                // In player mode a pause is intentional and must NOT be
                // "recovered" from. Only auto-resume when we mean to be playing.
                let intendPlaying = !playerMode || isPlaying
                if st.state != "play" && intendPlaying {
                    notPlayStrikes += 1
                    progressStallStrikes = 0; lastProgressMs = nil
                    // resumeCooldownUntil spaces out attempts after a resume that
                    // did not bring the room back (see noteResumeOutcome).
                    if notPlayStrikes >= 2, Date() >= resumeCooldownUntil {
                        notPlayStrikes = 0
                        dlog("player '\(st.state)' x2 while streaming -> resuming")
                        await resumePlaybackOnce(reason: "player not playing")
                        continue
                    }
                } else {
                    notPlayStrikes = 0
                    // FROZEN-CLOCK WEDGE: the process is alive and the API still
                    // answers "play", but item_progress_ms stops advancing. This
                    // is the real "weird noises then it slowly cuts out and dies"
                    // failure, and the dead-API detector below never catches it
                    // because the HTTP API keeps replying. FOUR polls (~12s) with
                    // zero clock advance while we intend to play means the engine
                    // is wedged: respawn it. (Was 2 polls/~6s — but a deep
                    // rebuffer also freezes the clock legitimately for several
                    // seconds, and respawning mid-rebuffer turned a 2s recovery
                    // into an 8s+ full dropout.)
                    if intendPlaying, st.state == "play", let p = st.item_progress_ms {
                        if let last = lastProgressMs, p <= last {
                            progressStallStrikes += 1
                        } else {
                            progressStallStrikes = 0
                        }
                        lastProgressMs = p
                        if progressStallStrikes >= 4 {
                            await forceRespawn("playback clock frozen at \(p)ms (no advance x4 ~12s) while playing")
                            continue
                        }
                    } else {
                        progressStallStrikes = 0; lastProgressMs = nil
                    }
                }
                guard let outs = try? await api.outputs() else {
                    // OwnTone's HTTP API didn't answer. The supervisor's crash
                    // watchdog only fires if the PROCESS exits — but the real
                    // failure is a WEDGE (process alive, API frozen, "weird noises
                    // then everything dies"). Detect it here: after 2 dead polls
                    // (~6s) force a respawn so the user never restarts by hand.
                    guard !Task.isCancelled else { break }
                    await noteEngineAPIFailure("outputs")
                    continue
                }
                // Stopped or replaced while the request was out: this snapshot
                // belongs to a session that no longer exists.
                guard !Task.isCancelled, phase == .streaming else { break }
                apiDeadStrikes = 0; apiDeadSince = nil
                applyDiscoveredSpeakers(outs)

                for i in speakers.indices where speakers[i].enabled {
                    guard speakers[i].available else { continue }
                    let id = speakers[i].id
                    let ok = outputIsReady(outs.first(where: { $0.id == id }))
                    if ok {
                        troubleStrikes[id] = 0
                        let ready = (readyStrikes[id] ?? 0) + 1
                        readyStrikes[id] = ready
                        // One CONNECTED/STREAMING flicker must not clear `.trouble` or
                        // abort recovery — require two consecutive ready polls
                        // (~6s) before declaring audible again.
                        // connected-but-not-streaming is ready (outputIsReady).
                        let wasDown = speakers[i].health == .trouble
                            || speakers[i].health == .connecting
                        if wasDown {
                            if ready >= 2 {
                                speakers[i].health = .live
                                // Volume pushes were skipped while non-live. Force
                                // exact want now — reconcile's ±12 dead-zone would
                                // leave small Mac-key changes stuck on the front.
                                forceVolumeResync(ids: [id])
                            }
                        } else if speakers[i].health != .live {
                            speakers[i].health = .live
                        }
                    } else {
                        readyStrikes[id] = 0
                        // First miss: stay `.live` so Mac/slider volume still
                        // reaches the speaker through a one-poll mDNS flicker.
                        // Second miss (~6s) → connecting. Third (~9s) → hard rejoin.
                        // Dropping to connecting on strike 1 was why the front
                        // "ignored" volume while the Sonos kept tracking.
                        let strikes = (troubleStrikes[id] ?? 0) + 1
                        troubleStrikes[id] = strikes
                        // Two consecutive misses (~6 s) = this speaker is down while
                        // its partner may be playing: show it (.trouble) and start
                        // the gentle rejoin. The rejoin never deselects the partner.
                        if strikes >= 2 {
                            if speakers[i].health != .trouble {
                                // Context for the next dropout: both speakers going at
                                // once (and a path change just before) means the Mac or
                                // engine stalled, not the speaker.
                                let others = speakers.filter { $0.id != id && $0.enabled && $0.health != .live }.map(\.name)
                                let netAge = Int(Date().timeIntervalSince(lastNetworkChangeAt))
                                dlog("\(speakers[i].name) dropped (2 strikes, ~6 s) -> rejoining gently [also down: \(others.isEmpty ? "none" : others.joined(separator: ",")); path ok=\(pathSatisfied) last change \(netAge)s ago]")
                                aiEvent("speaker_rejoin", level: "warn", fields: ["speaker": speakers[i].name, "also_down": others.joined(separator: ","), "path_ok": "\(pathSatisfied)"])
                            }
                            speakers[i].health = .trouble
                        }
                    }
                }
                // Auto-rejoin only the troubled output. Cooldown + fail cap inside
                // recoverSpeaker prevent endless deselect thrash.
                // Not while a full resume (network settle / post-respawn) is
                // running: it owns re-selection and rejoins its own missing
                // outputs. Both at once deselected a speaker mid-resume
                // (2026-09-22 20:42:44-20:43:01: two 3-strike rejoins interleaved
                // with a resume that ended "resume did NOT reach play state").
                for sp in speakers where sp.enabled && sp.health == .trouble && !resumeInFlight {
                    // The loop iterates a snapshot and each rejoin takes many
                    // seconds; the next speaker may have healed (or the stream
                    // ended) in the meantime.
                    guard !Task.isCancelled, phase == .streaming,
                          speakers.first(where: { $0.id == sp.id })?.health == .trouble else { continue }
                    await recoverSpeaker(sp)
                }
                updateVolumeIntent()
                volumeController.observe(Dictionary(outs.map { ($0.id, $0.volume) },
                                                    uniquingKeysWith: { a, _ in a }), token: volumeToken)

            }
        }
    }

    /// Slow guard while idle: keeps engine and app state honest.
    private func startIdleGuard() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self else { return }
                guard !self.phase.isOn else { continue }
                // reconcileEngineState() only checked the phase BEFORE its
                // requests, so a stream started while the poll was out got its
                // freshly-begun playback stopped by the answer. Re-check after
                // every await, right before the stop.
                guard let st = try? await self.api.playerState(), st.state == "play",
                      !self.phase.isOn, !self.startingPlayback else { continue }
                self.dlog("idle guard: engine is playing while DALI is idle -> stopping it")
                try? await self.api.stop()
            }
        }
    }

    // MARK: sleep/wake

    /// Quitting must take the engine with it. The app delegate's SIGTERM alone
    /// is not enough: OwnTone can hang forever in its PTP teardown, and that
    /// orphan keeps UDP 319/320 and a speaker session (see
    /// EngineSupervisor.reapEngines). Posted synchronously on the main thread
    /// before exit, so blocking up to ~3 s here is the whole point.
    private func reapEngineOnQuit(confPath: String) {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { _ in
            EngineSupervisor.reapEngines(matchingConfig: confPath, graceSeconds: 3.0)
        }
    }

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // `.starting` counts: a start still connecting when the lid
                // closes would otherwise run on into the sleep and land as an
                // error (or a half-built session) on wake.
                guard let self, self.phase.isOn else { return }
                self.wasStreamingBeforeSleep = true
                if self.playerMode { self.stopPlayback() } else { self.stopStream() }
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wasStreamingBeforeSleep else { return }
                self.wasStreamingBeforeSleep = false
                // Wait for the network to actually come back rather than
                // guessing 3s — Wi-Fi after a lid-open regularly takes longer,
                // and starting early just fails discovery and shows an error.
                await self.awaitNetwork()
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // let mDNS settle
                // Player mode has no capture stream to restart; starting one
                // here would begin mirroring the Mac under a player-mode UI.
                guard !self.playerMode else { return }
                self.startStream(reason: "wake")
            }
        }
    }
    private var wasStreamingBeforeSleep = false

    // MARK: network resilience
    //
    // The failure nobody instruments: Wi-Fi drops for two seconds, or the Mac
    // roams to another access point, or the router reboots. Every AirPlay RTSP
    // session dies and the mDNS view goes stale, but the app looks fine — it
    // only finds out via the health loop's strike counters, which take 6s+ per
    // strike and often just sit in "trouble" because re-selecting a device
    // whose session died on a since-changed network doesn't work. Watching the
    // path directly turns a 30s+ limp into an immediate, deliberate recovery.
    private var pathMonitor: NWPathMonitor?
    private var pathSatisfied = true

    /// Publishes stream state + measured audio delay on loopback so the
    /// browser extension can auto-match video without the user guessing.
    let syncBeacon = SyncBeacon()

    private var lastNetworkChangeAt = Date.distantPast
    private var networkSettleTask: Task<Void, Never>?

    private func observeNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor in
                guard let self else { return }
                let wasSatisfied = self.pathSatisfied
                self.pathSatisfied = satisfied
                guard satisfied != wasSatisfied else { return }
                self.lastNetworkChangeAt = Date()
                guard self.phase == .streaming else { return }

                if !satisfied {
                    // Don't touch the session yet: most losses are a one- or
                    // two-second blip (roaming, VPN interface churn) and the
                    // AirPlay sessions ride straight through them.
                    // Never cancel a resume that is already mid-flight: it has
                    // muted the room and would bail before fading back in.
                    if !self.resumeInFlight { self.networkSettleTask?.cancel() }
                    self.dlog("network path lost while streaming")
                    self.aiEvent("network_lost", level: "warn")
                } else {
                    self.dlog("network path restored; settling before any recovery")
                    self.aiEvent("network_restored")
                    self.scheduleNetworkRecovery()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dali.network", qos: .utility))
        pathMonitor = monitor
    }

    /// Wait for the path to hold for 3 s, then check whether anything is
    /// actually broken before rebuilding. The old handler re-discovered and
    /// re-played on every flip — muting the room each time, even when both
    /// speakers were still playing.
    private func scheduleNetworkRecovery() {
        // A resume already running re-selects everything itself; cancelling it
        // for a fresh settle timer would leave the room muted mid-cycle.
        guard !resumeInFlight else {
            dlog("network restored; a resume is already running")
            return
        }
        networkSettleTask?.cancel()
        let generation = streamGeneration
        networkSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.pathSatisfied,
                  self.streamIsCurrent(generation) else { return }
            let ids = self.sessionSpeakers().map(\.id)
            // An unanswered poll is "unknown", not "not playing": right after a
            // path change the engine's API stalls while it tears RTSP sessions
            // down, and resuming into that stall is the reset the health loop's
            // own wedge logic exists to judge (it has the patience for it).
            guard let st = try? await self.api.playerState() else {
                if self.streamIsCurrent(generation) {
                    self.dlog("network settled; engine API not answering -> leaving it to the health loop")
                }
                return
            }
            let playing = st.state == "play"
            let missing = await self.awaitOutputsReady(ids: Set(ids), timeoutMs: 2_000)
            guard self.streamIsCurrent(generation) else { return }
            if playing, missing.isEmpty {
                self.dlog("network settled; session intact, no resume needed")
                return
            }
            self.dlog("network settled; session broken -> re-discovering and resuming")
            await self.refreshSpeakers()
            guard self.streamIsCurrent(generation) else { return }
            self.resetDriftAnchors()
            await self.resumePlaybackOnce(reason: "network restored")
        }
    }

    /// True once the network is usable again, or after `timeout`. Used on wake:
    /// a fixed sleep is a guess, and guessing short means the resume fails.
    private func awaitNetwork(timeoutMs: Int = 15_000) async {
        var waited = 0
        while !pathSatisfied && waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 250
        }
    }
}
