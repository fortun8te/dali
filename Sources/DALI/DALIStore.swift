// DALI — single source of truth.
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
                syncBeacon.publish(streaming: false, delaySeconds: nil)
                cancelVolumePush()
            }
            if !phase.isOn { sessionMembership.reset() }
            // What-is-playing only matters while the room can hear it.
            NowPlayingMonitor.shared.setActive(phase == .streaming)
        }
    }
    var speakers: [RoomSpeaker] = []

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
            switch source {
            case .system: UserDefaults.standard.set("", forKey: "dali.sourceApp")
            case .app(_, let name): UserDefaults.standard.set(name, forKey: "dali.sourceApp")
            case .spotify: UserDefaults.standard.set("Spotify", forKey: "dali.sourceApp")
            }
            rebuildCaptureIfStreaming()
            // Switching to/from Spotify toggles the Connect helper.
            if source == .spotify { Task { await startSpotifyIfNeeded() } }
            else { Task { await stopSpotify() } }
        }
    }

    /// Re-resolve a remembered app source by name (pids do not survive relaunch).
    func resolveSavedSource() {
        guard case .system = source,
              let saved = UserDefaults.standard.string(forKey: "dali.sourceApp"),
              !saved.isEmpty,
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  $0.activationPolicy == .regular && $0.localizedName == saved
              })
        else { return }
        source = .app(pid: app.processIdentifier, name: saved)
    }

    /// The Mac's output volume 0...1. In All-audio mode this IS the room's
    /// group volume: speaker output = slider x this. The keys/menu/HUD are
    /// the master control; the app adds no second master.
    var systemVolume: Double = 0.5

    /// Music level 0...1 for the room visualization.
    var audioLevel: Double = 0
    var bassLevel: Double = 0
    var trebleLevel: Double = 0
    /// Beats heard IN THE ROOM so far. The canvas pulses when it changes.
    var beatCount: Int = 0

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
    var delayTrimMs: Double = UserDefaults.standard.double(forKey: "dali.delayTrimMs") {
        didSet {
            let clamped = min(max(delayTrimMs, -400), 400)
            if clamped != delayTrimMs { delayTrimMs = clamped; return }
            guard clamped != oldValue else { return }
            UserDefaults.standard.set(clamped, forKey: "dali.delayTrimMs")
            // Straight out to the browser, so dragging moves the picture live
            // instead of waiting for the next flight tick.
            applyRoomDelay()
            syncBeacon.publish(streaming: phase == .streaming, delaySeconds: roomDelaySec)
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
    /// second ago. ~14 samples at the 15 Hz tick; nothing measurable.
    private struct LevelSample { let at: Date; let level, bass, treble: Double; let beats: Int }
    private var levelDelayLine: [LevelSample] = []
    private var levelTask: Task<Void, Never>?

    private var statsTick = 0
    private var lastDropped = 0
    /// Compact machine-readable health every ~30s. The old 3s prose line repeated
    /// almost-identical state ten times per interval, costing disk space and AI
    /// context without adding evidence. Detailed 1s telemetry remains in the
    /// bounded flight recorder; this file is the cheap index an AI should read.
    private func logCaptureStats() {
        statsTick += 1
        guard statsTick % 450 == 0 else { return }   // ~30s at 15Hz
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
            "mac_volume": Int(systemVolume * 100),
            "backlog_ms": Int(Double(st.pending ?? 0) / 176.4),
            "rate_ppm": Int(driftCorr * 1_000_000),
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
    private var progressAnchorMs: Int?     // OwnTone item_progress_ms at lock start
    private var writtenAnchor: Int?        // bytes written at the same instant
    private var trueFillEMA = 0.0          // lightly smoothed true backlog, seconds (display)
    private var nonPlayAnchorStrikes = 0   // consecutive non-play polls (grace before re-anchor)

    // MARK: rate matcher
    //
    // ---- WHAT IS ACTUALLY WRONG -----------------------------------------
    // The pipeline is
    //     us --write--> [kernel FIFO, 46 ms] --pipe.c--> [input_buffer, cap
    //     2.18 s] --player.c, 10 ms setitimer tick--> AirPlay
    // and the player's tick runs slightly LONG, so it drains the pipe about
    // 0.4% slower than we fill it. The surplus accumulates invisibly inside
    // OwnTone's input_buffer — which is exactly why `appBuf` reads 0.00 s the
    // whole time the latency is ratcheting: the buffer that is filling is not
    // ours. Measured across 553 s with the varispeed pinned at exactly 1.0,
    // three independent ways: -4011 ppm (item_progress vs wall clock),
    // +4069 ppm (d(fill)/dt), +2979 ppm (engine's own `clock - pts` slope).
    // Unchecked that is 14 s of latency per hour; it collides with the 2.18 s
    // input threshold and with OwnTone's PLAYER_READ_BEHIND_MAX suspend, which
    // flushes every AirPlay output at once = the audible dropout.
    //
    // ---- WHY THIS LOOP CANNOT BECOME THE OLD ONE -------------------------
    // The deleted controller was P+I on the fill ERROR. Its fatal property was
    // that a starved pipe makes item_progress_ms under-advance, which
    // OVER-estimates fill, which commanded a harder drain, which starved it
    // further — and the integral then welded it to the rail (RATECLAMP on 454
    // log lines). Three structural changes make that impossible here:
    //
    //   1. THE LOOP INTEGRATES THE SLOPE OF FILL, NOT THE FILL ITSELF.
    //      `corr += KR * d(fill)/dt` converges to the plant's true rate skew
    //      (proof in the update site below) and is INDIFFERENT to fill's
    //      absolute value. The starvation ratchet corrupts fill's absolute
    //      value permanently but its slope only while starvation is ongoing —
    //      and ongoing starvation is directly detectable on our own side.
    //   2. EVERY DETECTABLE STARVATION CAUSE FREEZES THE LOOP. Drops, capture
    //      gaps, tap rebuilds, converter rebuilds, backpressure, silence-fed
    //      intervals, engine restarts, API hangs, implausible fill jumps.
    //   3. A NO-FEEDBACK WATCHDOG. If a correction has been applied for 90 s
    //      and fill moved AGAINST it, the plant is not behaving like the model,
    //      so the loop hard-resets and locks out for 180 s. In the old runaway
    //      this condition was true continuously; it would have fired within 90 s
    //      and could never have been sustained for more than a third of the time.
    private var rateInt = 0.0              // slow estimate of plant skew, fraction. The ONLY integrator.
    private var fillSlow: Double?          // heavily smoothed fill (seconds) — the control input
    private var errInt = 0.0               // ∫ fill-error, folded into rateInt; recentering only
    private var slopeAnchorFill = 0.0      // fillSlow when the current rate window opened
    private var slopeAnchorAge = 0.0       // seconds accumulated in that window
    private var slopeAnchorCorr = 0.0      // ∫ applied correction over that window
    private var lastSlopePpm = 0.0         // last measured plant skew, for the log
    private var driftCorr = 0.0            // last commanded correction, fraction
    private var fillJumpStrikes = 0        // consecutive implausible fill readings
    private var driftLockoutSec = 0.0      // >0 => hard-frozen at ratio 1.0
    private var authRunSec = 0.0           // seconds corr has held one direction outside the deadzone
    private var authRunSign = 0            // +1 draining, -1 filling, 0 idle
    private var authRunStartFill = 0.0     // fillSlow when that run opened
    private var driftFreeze = "startup"    // why the loop is not steering right now ("" = steering)
    /// Running integral of APPLIED correction, in seconds — our own copy of what
    /// OwnTone calls `read_deficit`. Positive = we have cumulatively delivered
    /// this much LESS audio than real time. See ASYMMETRY 3.
    private var netDrainSec = 0.0
    /// The debt cap can cross its boundary every second. Track the state but
    /// rate-limit prose so a harmless control oscillation cannot flood the log.
    private var debtCapActive = false
    private var debtCapLastLogAt = Date.distantPast

    /// ±0.5% authority. Enforced again inside CaptureController.setTargetRatio.
    private static let driftRail = CaptureController.driftRail
    private static let driftDeadzone = CaptureController.driftDeadzone
    /// Rate-loop cadence. Long enough that d(fill)/dt is dominated by real skew
    /// rather than by the 1 s quantisation of item_progress_ms (±1 s over a 15 s
    /// window is ±67000 ppm of instantaneous noise, which the KR gain and the
    /// fill EMA together attenuate by ~100x).
    private static let driftAdjustSec = 15.0
    /// Rate-matching gain, per adjust step. 0.15 per 15 s => the estimate of the
    /// plant skew converges with a time constant of 15/0.15 = 100 s. That is the
    /// loop's ONLY fast path and it is still two orders of magnitude slower than
    /// the old controller, which could swing the full rail in ~6 s.
    private static let driftKR = 0.15
    /// Fill-error proportional gain, per second. 1.0 s of error commands 1200
    /// ppm, so the P path alone has a time constant of 1/0.0012 = 833 s. It only
    /// exists to stop the absolute latency wandering; it is deliberately far too
    /// weak to chase a transient.
    private static let driftKP = 0.0012
    /// Fill-error integral, per second squared. 1.0 s of standing error takes
    /// ~15 min to contribute 2000 ppm. This is the recentering term and the only
    /// place windup is even conceivable, so it is clamped hard (see below).
    private static let driftKI = 2.2e-6
    /// EMA time constant on fill. item_progress_ms is 1 s quantised, so the raw
    /// fill has ~±0.05 s of quantisation noise; 20 s of smoothing puts the
    /// measurement noise well under the 0.10 s watchdog threshold.
    private static let driftFillTau = 20.0
    /// A fill reading this far from the smoothed value is not physically
    /// reachable in one poll (the rail permits 5 ms/s) — it is an engine restart,
    /// a seek, or a counter reset. Reject the sample.
    private static let driftJumpSec = 0.5
    private static let driftWatchdogSec = 90.0
    /// How much cumulative under-delivery we allow. OwnTone suspends playback at
    /// 1.5 s (`read_deficit_max`, player.c), so this is a fifth of the distance
    /// to a flush — enough headroom that a burst of jitter on top of a full
    /// budget still cannot reach it.
    private static let drainBudgetSec = 0.30
    /// Repayment rate once over budget: 1000 ppm of over-delivery. Slow enough to
    /// be inaudible (under 2 cents), fast enough to clear a full budget in ~5
    /// minutes.
    private static let drainRepayRate = 0.001
    /// Same watchdog, but for a correction pinned at the rail. At the rail the
    /// loop has spent its entire authority, so "still moving the wrong way" is
    /// already proof it has none — there is nothing left to wait for and no
    /// stronger correction to escalate to. 30 s is long enough that a burst of
    /// volume-push jitter can't trip it and short enough that a phantom fill
    /// ramp (see the flat clock-divergence note below) can't run for minutes.
    private static let driftRailWatchdogSec = 30.0
    // LOCKOUT LENGTH — observed failing in the field, do not raise again.
    //
    // 180 s was chosen to bound worst-case authority if the loop's measurement
    // were inverted. But a lockout is a window in which NOTHING corrects, and
    // the plant refills at several thousand ppm — so a 3-minute lockout let
    // fill ratchet 0.89 -> 1.64 s unopposed (dali-flight 2026-08-01 16:54,
    // `hold=lockout` on every line). That is the glitch interval, caused by the
    // guard rather than by drift. 30 s still breaks any runaway feedback (the
    // loop cannot re-establish a wrong correction faster than its 100 s time
    // constant) while leaving the buffer defended the rest of the time.
    private static let driftLockoutSec_ = 30.0
    private nonisolated static let flightLogURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DALI/dali-flight.log")

    // One serial writer for every app-owned log. The old implementation opened
    // and seeked the same files on arbitrary global-queue threads, so a flight
    // line and an event line could race, reorder, or overwrite each other right
    // when the machine was under load. It also grew forever. Keep one previous
    // generation so a long session cannot fill the disk or bury the incident.
    private nonisolated static let fileLogQueue = DispatchQueue(label: "dali.file-log", qos: .utility)
    private nonisolated static func appendLog(_ line: String, to url: URL, maxBytes: UInt64) {
        let data = Data(line.utf8)
        fileLogQueue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
            if size + UInt64(data.count) > maxBytes {
                let previous = URL(fileURLWithPath: url.path + ".1")
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: url, to: previous)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            do {
                try h.seekToEnd()
                try h.write(contentsOf: data)
                try h.close()
            } catch {
                try? h.close()
            }
        }
    }

    private nonisolated static func flog(_ s: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(s)\n"
        appendLog(line, to: flightLogURL, maxBytes: 16 * 1024 * 1024)
    }

    private func startFlightRecorder() {
        flightTask?.cancel()
        lastFlight = nil
        lastFlightFlags = ""
        aiSessionID = String(UUID().uuidString.prefix(8)).lowercased()
        statsTick = 0
        lastDropped = capture.stats.dropped
        resetDriftAnchors()
        driftFreeze = "startup"
        Self.flog("=== stream start: \(sessionSpeakerSummary()) | startBuffer=\(Self.savedStartBufferMs())ms | rateMatcher rail=±\(String(format: "%.2f", Self.driftRail*100))% tau=\(Int(Self.driftAdjustSec / Self.driftKR))s ===")
        aiEvent("stream_start", fields: [
            "speakers": sessionSpeakerSummary(),
            "start_buffer_ms": Self.savedStartBufferMs(),
            "source": source.label,
        ])
        aiHealth([
            "phase": "streaming", "speakers": sessionSpeakerSummary(),
            "source": source.label, "status": "warming_up",
        ])
        flightTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // `guard let self ... else { continue }` spun this task forever
                // once the store was gone: nothing inside the loop could ever
                // cancel it again. A missing self means the app is tearing down.
                guard let self else { return }
                guard self.phase == .streaming else { continue }
                await self.recordFlight()
            }
        }
    }

    private func sessionSpeakerSummary() -> String {
        speakers.filter { $0.enabled }.map { "\($0.name)" }.joined(separator: "+")
    }

    private func recordFlight() async {
        let f = capture.readMetrics()
        let prev = lastFlight
        lastFlight = f
        guard let p = prev else { return }   // need a delta
        // Real elapsed time, not the nominal 1 s. The loop sleeps 1 s and then
        // makes two HTTP calls, so its period is 1 s + API latency. Dividing by
        // 1.0 is what made the old log report `produce=103.5%` on a perfectly
        // healthy stream — it was measuring its own jitter.
        let dt = min(max(f.intervalSec, 0.2), 10.0)
        // THE DEBT LEDGER (see ASYMMETRY 3). Charge only drain BEYOND the matched
        // plant skew (`rateInt`). Sustained rate matching must run forever; the
        // old ledger billed that too, so a healthy ~+4000 ppm plant hit the 0.30s
        // ceiling in ~75s and entered drain/repay cycling (wild skew, FILLHIGH).
        // A freeze still counts: appliedCorr stays in force even when we stop
        // steering, and excess over rateInt is what actually spends the budget.
        netDrainSec += (f.appliedCorr - rateInt) * dt
        let writtenDelta = f.written - p.written          // bytes the kernel pipe accepted
        let produced = f.outBytes + f.silenceBytes        // bytes we made (post-varispeed + keepalive)
        let dropDelta = f.dropped - p.dropped
        let appBufSec = String(format: "%.2f", Double(f.pending) / 176_400)
        let writtenPct = String(format: "%.1f", Double(writtenDelta) / (176_400 * dt) * 100)
        let producedPct = String(format: "%.1f", Double(produced) / (176_400 * dt) * 100)
        let writtenPctVal = Double(writtenDelta) / (176_400 * dt) * 100

        // Live engine/AirPlay state + OwnTone's REAL playback clock. Time the call
        // so a WEDGE (API going slow/unresponsive — the onset of the "weird noises
        // then dies" failure) shows up in the log as apiMs/APIHANG instead of the
        // recorder silently going blind right when we need the data.
        var playerState = "?"
        var progressMs: Int?
        var spkInfo = ""
        let apiT0 = Date()
        // Parallelize — two independent HTTP calls, was sequential (6s wedge stall)
        async let psTask: PlayerState? = try? await api.playerState()
        async let outsTask: [Output]? = try? await api.outputs()
        let ps = await psTask
        let outs = await outsTask
        let apiMs = Int(Date().timeIntervalSince(apiT0) * 1000)
        if let ps { playerState = ps.state; progressMs = ps.item_progress_ms }
        let apiHang = ps == nil
        if let outs {
            spkInfo = speakers.filter { $0.enabled }.map { sp -> String in
                let o = outs.first { $0.id == sp.id }
                let sel = (o?.selected ?? false) ? "on" : "OFF"
                let link = (o?.streaming ?? false) ? "stream" :
                    ((o?.connected ?? false) ? "connected" : "DEAD")
                return "\(sp.name)[\(sel) \(link) v\(o?.volume ?? -1)/want\(effectiveVolume(sp))]"
            }.joined(separator: " ")
        }

        // ---- TRUE backlog from OwnTone's playback clock ---------------------
        // fill = bytes we've handed the pipe MINUS bytes OwnTone has rendered.
        // This is the real, otherwise-invisible end-to-end buffer depth. We anchor
        // both counters at the first sane reading so only the DELTA matters —
        // then add the start buffer back in: OwnTone begins playback with a full
        // start_buffer already accumulated, so at the anchor poll the real backlog
        // is startBufferSec while the raw delta reads 0. (The old code targeted
        // an absolute 1.2s against that zero-based delta: err=-1.2 railed the
        // varispeed to +0.6% overproduction, and ~228s in the growing backlog hit
        // the FIFOWriter drop cap — the always-at-~4-minutes glitch.)
        let startBufferSec = Double(config.startBufferMs) / 1000.0
        let written = f.written
        var trueFillSec: Double? = nil
        var fillRaw: Double? = nil
        // Set when the anchor was actually dropped below, so the drift gate can
        // tell a real re-anchor from a transient non-play poll. (Reading
        // nonPlayAnchorStrikes there would never work: it is reset to 0 by the
        // very branch that performs the re-anchor.)
        var reAnchored = false
        if playerState == "play", let pm = progressMs {
            nonPlayAnchorStrikes = 0
            if let pa = progressAnchorMs, let wa = writtenAnchor {
                let renderedBytes = Double(pm - pa) / 1000.0 * 176_400.0
                let writtenBytes = Double(written - wa)
                let fill = startBufferSec + (writtenBytes - renderedBytes) / 176_400.0   // seconds, absolute
                fillRaw = fill
                // EMA smooth (progress clock is coarse, 1s granularity).
                trueFillEMA = trueFillEMA == 0 ? fill : trueFillEMA * 0.6 + fill * 0.4
                trueFillSec = trueFillEMA
            } else {
                progressAnchorMs = pm; writtenAnchor = written      // first lock
            }
        } else {
            // A transient non-"play" poll (rebuffer blip) must NOT re-anchor:
            // re-anchoring re-hides the accumulated backlog, the controller
            // re-rails to overproduction, and the ~4-min grow-then-drop cycle
            // restarts — that is what made the glitch RECUR. Only a sustained
            // stop (3 consecutive polls) re-anchors; a real engine respawn goes
            // through resetDriftAnchors().
            nonPlayAnchorStrikes += 1
            if nonPlayAnchorStrikes >= 3 {
                progressAnchorMs = nil; writtenAnchor = nil; trueFillEMA = 0
                nonPlayAnchorStrikes = 0
                reAnchored = true
            }
        }

        // ---- Rate matcher ---------------------------------------------------
        // Setpoint is the buffer OwnTone establishes for itself at start: at the
        // anchor poll the raw delta is 0 and the real backlog is start_buffer_ms,
        // so `fill` is already expressed on that scale.
        let targetFill = startBufferSec

        // 1. VALIDITY GATE. Anything that makes this interval's byte accounting
        //    or the progress clock untrustworthy freezes the loop. `hard` means
        //    the pipeline itself was discontinuous, so the learned skew estimate
        //    is meaningless and must go too.
        var freeze = ""
        var hard = false
        if driftLockoutSec > 0 {
            driftLockoutSec = max(0, driftLockoutSec - dt); freeze = "lockout"; hard = true
        } else if f.tapRebuilds > 0 {
            freeze = "taprebuild"; hard = true            // varispeed was reset under us
        } else if dropDelta > 0 {
            // FIFOWriter discarded audio: `written` no longer equals what we
            // produced, so every byte-difference downstream of here is wrong.
            freeze = "drop"; hard = true
        } else if playerState != "play" {
            freeze = "notplaying"; hard = reAnchored
        } else if apiHang || progressMs == nil {
            freeze = "apihang"
        } else if trueFillSec == nil || fillRaw == nil {
            // No anchor yet (or it was just dropped): there is no fill to steer
            // on, and the stale smoothed value must not survive into the next
            // anchor's coordinate system.
            freeze = "noanchor"; hard = true; fillSlow = nil
        } else if f.convRebuilds > 0 {
            freeze = "convrebuild"                        // resampler discontinuity
        } else if f.maxGapMs > 120 {
            freeze = "capturegap"                         // we under-produced for a non-skew reason
        } else if Double(f.pending) / 176_400 > 0.25 {
            // Real backpressure: OwnTone stopped accepting, so `written` is no
            // longer a proxy for what it consumed and fill is garbage.
            freeze = "backpressure"
        } else if Double(f.silenceBytes) > 0.25 * Double(max(produced, 1)) {
            // Keepalive silence is wall-clock paced and bypasses the varispeed,
            // so this interval cannot tell us what our correction did.
            freeze = "silencefed"
        } else if abs(f.appliedCorr - driftCorr) > Self.driftRail * 0.5 && driftCorr != 0 {
            // Commanded and applied disagree by more than half the rail: the
            // ratio moved mid-interval or something diluted it. Skip.
            freeze = "corrmismatch"
        }

        // 2. Implausible fill reading. The rail permits 5 ms of change per
        //    second; anything near 0.5 s in one poll is a restart, a seek, or a
        //    counter reset, never drift. Reject the sample; three in a row means
        //    the anchor itself is stale, so re-anchor.
        if freeze.isEmpty, let raw = fillRaw, let s = fillSlow, abs(raw - s) > Self.driftJumpSec {
            fillJumpStrikes += 1
            freeze = "filljump"
            if fillJumpStrikes >= 3 {
                hard = true
                progressAnchorMs = nil; writtenAnchor = nil; trueFillEMA = 0; fillSlow = nil
                fillJumpStrikes = 0
            }
        } else if freeze.isEmpty {
            fillJumpStrikes = 0
        }

        // 3. Track the smoothed control input. Only advanced on valid samples,
        //    so a frozen interval never injects a step into the slope window.
        if freeze.isEmpty, let raw = fillRaw {
            if fillSlow == nil {
                // First value in a fresh anchor's coordinate system. Open the
                // slope window ON it, so the first 15 s measurement cannot see a
                // step between the placeholder anchor and reality and mistake it
                // for tens of thousands of ppm of drift.
                fillSlow = raw
                slopeAnchorFill = raw; slopeAnchorAge = 0; slopeAnchorCorr = 0
            } else {
                let a = 1 - exp(-dt / Self.driftFillTau)
                fillSlow = fillSlow! + a * (raw - fillSlow!)
            }
        }

        // 4. CONTROL UPDATE.
        if hard {
            // Wipe everything learned: the plant we measured is not the plant we
            // now have. Ratio goes to exactly 1.0, which is the bit-transparent
            // passthrough — the safest possible state.
            rateInt = 0; errInt = 0; driftCorr = 0
            lastSlopePpm = 0  // don't keep printing a stale tens-of-thousands ppm
            slopeAnchorAge = 0; slopeAnchorCorr = 0; slopeAnchorFill = fillSlow ?? targetFill
            authRunSec = 0; authRunSign = 0
        } else if freeze.isEmpty, let fs = fillSlow {
            let err = fs - targetFill
            slopeAnchorAge += dt
            slopeAnchorCorr += f.appliedCorr * dt        // ∫ applied correction over the window
            if slopeAnchorAge >= Self.driftAdjustSec {
                // THE RATE MATCHER. Let `skew` be the plant's true rate mismatch
                // and `corr` our correction. By construction
                //     d(fill)/dt = skew - corr
                // so this update is
                //     corr += KR * (skew - corr)
                // i.e. a first-order convergence of corr onto skew with time
                // constant driftAdjustSec/KR = 100 s. It has ONE real, strictly
                // negative eigenvalue: it cannot oscillate, cannot overshoot,
                // and — crucially — has no dependence whatsoever on fill's
                // absolute value, which is the quantity the starvation ratchet
                // corrupts. When it has converged, d(fill)/dt is zero and the
                // update stops: it is self-terminating, not self-reinforcing.
                let slope = (fs - slopeAnchorFill) / slopeAnchorAge      // s/s
                // Reported skew is the PLANT's, so add back the mean correction
                // we were applying across the whole window (not just this poll's).
                lastSlopePpm = (slope + slopeAnchorCorr / slopeAnchorAge) * 1e6
                rateInt += Self.driftKR * slope
                // Recentering only. `rateInt` holds the drift at zero but at
                // whatever latency it happened to inherit (the fill error has a
                // free integrator and no restoring force of its own). This is a
                // SEPARATE term, clamped to a third of the rail, so the only
                // windup-capable quantity in the loop is bounded to 1667 ppm.
                errInt = min(max(errInt + Self.driftKI * err * slopeAnchorAge,
                                 -Self.driftRail / 3), Self.driftRail / 3)
                rateInt = min(max(rateInt, -Self.driftRail), Self.driftRail)
                slopeAnchorFill = fs; slopeAnchorAge = 0; slopeAnchorCorr = 0
            }
            // ASYMMETRY 1: the two failures are not symmetric in consequence.
            // Running dry underruns and is audible within seconds; running full
            // takes minutes to reach OwnTone's 2.18 s cap and is silent until it
            // does. So the P term is 3x stronger below the setpoint than above.
            // This only ever strengthens the FILL direction, which by
            // construction cannot starve anything — it is the one direction in
            // which being wrong is harmless. (Simulated: a -3000 ppm plant
            // otherwise costs 0.6 s of buffer before the loop catches it, which
            // does not fit under a 0.7 s start buffer.)
            let kp = err < 0 ? Self.driftKP * 3 : Self.driftKP
            var c = rateInt + errInt + kp * err
            // ASYMMETRY 2: two states where one direction is unambiguously wrong
            // no matter what fill claims.
            if fs < 0.25 { c = min(c, 0) }                  // nearly empty: never drain
            if fs > targetFill + 2.0 { c = max(c, 0) }      // over the engine's own cap: never fill
            c = min(max(c, -Self.driftRail), Self.driftRail)
            // ASYMMETRY 3 — THE DEBT CEILING. This is the fix for the glitch.
            //
            // A positive correction does not just "drain the backlog": it makes
            // the varispeed emit FEWER frames than real time, which is literally
            // under-delivery to the engine. OwnTone counts every byte we fail to
            // provide in `pb_session.read_deficit` and, at
            // `read_deficit_max` = 264600 bytes = EXACTLY 1.5 s cumulative, does
            // this (player.c:1491):
            //
            //     "Source is not providing sufficient data, temporarily
            //      suspending playback" -> pb_suspend()
            //
            // Suspend flushes and restarts the stream. Observed 2026-08-01
            // 19:44:29, and the engine's own clock stepped 515 ms across it
            // (clock-pts -528 ms -> -13 ms). That step IS the audible glitch, and
            // the flight log shows the whole cycle repeating four times in six
            // minutes. Held at the +0.50% rail, 1.5 s of debt accrues in five
            // minutes — which is the "it glitches after a few minutes" report,
            // exactly.
            //
            // Nothing upstream bounded this: the rail bounds the RATE, and the
            // no-feedback watchdog bounds how long one DIRECTION runs, but the
            // quantity that actually kills us is the running INTEGRAL, and
            // nothing was tracking it. So track it — in the engine's own units,
            // against a budget well under its limit.
            //
            // Deliberately asymmetric, because the two directions are not: too
            // full costs latency and OwnTone back-pressures us long before it
            // matters; too empty costs a flush and a restart. So filling is
            // unbudgeted and draining is on a short leash.
            // (Enforced below, unconditionally — see `debt ceiling` before
            //  setTargetRatio. Doing it only here would miss the case that
            //  actually runs longest: a soft freeze HOLDS driftCorr in force
            //  while never re-entering this branch, so a ratio frozen at the
            //  rail would keep accruing debt with nothing to stop it.)
            if abs(c) < Self.driftDeadzone { c = 0 }
            driftCorr = c
        }
        // (soft freeze: driftCorr, rateInt and errInt are all held unchanged —
        //  a one-second hiccup must not throw away 100 s of learning — but the
        //  slope window is discarded, because it now spans an invalid interval.)
        if !freeze.isEmpty {
            slopeAnchorAge = 0; slopeAnchorCorr = 0; slopeAnchorFill = fillSlow ?? targetFill
        }

        // 5. NO-FEEDBACK WATCHDOG — the structural guarantee against the old
        //    failure mode. If we have been correcting in one direction for 90 s
        //    and fill has moved AGAINST that correction by more than the
        //    measurement noise, then either the measurement is inverted (exactly
        //    what starvation does to item_progress_ms) or the plant's skew
        //    exceeds our whole authority — and in both cases pushing harder is
        //    useless or harmful. Hard reset and lock out for 180 s.
        //
        //    In the deleted controller's runaway this condition held
        //    CONTINUOUSLY: drift welded to +0.60% while fill climbed.
        //
        //    THE BOUND. 90 s of run followed by a 180 s lockout caps the duty
        //    cycle at 1/3, so the WORST-CASE sustained authority in any direction
        //    is rail/3 = 1667 ppm even if the fill measurement is completely
        //    inverted and every single decision is wrong. Per cycle the exposure
        //    is 90 s x 0.005 = 0.45 s of buffer, against a 0.7 s start buffer
        //    and OwnTone's 2.18 s input reserve.
        //
        //    Simulated against a faithful model of the old failure mode (fill
        //    reported with the wrong sign wrt the correction, 6 h): the loop
        //    trips 79 times, authority pins at +1650 ppm, and the TRUE buffer
        //    never falls below its starting value — because this pipeline
        //    refills itself at +4000 ppm, which out-runs the bound. Against the
        //    real plant it holds fill inside 0.65-0.76 s for six hours with
        //    zero trips.
        //
        //    HONEST LIMIT: if the measurement were inverted AND the plant had no
        //    natural refill at all, 1667 ppm would still empty a 0.7 s buffer in
        //    ~7 minutes (vs ~2 for the old controller). That case cannot be
        //    distinguished from healthy operation by fill alone — any loop able
        //    to cancel a real +4000 ppm inflow can, by definition, drain at
        //    +4000 ppm when told to. It is bounded and loudly logged, not
        //    eliminated. The freeze gates above exist to make it unreachable in
        //    practice, since every mechanism that inverts the measurement
        //    (drops, gaps, backpressure, restarts) is caught before this point.
        //
        //    If the trip repeats, the log says so on every line and the meaning
        //    is unambiguous: this machine's skew exceeds ±0.5% and the rail needs
        //    raising — not that the loop is misbehaving.
        //    MEASURED 2026-08-01, and the reason the reset rule below changed.
        //    A 70 s session ramped fill 0.74 s -> 2.16 s (~+25000 ppm) with the
        //    correction pinned at the +0.50% rail the whole way. The engine's own
        //    `Clock divergence ... clock - pts` over the SAME window stayed inside
        //    -35..+6 ms with no trend — a real 25000 ppm consumption deficit would
        //    have walked it to -1.8 s. So the engine was rendering in real time and
        //    the ramp was a phantom: item_progress_ms under-reporting, exactly the
        //    inverted-measurement case this watchdog was written for. It did not
        //    fire, because `!freeze.isEmpty` RESET the run on every soft freeze and
        //    backpressure/filljump blips came more often than every 90 s — 122
        //    railed seconds produced 3 trips. A soft freeze means "this one second
        //    is unreadable", not "forget the last 90"; it now pauses the run
        //    instead of clearing it. Only a `hard` freeze (real pipeline
        //    discontinuity, which already wiped the learned state) resets.
        let sign = driftCorr > Self.driftDeadzone ? 1 : (driftCorr < -Self.driftDeadzone ? -1 : 0)
        let railedNow = abs(driftCorr) >= Self.driftRail - 1e-9
        if sign == 0 || sign != authRunSign || hard {
            authRunSign = sign; authRunSec = 0; authRunStartFill = fillSlow ?? targetFill
        } else if !freeze.isEmpty {
            // Soft freeze: hold the run open, accumulate nothing. The correction
            // is still being applied to the audio, so the evidence stays valid —
            // we just can't read this interval.
        } else if let fs = fillSlow {
            authRunSec += dt
            let moved = fs - authRunStartFill              // +ve = fill rose
            // 0.10 s was too tight: normal fill wander during volume pushes
            // (each one is an RTSP round-trip that stalls the player thread)
            // routinely exceeds it, so the watchdog fired on healthy sessions
            // and locked the loop out exactly when the buffer needed defending.
            // 0.25 s still catches a genuinely inverted loop — which moves fill
            // monotonically and fast — without tripping on ordinary jitter.
            let wrongWay = sign > 0 ? moved > 0.25 : moved < -0.25
            let needSec = railedNow ? Self.driftRailWatchdogSec : Self.driftWatchdogSec
            if authRunSec >= needSec && wrongWay {
                // Phantom fill (item_progress_ms under-report) used to only freeze
                // ratio=1.0 for 30s while leaving the bogus high fillSlow in place.
                // After lockout the loop saw fill still at ~1.8s, drained again,
                // and the climb→rail→NOFEEDBACK cycle repeated every ~90s until
                // the room glitched or the user restarted. Re-anchor the fill
                // clocks so the next measurement starts from start_buffer again.
                let phantomRising = sign > 0 && moved > 0.25
                rateInt = 0; errInt = 0; driftCorr = 0
                lastSlopePpm = 0
                slopeAnchorAge = 0; slopeAnchorCorr = 0
                authRunSec = 0; authRunSign = 0
                if phantomRising {
                    progressAnchorMs = nil; writtenAnchor = nil
                    trueFillEMA = 0; fillSlow = nil
                    slopeAnchorFill = targetFill
                    fillJumpStrikes = 0
                    // Short lockout only: we threw away the bad measurement, so
                    // there is no wound-up integral left to defend against.
                    driftLockoutSec = min(Self.driftLockoutSec_, 10.0)
                    freeze = "NOFEEDBACK"
                    hard = true
                    dlog("drift NOFEEDBACK: corr held drain\(railedNow ? " AT RAIL" : "") \(Int(needSec))s, fill moved \(String(format: "%+.2f", moved))s — re-anchoring fill (phantom progress) + \(Int(driftLockoutSec))s lockout")
                    aiEvent("fill_reanchor_phantom", level: "warn", fields: [
                        "moved_s": String(format: "%.2f", moved),
                        "rail": railedNow,
                        "need_s": Int(needSec),
                    ])
                } else {
                    slopeAnchorFill = fs
                    driftLockoutSec = Self.driftLockoutSec_
                    freeze = "NOFEEDBACK"
                    dlog("drift NOFEEDBACK: corr held \(sign > 0 ? "drain" : "fill")\(railedNow ? " AT RAIL" : "") \(Int(needSec))s, fill moved \(String(format: "%+.2f", moved))s — freezing \(Int(Self.driftLockoutSec_))s at ratio 1.0")
                }
            }
        }

        // Early phantom-climb trip: write is realtime (~100%) and speakers are
        // streaming, but measured fill has already walked >0.8s above the start
        // buffer. Waiting for the 30s rail watchdog lets latency climb into the
        // glitch zone. Re-anchor as soon as the measurement is clearly bogus.
        if freeze.isEmpty,
           let fs = fillSlow,
           fs > targetFill + 0.80,
           abs(writtenPctVal - 100) < 3,
           !spkInfo.contains("DEAD"),
           !spkInfo.contains("OFF") {
            progressAnchorMs = nil; writtenAnchor = nil
            trueFillEMA = 0; fillSlow = nil
            rateInt = 0; errInt = 0; driftCorr = 0
            lastSlopePpm = 0
            slopeAnchorAge = 0; slopeAnchorCorr = 0; slopeAnchorFill = targetFill
            authRunSec = 0; authRunSign = 0; fillJumpStrikes = 0
            driftLockoutSec = min(Self.driftLockoutSec_, 10.0)
            freeze = "PHANTOMFILL"
            hard = true
            dlog(String(format: "phantom fill climb: slow=%.2fs target=%.2fs write=%.0f%% — re-anchoring", fs, targetFill, writtenPctVal))
            aiEvent("fill_reanchor_climb", level: "warn", fields: [
                "slow_s": String(format: "%.2f", fs),
                "target_s": String(format: "%.2f", targetFill),
                "write_pct": String(format: "%.1f", writtenPctVal),
            ])
        }

        // DEBT CEILING — the last word on the ratio, applied to whatever
        // driftCorr ended up being: freshly computed, held through a freeze, or
        // left over from before a lockout. See ASYMMETRY 3 above for why the
        // integral, not the rate, is the quantity that glitches.
        // Over budget we do not merely stop draining — we REPAY. Clamping to
        // exactly 0 looks safer and is worse: the ledger then stops moving in
        // either direction, so the budget is spent for the rest of the session
        // and the loop can never steer down again however much it needs to. A
        // small over-delivery instead walks the debt back to zero in ~5 min AND
        // deepens the engine's reserve on the way, so the steady state is a slow
        // drain/repay cycle averaging zero — which is the only honest setpoint
        // for a correction that is supposed to cancel drift, not create it.
        if netDrainSec > Self.drainBudgetSec {
            let capped = min(driftCorr, -Self.drainRepayRate)
            if capped != driftCorr {
                if !debtCapActive {
                    debtCapActive = true
                }
                if Date().timeIntervalSince(debtCapLastLogAt) >= 60 {
                    dlog(String(format: "drain budget spent (%.2fs of %.2fs) — capping %+.2f%% to %+.2f%%",
                                netDrainSec, Self.drainBudgetSec, driftCorr * 100, capped * 100))
                    debtCapLastLogAt = Date()
                }
                driftCorr = capped
            }
        } else if debtCapActive {
            debtCapActive = false
            if Date().timeIntervalSince(debtCapLastLogAt) >= 60 {
                dlog(String(format: "drain budget recovered (%.2fs) — steering again", netDrainSec))
                debtCapLastLogAt = Date()
            }
        }

        // OwnTone now schedules reads from its monotonic wall clock. The app's
        // older rate matcher used the coarse item-progress counter and was
        // repeatedly fooled into removing audio at +0.5%. That made both
        // speakers fall progressively behind together until they appeared to
        // go out. Keep the capture bit-transparent; the engine owns pacing.
        driftCorr = 0
        rateInt = 0
        errInt = 0
        netDrainSec = 0
        freeze = "engineclock"
        driftFreeze = freeze
        capture.setTargetRatio(1.0)

        // ---- Logging --------------------------------------------------------
        let driftPct = String(format: "%+.2f", f.appliedCorr * 100)
        let fillStr = trueFillSec.map { String(format: "%.2fs", $0) } ?? "?"
        let slowStr = fillSlow.map { String(format: "%.2fs", $0) } ?? "?"
        let corrStr = String(format: "%+.2f", driftCorr * 100)
        let skewStr = String(format: "%+.0f", lastSlopePpm)
        let atRail = abs(driftCorr) >= Self.driftRail - 1e-9
        let flags = [
            dropDelta > 0 ? "DROP+\(dropDelta)" : nil,
            freeze == "NOFEEDBACK" ? "DRIFT-NOFEEDBACK" : nil,
            freeze == "PHANTOMFILL" ? "PHANTOMFILL" : nil,
            atRail ? "RATERAIL" : nil,
            (trueFillSec ?? 0) > targetFill + 1.5 ? "FILLHIGH" : nil,
            (trueFillSec ?? 9) < 0.15 ? "UNDERRUN" : nil,
            // EAGAIN rate can NOT distinguish healthy backpressure from a dead
            // reader: the 8 KB pipe + 1 ms retry saturates near ~1000/s in both
            // cases (review finding M6). The discriminating signal is bytes
            // actually accepted: a live OwnTone drains 176,400 B/s no matter
            // what; an interval where the pipe accepted ~nothing while we have
            // data queued means the reader is genuinely stalled.
            (writtenDelta < 8_192 && f.pending > 0) ? "READERSTALL" : nil,
            f.maxGapMs > 120 ? String(format: "captureGap%.0fms", f.maxGapMs) : nil,
            f.convRebuilds > 0 ? "convRebuild\(f.convRebuilds)" : nil,
            // fill sinking well under the buffer OwnTone established means its
            // read deficit is growing — the real precursor to the glitch.
            (trueFillSec.map { $0 < targetFill * 0.5 } ?? false) ? "FILLLOW" : nil,
            apiHang ? "APIHANG" : nil,
            apiMs > 1000 ? "apiSLOW\(apiMs)ms" : nil,
            playerState != "play" ? "PLAYER=\(playerState)" : nil,
            spkInfo.contains("OFF") ? "speakerOFF" : nil,
            spkInfo.contains("DEAD") ? "speakerDEAD" : nil,
        ].compactMap { $0 }.joined(separator: " ")

        // Duplicate the first appearance/change of an anomaly into the compact
        // event log. The one-second flight recorder keeps the full data; this
        // gives a human a short incident index without scanning thousands of
        // healthy lines. Clearing is logged too, so every incident has bounds.
        if flags != lastFlightFlags {
            if !flags.isEmpty {
                dlog("FLIGHT anomaly BEGIN/CHANGE: \(flags) fill=\(fillStr) corr=\(corrStr)% api=\(apiMs)ms")
                aiEvent("anomaly_start_or_change", level: "warn", fields: [
                    "flags": flags, "fill_s": fillStr, "rate_pct": corrStr, "api_ms": apiMs,
                ])
            } else if !lastFlightFlags.isEmpty {
                dlog("FLIGHT anomaly CLEARED: \(lastFlightFlags)")
                aiEvent("anomaly_clear", fields: ["flags": lastFlightFlags])
            }
            lastFlightFlags = flags
        }

        // fill    = end-to-end backlog, seconds (lightly smoothed, the display value)
        // slow    = the same, heavily smoothed — this is what the loop actually steers on
        // corr    = commanded rate correction (+ drains the backlog, - fills it)
        // drift   = correction ACTUALLY applied to audio this interval (byte-weighted)
        // skew    = the plant's measured rate mismatch in ppm, i.e. what corr is cancelling
        // hold    = why the loop is not steering ("" when it is)
        // HEALTHY, once converged: slow flat within ~±0.05s, skew steady near its
        // machine's value (~+4000 ppm here), corr ≈ skew, drift ≈ corr, hold empty.
        // UNHEALTHY: slow trending; corr pinned at the rail (RATERAIL) — authority
        // exhausted; hold set for long stretches — the loop is blind, look at why;
        // DRIFT-NOFEEDBACK — corr and fill moved in the same direction, loop disowned.
        let hold = freeze.isEmpty ? "" : " hold=\(freeze)"
        applyRoomDelay()
        syncBeacon.publish(streaming: phase == .streaming, delaySeconds: roomDelaySec)
        Self.flog("fill=\(fillStr) slow=\(slowStr) corr=\(corrStr)% drift=\(driftPct)% skew=\(skewStr)ppm debt=\(String(format: "%+.2f", netDrainSec))s\(hold) write=\(writtenPct)% produce=\(producedPct)% appBuf=\(appBufSec)s bufs=\(f.bufCount) maxgap=\(Int(f.maxGapMs))ms inRate=\(Int(f.inRate)) prog=\(progressMs.map(String.init) ?? "?")ms macVol=\(Int(systemVolume*100)) | \(spkInfo)\(flags.isEmpty ? "" : "  <<< \(flags)")")
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
            while !Task.isCancelled && phase == .streaming {
                let now = Date()
                let r = capture.readLevels()
                levelDelayLine.append(LevelSample(at: now, level: r.level, bass: r.bass,
                                                  treble: r.treble, beats: r.beats))
                // Publish the newest sample the room has actually reached.
                let due = now.addingTimeInterval(-roomDelaySec)
                var newest: LevelSample?
                while let first = levelDelayLine.first, first.at <= due {
                    newest = first
                    levelDelayLine.removeFirst()
                }
                // Guard against the line growing without bound if the delay is
                // ever mis-measured: two seconds of samples is plenty.
                if levelDelayLine.count > 60 { levelDelayLine.removeFirst(levelDelayLine.count - 60) }
                if let s = newest {
                    audioLevel = s.level
                    bassLevel = s.bass
                    trebleLevel = s.treble
                    if s.beats != beatCount { beatCount = s.beats }
                }
                // Cheap, and it is the only thing standing between a browser bug
                // and a room that stays silent while the Mac is playing.
                reviewCutCredibility()
                logCaptureStats()
                try? await Task.sleep(nanoseconds: 66_000_000)   // ~15 Hz
            }
            audioLevel = 0
            bassLevel = 0
            trebleLevel = 0
            levelDelayLine.removeAll()
        }
    }

    private func rebuildCaptureIfStreaming() {
        guard phase == .streaming else { return }
        let fifo = config.pipePath.path
        let src = source.tapSource
        let cap = capture
        let generation = streamGeneration
        let captureSession = cap.sessionID
        Task { @MainActor [weak self] in
            let ok = await Task.detached {
                cap.rebuild(fifoPath: fifo, muteLocal: true, source: src,
                            expectedSession: captureSession)
            }.value
            guard !ok else { return }
            guard let self, self.phase == .streaming,
                  self.streamGeneration == generation else { return }
            self.stopStream()
            self.phase = .error("The selected app's audio could not be captured.")
        }
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
            UserDefaults.standard.set(current.enabled, forKey: "dali.on.\(current.name)")
        }
        if kind == .front {
            frontName = name
            if !name.isEmpty, backName == name { backName = "" }
        } else {
            backName = name
            if !name.isEmpty, frontName == name { frontName = "" }
        }
        UserDefaults.standard.set(frontName, forKey: "dali.frontName")
        UserDefaults.standard.set(backName, forKey: "dali.backName")
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
        var tagged = fields
        tagged["session"] = aiSessionID
        Self.writeAIEvent(event, level: level, fields: tagged)
    }

    private func aiHealth(_ fields: [String: Any]) {
        var tagged = fields
        tagged["session"] = aiSessionID
        Self.writeAIEvent("health", level: "info", fields: tagged)
        Self.writeAIHealth(tagged)
    }

    private nonisolated static func dlog(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(msg)\n"
        appendLog(line, to: debugLogURL, maxBytes: 8 * 1024 * 1024)
    }
    func dlog(_ msg: String) { Self.dlog(msg) }

    /// Persisted audio-delay (start buffer) in ms, clamped to OwnTone's safe
    /// range. OwnTone hard-floors at >250ms (session refuses to start below);
    /// our floor 500 keeps jitter/retransmit headroom for the slowest device.
    /// 700 is the default: with the drift controller holding the fill AT the
    /// start buffer (no more backlog runaway), a deep buffer is no longer
    /// needed for stability — it was only ever pure latency.
    static func savedStartBufferMs() -> Int {
        let v = UserDefaults.standard.object(forKey: "dali.startBufferMs") as? Double ?? 700
        return Int(min(max(v, 500), 3000))
    }

    init() {
        let defaults = UserDefaults.standard
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

        // Bundled helper; falls back to the repo vendor dir during development.
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/owntone/owntone")
        let dev = URL(fileURLWithPath: NSString(string: "~/Downloads/beam/vendor/owntone/owntone").expandingTildeInPath)
        let binary = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : dev
        supervisor = EngineSupervisor(binary: binary, config: cfg)
        // Spotify Connect device — shares the same pipe so front/back stay PTP-synced.
        let spotifyCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DALI/spotify-cache")
        spotifySupervisor = SpotifySupervisor(
            deviceName: "DALI",
            pipePath: cfg.pipePath,
            cacheDir: spotifyCache
        )
        applyRoomDelay()

        Task { await bootEngine() }
        startIdleGuard()
        observeSleepWake()
        observeNetwork()
        syncBeacon.onCut = { [weak self] cut in self?.setExtensionCut(cut) }
        syncBeacon.onNow = { NowPlayingMonitor.shared.browserReport(json: $0) }
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
        capture.onSourceSilenceChanged = { [weak self] silent in
            self?.dlog("source digital silence \(silent ? "began" : "ended") — keepalive only; speaker volume unchanged")
        }
        syncBeacon.start()
        // Volume keys: when the Mac itself is silent (room-only), the hardware
        // volume keys steer the ROOM master via the system volume they change.
        // Never mirror a Mac volume spike 1:1 onto the speakers — rise is ramped;
        // falls stay immediate so mute/quiet still feels instant. volumeLimit
        // remains the hard ceiling inside effectiveVolume().
        volumeObserver.onChange = { [weak self] new, prev in
            Task { @MainActor in
                guard let self else { return }
                self.desiredSystemVolume = min(max(new, 0), 1)
                if new < prev - 0.001 {
                    // Drop immediately (mute / volume-down).
                    self.systemVolume = self.desiredSystemVolume
                    self.sysVolRampTask?.cancel()
                    self.sysVolRampTask = nil
                    if self.phase == .streaming, case .system = self.source {
                        self.scheduleVolumePush()
                    }
                } else {
                    self.startSysVolRamp()
                }
            }
        }
        let initial = volumeObserver.current() ?? 0.5
        systemVolume = initial
        desiredSystemVolume = initial
    }

    private let volumeObserver = SystemVolumeObserver()
    /// Mac volume the observer last reported. `systemVolume` may lag behind
    /// while we ramp up so speakers never jump loud.
    private var desiredSystemVolume: Double = 0.5
    private var sysVolRampTask: Task<Void, Never>?

    /// Coalesce rapid volume-up key repeats into one room command. Sending a
    /// network volume request every 80 ms overwhelmed the front receiver's
    /// control connection and dropped it from the group. Falls remain immediate
    /// so mute/volume-down is always responsive. 500 ms (was 300) — OwnTone's
    /// SET_PARAMETER (volume) to the PowerNode times out under chatter and
    /// tears the AirPlay session down ("failed during execution of volume").
    private func startSysVolRamp() {
        guard sysVolRampTask == nil else { return }
        sysVolRampTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { sysVolRampTask = nil; return }
            systemVolume = desiredSystemVolume
            if phase == .streaming, case .system = source { scheduleVolumePush() }
            sysVolRampTask = nil
        }
    }

    // MARK: engine lifecycle

    private func bootEngine() async {
        do {
            try await supervisor.start()
            ptpDegraded = await supervisor.ptpAvailable == false
            if ptpDegraded { dlog("PTP degraded — front/back sync may drift (NTP-only)") }
            await refreshSpeakers()
            await reconcileEngineState()
            await loadLibrary()
        } catch {
            phase = .error("The audio engine could not start.\n\(error)")
        }
    }

    /// The engine can resume pipe playback on its own after a restart, holding
    /// the speakers while the app shows OFF. The app's state wins: if we are
    /// not streaming, the engine must not play.
    private func reconcileEngineState() async {
        guard !phase.isOn else { return }
        if let st = try? await api.playerState(), st.state == "play" {
            try? await api.stop()
        }
    }

    func shutdown() async {
        capture.stop()
        await supervisor.stop()
    }

    func restartEngine() {
        let resumeMirror = phase == .streaming && !playerMode
        streamGeneration += 1
        let generation = streamGeneration
        healthTask?.cancel(); healthTask = nil
        levelTask?.cancel(); levelTask = nil
        flightTask?.cancel(); flightTask = nil
        nowTask?.cancel(); nowTask = nil
        fading = false
        capture.stop()
        for i in speakers.indices { speakers[i].health = .off }
        phase = .starting
        Task { @MainActor in
            lastSentVolumes.removeAll()
            // Rebuild config so a changed audio-delay pref takes effect.
            config = OwnToneConfig(rootDir: config.rootDir,
                                   startBufferMs: Self.savedStartBufferMs())
            await supervisor.updateConfig(config)
            await supervisor.setResumePlayback(false)
            try? await api.stop()
            do {
                try await supervisor.restart()
                guard generation == streamGeneration else { return }
                await refreshSpeakers()
                phase = .idle
                if resumeMirror { startStream() }
            } catch {
                guard generation == streamGeneration else { return }
                phase = .error("The audio engine could not restart.\n\(error)")
            }
        }
    }

    // MARK: discovery

    func refreshSpeakers() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let outputs = try await api.outputs()
            discoveryMessage = nil
            applyDiscoveredSpeakers(outputs)
        } catch {
            discoveryMessage = "Speakers could not be refreshed. Try again in a moment."
        }
    }

    private func applyDiscoveredSpeakers(_ outputs: [Output]) {
        let preferences = SpeakerPreferences(defaults: .standard)
        var list: [RoomSpeaker] = []
        let discovered = outputs.filter { $0.name != hostName() && $0.type.localizedCaseInsensitiveContains("AirPlay") }
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
        let remembered = preferences.rememberedNames.union(speakers.filter { $0.enabled }.map(\.name))
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
        speakers = list.sorted {
            rank($0.kind) == rank($1.kind) ? $0.name < $1.name : rank($0.kind) < rank($1.kind)
        }
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

    private func hostName() -> String {
        Host.current().localizedName ?? ""
    }

    // MARK: the big switch

    /// Bumped on every start/stop so an in-flight startStream Task cannot keep
    /// hard-rejoining or flipping phase after the user stopped / a prior attempt
    /// already failed cleanly.
    private var streamGeneration = 0

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
        case .mirror: startStream()
        case .player: shuffleAll()
        }
    }

    func startStream() {
        guard !phase.isOn else { return }
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
        volumeFailUntil.removeAll()
        forceVolumePush = false
        Task { @MainActor in
            do {
                if await !api.isUp() { try await supervisor.start() }
                ptpDegraded = await supervisor.ptpAvailable == false
                if ptpDegraded { dlog("PTP degraded at stream start — will show NEEDS YOU") }
                guard phase == .starting, gen == streamGeneration else { return }
                resolveSavedSource()
                await refreshSpeakers()
                // Select the whole session set (front/back always, enabled extras)
                // so toggling a pair member later only mutes it, never changes the
                // group, preserving sync.
                let chosen = sessionSpeakers()
                guard chosen.contains(where: \.enabled) else {
                    guard gen == streamGeneration else { return }
                    phase = .error(speakers.contains(where: \.enabled)
                        ? "Your selected speakers are unavailable. Check their power and Wi-Fi, then try again."
                        : "Choose at least one speaker in Settings → Room.")
                    return
                }
                for speaker in chosen { sessionMembership.retain(speaker.name) }
                lastSentVolumes.removeAll()
                markHealth(of: chosen.map(\.id), .connecting)
                // Stop any stale pipe session before selecting this run's group.
                // Selecting first and then stopping left a race where the UI
                // still said selected while one newly-created AirPlay session
                // had already been torn down.
                try? await api.stop()
                guard phase == .starting, gen == streamGeneration else { return }
                try await api.setOutputs(ids: chosen.map(\.id))
                // Always start SILENT, then fade in after playback begins.
                for sp in chosen {
                    guard phase == .starting, gen == streamGeneration else { return }
                    try? await api.setVolume(outputID: sp.id, volume: 0)
                }
                guard phase == .starting, gen == streamGeneration else { return }

                // Spotify Connect: librespot feeds the same pipe PTP-synced to front/back.
                // If librespot binary is present, it is the SOLE writer — starting a
                // ProcessTap as well would garble the FIFO with two interleaved writers.
                if source == .spotify {
                    await startSpotifyIfNeeded()
                    let hasLibrespot = await spotifySupervisor.isLibrespotAvailable
                    if hasLibrespot {
                        dlog("Spotify mode with librespot — skipping ProcessTap, librespot owns the pipe")
                        // Ensure pipe exists (OwnTone materializes it) even without capture
                        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: config.pipePath.path).deletingLastPathComponent(), withIntermediateDirectories: true)
                    } else {
                        dlog("Spotify mode without librespot — tapping Spotify app (\(source.label))")
                        try capture.start(fifoPath: config.pipePath.path,
                                          muteLocal: true,
                                          source: source.tapSource)
                    }
                } else {
                    // DALI takes over the speakers: whatever they were playing is replaced.
                    try capture.start(fifoPath: config.pipePath.path,
                                      muteLocal: true,
                                      source: source.tapSource)
                }
                await supervisor.setResumePlayback(true)
                guard phase == .starting, gen == streamGeneration else {
                    return
                }

                // The engine's pipe_autostart begins playback by itself as soon as
                // audio flows. Queueing while it does that returns 500, so first
                // give autostart a moment, then queue manually only if needed.
                var playing = false
                for _ in 0..<8 {
                    guard phase == .starting, gen == streamGeneration else { return }
                    if let st = try? await api.playerState(), st.state == "play" { playing = true; break }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                if !playing {
                    try? await api.rescan()
                    var uri: String?
                    for _ in 0..<6 {
                        guard phase == .starting, gen == streamGeneration else { return }
                        if let u = (try? await api.pipeTrackURI(named: "beam.pipe")) ?? nil { uri = u; break }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if let uri {
                        try? await api.playPipe(uri: uri)   // tolerated: autostart may win the race
                    }
                    // Either our play or a late autostart counts.
                    for _ in 0..<6 {
                        guard phase == .starting, gen == streamGeneration else { return }
                        if let st = try? await api.playerState(), st.state == "play" { playing = true; break }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                guard phase == .starting, gen == streamGeneration else { return }
                guard playing else {
                    capture.stop()
                    try? await api.stop()
                    guard gen == streamGeneration else { return }
                    phase = .error("The room did not start playing. Is any audio playing on the Mac?")
                    return
                }
                // Do not trust `selected`: OwnTone persists that preference even
                // when the actual AirPlay session is stopped or failed. Wait for
                // connected OR streaming (AirPlay 2 often stays connected-only).
                // Soft re-assert first; hard deselect/select at most ONCE — AP2
                // shared sessions die when any member is deselected.
                var missing = await awaitOutputsReady(ids: Set(chosen.map(\.id)), timeoutMs: 15_000)
                guard phase == .starting, gen == streamGeneration else { return }
                if !missing.isEmpty {
                    let names = chosen.filter { missing.contains($0.id) }.map(\.name).joined(separator: ", ")
                    dlog("startup speakers not ready: \(names) -> soft re-select")
                    aiEvent("startup_speaker_retry", level: "warn", fields: ["attempt": 1, "speakers": names, "mode": "soft"])
                    try? await api.setOutputs(ids: chosen.map(\.id))
                    missing = await awaitOutputsReady(ids: missing, timeoutMs: 8_000)
                }
                guard phase == .starting, gen == streamGeneration else { return }
                if !missing.isEmpty {
                    let names = chosen.filter { missing.contains($0.id) }.map(\.name).joined(separator: ", ")
                    dlog("startup speakers still not ready: \(names) -> one hard rejoin")
                    aiEvent("startup_speaker_retry", level: "warn", fields: ["attempt": 2, "speakers": names, "mode": "hard"])
                    for sp in chosen where missing.contains(sp.id) {
                        guard phase == .starting, gen == streamGeneration else { return }
                        try? await api.setSelected(outputID: sp.id, selected: false)
                    }
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    guard phase == .starting, gen == streamGeneration else { return }
                    for sp in chosen where missing.contains(sp.id) {
                        guard phase == .starting, gen == streamGeneration else { return }
                        try? await api.setSelected(outputID: sp.id, selected: true)
                    }
                    missing = await awaitOutputsReady(ids: missing, timeoutMs: 12_000)
                }
                guard phase == .starting, gen == streamGeneration else { return }
                guard missing.isEmpty else {
                    let names = chosen.filter { missing.contains($0.id) }.map(\.name).joined(separator: ", ")
                    capture.stop()
                    try? await api.stop()
                    guard gen == streamGeneration else { return }
                    markHealth(of: chosen.map(\.id), .off)
                    throw BeamAPIError(what: "Speakers did not connect: \(names)")
                }
                markHealth(of: chosen.map(\.id), .live)
                // Output ids are session-scoped, so the engine's stored offsets
                // do not necessarily follow a new session — re-assert zero.
                resetOffsetCache()
                enforceZeroOffsets(force: true)
                phase = .streaming
                dlog("stream started -> \(chosen.map(\.name).joined(separator: ", ")) (tap clockAnchored=\(capture.isClockAnchored))")
                startHealthLoop()
                startLevelLoop()
                startFlightRecorder()
                await fadeIn()
            } catch let e as ProcessTap.TapError {
                guard gen == streamGeneration else { return }
                capture.stop()
                try? await api.stop()
                guard gen == streamGeneration else { return }
                for i in speakers.indices { speakers[i].health = .off }
                phase = .error("DALI needs permission to capture your Mac's audio. (\(e.stage))")
            } catch {
                guard gen == streamGeneration else { return }
                capture.stop()
                try? await api.stop()
                guard gen == streamGeneration else { return }
                healthTask?.cancel()
                levelTask?.cancel()
                flightTask?.cancel()
                for i in speakers.indices { speakers[i].health = .off }
                phase = .error("Could not start the stream.\n\(error)")
            }
        }
    }

    func stopStream() {
        streamGeneration += 1
        let generation = streamGeneration
        healthTask?.cancel()
        levelTask?.cancel()
        flightTask?.cancel()
        speakerRecoveryInFlight.removeAll()
        recoveryCooldownUntil.removeAll()
        recoveryFailCounts.removeAll()
        volumeFailUntil.removeAll()
        forceVolumePush = false
        fading = false
        audioLevel = 0
        resetCutState()
        capture.stop()
        Task {
            guard generation == streamGeneration else { return }
            await supervisor.setResumePlayback(false)
            guard generation == streamGeneration else { return }
            try? await api.stop()
            guard generation == streamGeneration else { return }
            await stopSpotify()
        }
        for i in speakers.indices { speakers[i].health = .off }
        dlog("stream stopped by user")
        aiEvent("stream_stop", fields: ["reason": "user"])
        phase = .idle
        aiHealth(["phase": "idle", "status": "stopped"])
    }

    // MARK: Spotify Connect
    private func startSpotifyIfNeeded() async {
        // Only run when source is Spotify and we're streaming
        guard source == .spotify else { return }
        dlog("Spotify Connect starting — device 'DALI' will appear in Spotify app")
        aiEvent("spotify_start", fields: ["device": "DALI"])
        try? await spotifySupervisor.start()
        // If librespot is available, it feeds the pipe directly — no tap needed.
        // If not, we already mapped tapSource to the Spotify app pid above,
        // so the existing capture path will tap Spotify desktop audio.
        if await spotifySupervisor.state == .running {
            dlog("Spotify Connect ready — select 'DALI' in Spotify")
        }
    }

    private func stopSpotify() async {
        await spotifySupervisor.stop()
        dlog("Spotify Connect stopped")
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
    var mode: RoomMode = RoomMode(rawValue: UserDefaults.standard.string(forKey: "dali.mode") ?? "") ?? .mirror {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "dali.mode")
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
    private var startingPlayback = false

    /// Load the album list from the engine's library (best-effort).
    func loadLibrary() async {
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
    private func prepareRoom() async -> Bool {
        if await !api.isUp() { try? await supervisor.start() }
        await refreshSpeakers()
        let chosen = sessionSpeakers()
        guard chosen.contains(where: \.enabled) else {
            phase = .error("Choose an available speaker in Settings → Room.")
            return false
        }
        for speaker in chosen { sessionMembership.retain(speaker.name) }
        lastSentVolumes.removeAll()
        markHealth(of: chosen.map(\.id), .connecting)
        try? await api.setOutputs(ids: chosen.map(\.id))
        for sp in chosen { try? await api.setVolume(outputID: sp.id, volume: 0) }
        return true
    }

    private func playToRoom(_ start: @escaping (BeamAPI) async throws -> Void) {
        guard !startingPlayback else { return }
        startingPlayback = true
        phase = .starting
        Task {
            defer { startingPlayback = false }
            guard await prepareRoom() else { return }
            do { try await start(api) }
            catch { phase = .error("Could not start playback.\n\(error)"); return }
            // DALI takes over the speakers whatever they were doing.
            try? await api.setOutputs(ids: sessionSpeakers().map(\.id))
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
        Task {
            if isPlaying {
                try? await api.pause(); isPlaying = false
            } else {
                try? await api.play(); isPlaying = true
                if phase != .streaming { phase = .streaming }
                startNowPlayingLoop()
            }
        }
    }

    func next()     { Task { try? await api.next() } }
    func previous() { Task { try? await api.previous() } }

    func stopPlayback() {
        streamGeneration += 1
        nowTask?.cancel(); nowTask = nil
        healthTask?.cancel()
        Task { try? await api.stop() }
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
            while !Task.isCancelled && phase == .streaming {
                if let ps = try? await api.playerState() {
                    isPlaying = (ps.state == "play")
                    if let items = try? await api.queue(),
                       let cur = items.first(where: { $0.id == ps.item_id }) {
                        nowTitle = cur.title ?? ""
                        nowArtist = cur.artist ?? ""
                        if let len = ps.item_length_ms ?? cur.length_ms, len > 0,
                           let p = ps.item_progress_ms {
                            nowProgress = min(1, max(0, Double(p) / Double(len)))
                        }
                    }
                }
                // No capture to measure, so feed the room canvas a gentle pulse.
                audioLevel  = isPlaying ? 0.5 : 0
                bassLevel   = isPlaying ? 0.4 : 0
                trebleLevel = isPlaying ? 0.3 : 0
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
        UserDefaults.standard.set(enabling, forKey: "dali.on.\(speaker.name)")
        guard phase == .streaming else { return }
        let sp = speakers[idx]
        if enabling && !alreadyJoined {
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
                    try await api.setVolume(outputID: sp.id, volume: 0)
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
            lastSentVolumes[sp.id] = nil
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
    // Effective speaker volume = relVolume * master/100 * balanceWeight.

    func setRelVolume(_ v: Double, for speaker: RoomSpeaker) {
        guard let idx = speakers.firstIndex(where: { $0.id == speaker.id }) else { return }
        guard v.isFinite else { return }
        let clamped = min(max(v, 0), 100)
        speakers[idx].relVolume = clamped
        UserDefaults.standard.set(clamped, forKey: "dali.vol.\(speaker.name)")
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
        UserDefaults.standard.set(clamped, forKey: "dali.gain.\(speaker.name)")
        lastSentVolumes[speaker.id] = nil
        scheduleVolumePush()
    }

    /// Hard ceiling for what any speaker is ever sent (big speakers, small room).
    var volumeLimit: Double {
        didSet {
            let clamped = min(max(volumeLimit, 1), 100)
            if clamped != volumeLimit {
                volumeLimit = clamped
                return
            }
            UserDefaults.standard.set(volumeLimit, forKey: "dali.volumeLimit")
            scheduleVolumePush()
        }
    }

    /// What we have CONFIRMED the engine holds. Only written after a PUT
    /// actually succeeded — see scheduleOffsetPush().
    private var lastSentOffset: [String: Int] = [:]
    private var offsetPushInFlight = false
    private var offsetPushAgain = false

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
    /// stored (the DB held a stale `Living Room = 60` from the old control long
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

    /// Single serialized, latest-wins offset pusher.
    ///
    /// THE BUG THIS REPLACES (why Space had no audible effect): the old version
    /// wrote `lastSentOffset[id] = want` at the moment it QUEUED a batch, then
    /// did `offsetPushTask?.cancel()` on the very next drag tick. A drag emits
    /// ticks far faster than an HTTP round-trip completes, so batch after batch
    /// was cancelled before its PUT landed — while the cache recorded every one
    /// of them as already sent. From then on the dedupe suppressed those exact
    /// values forever, so returning the slider to a position it had passed
    /// through sent nothing at all and the engine kept a stale offset.
    ///
    /// This version never cancels an in-flight request and only records a value
    /// once the engine has actually accepted it. A failed PUT clears the cache
    /// entry so the next pass retries instead of believing a write that never
    /// happened. Same proven shape as scheduleVolumePush().
    private func scheduleOffsetPush() {
        if offsetPushInFlight { offsetPushAgain = true; return }
        offsetPushInFlight = true
        Task {
            repeat {
                offsetPushAgain = false
                // Re-read the model each pass, so a drag that moved on while we
                // were mid-request converges on the LATEST value, not a stale
                // snapshot captured when the batch was queued.
                let snapshot = sessionSpeakers()
                    .map { ($0.id, $0.offsetMs) }
                for (id, ms) in snapshot where lastSentOffset[id] != ms {
                    do {
                        try await api.setOffset(outputID: id, offsetMs: ms)
                        lastSentOffset[id] = ms
                    } catch {
                        // Never claim a write we did not land.
                        lastSentOffset[id] = nil
                    }
                }
                try? await Task.sleep(nanoseconds: 80_000_000)   // pace a drag
            } while offsetPushAgain
            offsetPushInFlight = false
        }
    }

    /// Forget what we believe the engine holds — after a restart or a new
    /// session its output ids and stored offsets may not match ours.
    func resetOffsetCache() { lastSentOffset.removeAll() }

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
        forceVolumeResync()
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

    func effectiveVolume(_ s: RoomSpeaker) -> Int {
        guard !roomMutedByCut else { return 0 }   // video stopped: silence everything now
        guard s.enabled else { return 0 }   // muted but still in the group (sync)
        let base: Double
        if playerMode {
            // Player model: the engine sources the audio, so the Mac's own volume
            // is irrelevant. Each speaker's slider IS its absolute AirPlay volume.
            base = s.relVolume
        } else {
            switch source {
            // Map the Mac's full 0...100% master range across the room's safe
            // 0...volumeLimit range. The old formula hit the limit at only 20%
            // Mac volume (then a second 15% cap flattened it again), so most
            // volume-key presses appeared to do nothing.
            case .system: base = s.relVolume * systemVolume * (volumeLimit / 100)
            case .app:    base = s.relVolume
            case .spotify: base = s.relVolume
            }
        }
        // Calibration gain balances devices of different efficiency.
        let raw = min(base * s.gain, 100)
        let limited = min(raw, volumeLimit)
        return Int(limited.rounded())
    }

    // Single serialized pipeline: sends IMMEDIATELY, never overlaps requests,
    // and always ends on the latest values. Concurrent pushes used to race,
    // letting a stale high volume land after a newer low one (loud spikes).
    private var pushInFlight = false
    private var volumePushTask: Task<Void, Never>?
    private var volumePushGeneration = 0
    private var pushAgain = false
    private var forceVolumePush = false
    private var lastSentVolumes: [String: Int] = [:]
    private var lastReconciledEcho: [String: Int] = [:]
    /// After a SET_PARAMETER (volume) failure, OwnTone often tears that device
    /// down. Cool off before retrying so we don't pile more volume RTSP on a
    /// dying PowerNode control connection.
    private var volumeFailUntil: [String: Date] = [:]
    private var troubleStrikes: [String: Int] = [:]
    private var speakerRecoveryInFlight: Set<String> = []
    /// After a failed hard rejoin, back off before trying again — endless
    /// deselect/select every poll is what thrash-kills AirPlay 2 sessions.
    private var recoveryCooldownUntil: [String: Date] = [:]
    private var recoveryFailCounts: [String: Int] = [:]
    private var notPlayStrikes = 0
    private var apiDeadStrikes = 0      // consecutive health polls where OwnTone's API didn't answer (wedge detector)
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
    private func awaitOutputsReady(ids: Set<String>, timeoutMs: Int) async -> Set<String> {
        let client = api
        return await OutputReadiness.missing(ids: ids, timeout: .milliseconds(timeoutMs)) {
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
        guard fails < 4 else { return }   // stop hammering; leave .trouble for the user
        speakerRecoveryInFlight.insert(sp.id)
        defer {
            if generation == streamGeneration { speakerRecoveryInFlight.remove(sp.id) }
        }
        speakers.indices.filter { speakers[$0].id == sp.id }.forEach { speakers[$0].health = .connecting }
        // Silence first so a mid-rejoin device never blasts at its own default.
        try? await api.setVolume(outputID: sp.id, volume: 0)
        guard streamIsCurrent(generation) else { return }
        lastSentVolumes[sp.id] = 0
        try? await api.setSelected(outputID: sp.id, selected: false)
        guard streamIsCurrent(generation) else { return }
        try? await Task.sleep(nanoseconds: 750_000_000)
        guard streamIsCurrent(generation) else { return }
        try? await api.setSelected(outputID: sp.id, selected: true)
        guard streamIsCurrent(generation) else { return }
        let missing = await awaitOutputsReady(ids: Set([sp.id]), timeoutMs: 8_000)
        guard streamIsCurrent(generation) else { return }
        guard missing.isEmpty else {
            speakers.indices.filter { speakers[$0].id == sp.id }.forEach { speakers[$0].health = .trouble }
            let nextFails = fails + 1
            recoveryFailCounts[sp.id] = nextFails
            // Back off harder each failure so we don't thrash-kill the partner.
            let cooldown: TimeInterval = nextFails >= 3 ? 60 : 20
            recoveryCooldownUntil[sp.id] = Date().addingTimeInterval(cooldown)
            aiEvent("speaker_rejoin_failed", level: "error", fields: [
                "speaker": sp.name, "fails": nextFails, "cooldown_s": Int(cooldown)
            ])
            dlog("\(sp.name) hard rejoin failed (x\(nextFails)); cooldown \(Int(cooldown))s")
            return
        }
        // Restore the bounded target with one command. Multi-step fades were a
        // command storm and one ignored receiver reply can block OwnTone's
        // global command lane.
        volumeFailUntil[sp.id] = nil
        try? await api.setVolume(outputID: sp.id, volume: 0)
        guard streamIsCurrent(generation) else { return }
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard streamIsCurrent(generation),
              let current = speakers.first(where: { $0.id == sp.id }) else { return }
        let target = min(effectiveVolume(current), Int(volumeLimit.rounded()))
        do {
            try await api.setVolume(outputID: sp.id, volume: target)
            guard streamIsCurrent(generation) else { return }
            lastSentVolumes[sp.id] = target
        } catch {
            guard streamIsCurrent(generation) else { return }
            lastSentVolumes[sp.id] = nil
            volumeFailUntil[sp.id] = Date().addingTimeInterval(3)
            dlog("\(sp.name) setVolume(\(target)) failed after rejoin: \(error)")
        }
        troubleStrikes[sp.id] = 0
        readyStrikes[sp.id] = 2
        recoveryFailCounts[sp.id] = 0
        recoveryCooldownUntil[sp.id] = nil
        lastReconciledEcho[sp.id] = nil
        speakers.indices.filter { speakers[$0].id == sp.id }.forEach {
            speakers[$0].health = speakers[$0].enabled ? .live : .off
        }
        aiEvent("speaker_rejoin_ok", fields: ["speaker": sp.name])
        dlog("\(sp.name) hard rejoin succeeded")
        speakerRecoveryInFlight.remove(sp.id)
        // Mac/slider may have moved while we owned volume during recovery.
        guard let latest = speakers.first(where: { $0.id == sp.id }) else { return }
        let wantNow = min(effectiveVolume(latest), Int(volumeLimit.rounded()))
        if lastSentVolumes[sp.id] != wantNow {
            forceVolumeResync(ids: [sp.id])
        }
    }

    /// Invalidate cached sent volumes and push as soon as speakers are live.
    /// Call on connecting/trouble → live so volume changes made during a blip
    /// (when pushes were skipped) actually land — including deltas ≤ 12 that
    /// the reconcile dead-zone would otherwise leave stuck forever.
    private func forceVolumeResync(ids: [String]? = nil) {
        let targets = ids ?? sessionSpeakers().map(\.id)
        for id in targets {
            lastSentVolumes[id] = nil
            lastReconciledEcho[id] = nil
            volumeFailUntil[id] = nil
        }
        forceVolumePush = true
        scheduleVolumePush()
    }

    private func cancelVolumePush() {
        volumePushGeneration += 1
        volumePushTask?.cancel()
        volumePushTask = nil
        pushInFlight = false
        pushAgain = false
        forceVolumePush = false
    }

    private func scheduleVolumePush() {
        guard phase == .streaming, !fading else { return }
        if pushInFlight { pushAgain = true; return }
        pushInFlight = true
        let generation = volumePushGeneration
        volumePushTask = Task { @MainActor in
            defer {
                // An old request may finish after stop/start. It cannot release
                // the new session's lane or change its cached volume state.
                if generation == volumePushGeneration {
                    pushInFlight = false
                    volumePushTask = nil
                }
            }
            repeat {
                guard !Task.isCancelled, phase == .streaming,
                      generation == volumePushGeneration else { return }
                pushAgain = false
                let force = forceVolumePush
                forceVolumePush = false
                // Skip speakers mid-recovery or in trouble — recoverSpeaker owns
                // their volume so a concurrent push cannot blast them. Non-live
                // speakers keep a stale lastSentVolumes; forceVolumeResync on
                // return-to-live is what closes that gap.
                // A pair switched OFF stays in the AirPlay group and is muted by
                // sending volume 0 — but toggle() also marks it `.off`, and this
                // filter used to require `.live`, so the mute was never sent and
                // the "off" pair kept playing at its old volume. Disabled members
                // are always eligible: their target is 0 by construction.
                let ids = sessionSpeakers().map(\.id)
                for id in ids {
                    guard !Task.isCancelled, phase == .streaming,
                          generation == volumePushGeneration else { return }
                    guard let sp = sessionSpeakers().first(where: { $0.id == id }),
                          !sp.enabled || sp.health == .live,
                          !speakerRecoveryInFlight.contains(id) else { continue }
                    let name = sp.name
                    let v = min(effectiveVolume(sp), Int(volumeLimit.rounded()))
                    if let until = volumeFailUntil[id], until > Date(), !force { continue }
                    let prev = lastSentVolumes[id]
                    // Quantize routine updates: ±1 chatter from Mac-volume float
                    // rounding spammed RTSP and killed the PowerNode. Forced
                    // resync (live recovery / fade / cut) always sends exact.
                    if !force, let prev, abs(prev - v) < 2 { continue }
                    if prev == v { continue }
                    do {
                        try await api.setVolume(outputID: id, volume: v)
                        guard !Task.isCancelled, phase == .streaming,
                              generation == volumePushGeneration else { return }
                        lastSentVolumes[id] = v
                        volumeFailUntil[id] = nil
                    } catch {
                        guard !Task.isCancelled, phase == .streaming,
                              generation == volumePushGeneration else { return }
                        // Never suppress a retry for a command that did not land.
                        lastSentVolumes[id] = nil
                        volumeFailUntil[id] = Date().addingTimeInterval(3)
                        dlog("\(name) setVolume(\(v)) failed: \(error)")
                        aiEvent("volume_push_failed", level: "warn", fields: [
                            "speaker": name, "want": v, "error": "\(error)"
                        ])
                    }
                    // Pace between speakers (was 100ms end-of-batch only). AirPlay
                    // volume is RTSP SET_PARAMETER — stacking both devices at once
                    // is what produced APIHANG + "No response to SET_PARAMETER".
                    try? await Task.sleep(nanoseconds: 180_000_000)
                }
            } while pushAgain || forceVolumePush
        }
    }

    private var fading = false

    /// Bring the enabled speakers out of the silent setup state. The old eight-
    /// step fade sent 16 RTSP volume commands for a two-speaker room. A single
    /// ignored reply then blocked OwnTone's global player-command lane for 15s,
    /// backed the FIFO up and dropped audio. One bounded write per speaker keeps
    /// startup quiet without turning volume into a network stress test.
    private func fadeIn() async {
        let generation = streamGeneration
        fading = true
        defer {
            if generation == streamGeneration {
                fading = false
                scheduleVolumePush()
            }
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled, phase == .streaming,
              generation == streamGeneration else { return }
        for sp in sessionSpeakers() {
            guard !Task.isCancelled, phase == .streaming,
                  generation == streamGeneration else { return }
            let target = min(effectiveVolume(sp), Int(volumeLimit.rounded()))
            do {
                try await api.setVolume(outputID: sp.id, volume: target)
                guard !Task.isCancelled, phase == .streaming,
                      generation == streamGeneration else { return }
                lastSentVolumes[sp.id] = target
            } catch {
                guard !Task.isCancelled, phase == .streaming,
                      generation == streamGeneration else { return }
                lastSentVolumes[sp.id] = nil
            }
        }
    }

    private func pushVolumes() async throws {
        for s in sessionSpeakers() {
            try await api.setVolume(outputID: s.id, volume: effectiveVolume(s))
        }
    }

    /// Re-establish playback after the devices ended the session on their own.
    /// Re-selects every enabled output, re-plays the pipe, and re-pushes volumes
    /// TWICE (once now, once after the session settles) so a device that rejoins
    /// at its own default volume gets corrected instead of sitting quiet.
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
        } else if let uri = (try? await api.pipeTrackURI(named: "beam.pipe")) ?? nil {
            guard streamIsCurrent(generation) else { return }
            try? await api.playPipe(uri: uri)
        }
        guard streamIsCurrent(generation) else { return }
        lastSentVolumes.removeAll()
        // Silence first, settle, then FADE IN (the old double pushVolumes landed
        // as a loud jump mid-session whenever a rejoined device came back at its
        // own default volume and ignored the pre-session volume set).
        for sp in speakers where sp.enabled {
            guard streamIsCurrent(generation) else { return }
            try? await api.setVolume(outputID: sp.id, volume: 0)
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
        } else {
            dlog("resume did NOT reach play state")
            markHealth(of: ids, .connecting)
        }
    }

    // MARK: wedge recovery

    /// Re-anchor the drift controller after the engine is replaced under us, so a
    /// fresh playback clock does not produce a garbage fill estimate or a wound-up
    /// integral that bends the pitch right after recovery.
    private func resetDriftAnchors() {
        progressAnchorMs = nil; writtenAnchor = nil; trueFillEMA = 0
        nonPlayAnchorStrikes = 0
        rateInt = 0; errInt = 0; driftCorr = 0; fillSlow = nil
        slopeAnchorFill = 0; slopeAnchorAge = 0; slopeAnchorCorr = 0; lastSlopePpm = 0
        fillJumpStrikes = 0; driftLockoutSec = 0
        authRunSec = 0; authRunSign = 0; authRunStartFill = 0
        // Cleared HERE and nowhere else: OwnTone's read_deficit is a property of
        // the engine's stream, so our mirror of it may only be forgiven when that
        // stream restarts. Clearing it on an ordinary freeze would hand the loop
        // a fresh budget every hiccup, which is precisely how an unbounded
        // integral gets rebuilt by accident.
        netDrainSec = 0; debtCapActive = false; debtCapLastLogAt = Date.distantPast
        driftFreeze = "reanchor"
        capture.setTargetRatio(1.0)
    }

    /// Force the wedged engine to be replaced and wait for it to come back. Used
    /// for BOTH wedge kinds: a dead HTTP API, and a frozen playback clock while the
    /// API still answers. Clears every strike counter and re-anchors the controller
    /// so the recovered stream starts clean. The long wait covers the supervisor's
    /// SIGTERM grace plus the up-to-10s engine relaunch, so the loop does not kill a
    /// child that is still in the middle of starting.
    private func forceRespawn(_ reason: String) async {
        dlog("force respawn: \(reason)")
        aiEvent("engine_respawn", level: "error", fields: ["reason": reason])
        apiDeadStrikes = 0; notPlayStrikes = 0
        progressStallStrikes = 0; lastProgressMs = nil
        resetDriftAnchors()
        markHealth(of: speakers.filter(\.enabled).map(\.id), .connecting)
        await supervisor.killForRespawn()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        // killForRespawn assumes the crash path auto-recovers — but if the death
        // budget (3 crashes/60s) was just exhausted, the supervisor is parked in
        // .failed with no auto-retry. restart() clears the budget and revives it.
        for _ in 0..<6 {
            let s = await supervisor.state
            if s == .running { break }
            // `resettingBudgets: false` — see EngineSupervisor.restart(). This is
            // an AUTOMATIC recovery attempt, not the user asking for a clean
            // slate; resetting the wedge/crash budgets here is what let a
            // persistently-wedging engine loop kill->respawn->wedge forever,
            // each cycle getting a fresh breaker.
            if case .failed = s { try? await supervisor.restart(resettingBudgets: false); break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
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
        if apiDeadStrikes >= 2 {
            await forceRespawn("HTTP API dead x2 (last: \(endpoint)) while process alive")
        }
    }

    private func startHealthLoop() {
        healthTask?.cancel()
        apiDeadStrikes = 0; notPlayStrikes = 0
        progressStallStrikes = 0; lastProgressMs = nil
        readyStrikes.removeAll()
        troubleStrikes.removeAll()
        speakerRecoveryInFlight.removeAll()
        recoveryCooldownUntil.removeAll()
        recoveryFailCounts.removeAll()
        // Stale echo entries from a previous session would suppress the first
        // volume reconciliation of this one (review finding L6).
        lastReconciledEcho.removeAll()
        healthTask = Task {
            while !Task.isCancelled && phase == .streaming {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard phase == .streaming else { break }
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
                if capture.isRunning && starvedSec > 10 {
                    dlog(String(format: "tap: no buffers for %.0fs -> rebuilding tap", starvedSec))
                    aiEvent("capture_no_buffers", level: "warn", fields: ["seconds": Int(starvedSec)])
                    rebuildCaptureIfStreaming()
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
                guard let st = try? await api.playerState() else {
                    await noteEngineAPIFailure("player")
                    continue
                }
                // In player mode a pause is intentional and must NOT be
                // "recovered" from. Only auto-resume when we mean to be playing.
                let intendPlaying = !playerMode || isPlaying
                if st.state != "play" && intendPlaying {
                    notPlayStrikes += 1
                    progressStallStrikes = 0; lastProgressMs = nil
                    if notPlayStrikes >= 2 {
                        notPlayStrikes = 0
                        dlog("player '\(st.state)' x2 while streaming -> resuming")
                        await resumePlayback()
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
                    await noteEngineAPIFailure("outputs")
                    continue
                }
                apiDeadStrikes = 0
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
                        } else {
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
                        if strikes >= 3 {
                            if speakers[i].health != .trouble {
                                dlog("\(speakers[i].name) dropped (3 strikes) -> rejoining")
                                aiEvent("speaker_rejoin", level: "warn", fields: ["speaker": speakers[i].name])
                            }
                            speakers[i].health = .trouble
                        } else if strikes >= 2, speakers[i].health == .live {
                            speakers[i].health = .connecting
                        }
                    }
                }
                // Auto-rejoin only the troubled output. Cooldown + fail cap inside
                // recoverSpeaker prevent endless deselect thrash.
                for sp in speakers where sp.enabled && sp.health == .trouble {
                    await recoverSpeaker(sp)
                }
                // Volume reconciliation: a rejoined or reset device comes back at
                // its own volume; if the engine reports a value FAR from intent,
                // resend ours. Threshold 12 (not 2): AirPlay volume round-trips
                // through a dB scale, so the engine's reported 0-100 value
                // routinely differs from ours by ~5 just from rounding. Resending
                // on that noise spammed the POWERNODE with volume commands every
                // few seconds, which can itself destabilize the device. Only act
                // on a real gap (a device that actually reset its volume).
                for sp in speakers where sp.enabled && sp.health == .live
                    && !speakerRecoveryInFlight.contains(sp.id) {
                    if let until = volumeFailUntil[sp.id], until > Date() { continue }
                    if let o = outs.first(where: { $0.id == sp.id }),
                       abs(o.volume - effectiveVolume(sp)) > 12 {
                        // Correct once per DISTINCT echoed value. If the engine
                        // persistently reports a value >12 from intent (its dB
                        // curve vs our volumeLimit clamp), re-nil-ing the cache
                        // every 3s dripped a setVolume command at that device
                        // forever, which can itself destabilize it.
                        if lastReconciledEcho[sp.id] != o.volume {
                            lastReconciledEcho[sp.id] = o.volume
                            if lastSentVolumes[sp.id] != nil {
                                dlog("\(sp.name) volume drift engine=\(o.volume) want=\(effectiveVolume(sp)) -> resend")
                            }
                            lastSentVolumes[sp.id] = nil
                            forceVolumePush = true
                        }
                    }
                }
                if sessionSpeakers().contains(where: {
                    $0.health == .live
                        && !speakerRecoveryInFlight.contains($0.id)
                        && lastSentVolumes[$0.id] == nil
                }) {
                    scheduleVolumePush()
                }
            }
        }
    }

    /// Slow guard while idle: keeps engine and app state honest.
    private func startIdleGuard() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if !phase.isOn { await reconcileEngineState() }
            }
        }
    }

    // MARK: sleep/wake

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .streaming else { return }
                self.wasStreamingBeforeSleep = true
                self.stopStream()
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
                self.startStream()
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

    private func observeNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor in
                guard let self else { return }
                let wasSatisfied = self.pathSatisfied
                self.pathSatisfied = satisfied
                guard self.phase == .streaming, satisfied != wasSatisfied else { return }

                if !satisfied {
                    self.dlog("network path lost while streaming")
                    self.aiEvent("network_lost", level: "warn")
                    self.markHealth(of: self.sessionSpeakers().map(\.id), .connecting)
                } else {
                    // Back on a network — possibly a different one. Re-discover
                    // (output IDs are session-scoped and may have changed) and
                    // rebuild the session rather than waiting for strikes.
                    self.dlog("network path restored -> re-discovering and resuming")
                    self.aiEvent("network_restored")
                    await self.refreshSpeakers()
                    self.resetDriftAnchors()
                    await self.resumePlayback()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dali.network", qos: .utility))
        pathMonitor = monitor
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
