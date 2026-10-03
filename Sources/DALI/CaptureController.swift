// Wires ProcessTap -> FormatConverter -> FIFOWriter inside the app.
// Owns the audio objects; everything here is off the main thread except
// start/stop entry points.
//
// Thread map: the HAL's realtime IO thread only memcpys into a ring (see
// ProcessTap); the tap's consumer thread runs `attachHandler`'s closure
// (convert, resample, account, hand to the FIFO writer); the analysis queue does
// metering; `recoveryQueue` runs rebuilds. `lock` is therefore only ever taken
// by non-realtime threads.

import Foundation
import AVFoundation
import AppKit
import Synchronization

// Injectable hardware seam: tests compile and exercise this production file.
protocol CaptureTap: AnyObject, Sendable {
    var clockAnchored: Bool { get }
    var overrunCount: Int { get }
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onInvalidated: ((String) -> Void)? { get set }
    func start(muteLocal: Bool, source: ProcessTap.Source) throws
    func stop()
}
extension ProcessTap: CaptureTap {}

final class CaptureController: @unchecked Sendable {
    private var tap: (any CaptureTap)?
    private var fifo: FIFOWriter?
    private var fifoPathInUse: String?
    private let lock = NSLock()
    // Hardware work has one owner. stop invalidates synchronously, then queues
    // teardown; it never waits for an in-flight HAL start/stop or consumer.
    private let lifecycleQueue = DispatchQueue(label: "dali.capture.lifecycle")
    private let makeTap: @Sendable () -> any CaptureTap
    private let observeWake: Bool
    private let beforePublish: (@Sendable () -> Void)?
    init(makeTap: @escaping @Sendable () -> any CaptureTap = { ProcessTap() },
         observeWake: Bool = true, beforePublish: (@Sendable () -> Void)? = nil) {
        self.makeTap = makeTap; self.observeWake = observeWake; self.beforePublish = beforePublish
    }
    private var desiredMasterGain = 1.0
    func setMasterGain(_ value: Double) {
        guard value.isFinite else { return }
        lock.lock(); desiredMasterGain = min(max(value, 0), 1); lock.unlock()
    }
    private var sessionGeneration = 0
    var sessionID: Int {
        lock.lock(); defer { lock.unlock() }
        return sessionGeneration
    }
    private var _isRunning = false
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _isRunning }

    /// Monotonic seconds that keep counting through sleep and are immune to wall
    /// clock steps (NTP, DST, manual change), unlike Date().
    private static func monoNow() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    // SELF-HEALING (see requestRecovery). Device-change / wake / stall events all
    // funnel into ONE single-flight, spaced, backed-off rebuild instead of each
    // subsystem rebuilding on its own.
    private let recoveryQueue = DispatchQueue(label: "dali.capture.recovery")
    private var recoveryScheduled = false
    private var recoveryFailures = 0
    private var lastRecoveryMono = -1000.0
    private var stallAttempts = 0
    private var activeToken = 0
    private var startParams: (fifoPath: String, muteLocal: Bool, source: ProcessTap.Source)?
    private var wakeObserver: NSObjectProtocol?
    private var recoveriesAcc = 0
    /// Diagnostic hook for the flight log / analytics ("device_change: ...").
    /// Called on the recovery queue.
    var onEvent: ((String) -> Void)?
    // Analysis blocks queued but not yet run. Bounded so a starved analysis
    // queue can never build an unbounded pile of retained buffers.
    private let analysisBacklog = Atomic<Int>(0)

    // OwnTone's pipe playback needs a CONTINUOUS, REAL-TIME byte stream: it plays
    // exactly 44100*4 bytes per wall-clock second and trusts that contract. We
    // pin the TOTAL bytes written to elapsed wall-clock by topping up with
    // silence, so audio-time never drifts from real time (drift caused the
    // slow-building stutters/stops).
    private var silenceTimer: DispatchSourceTimer?
    private var lastBufferMono = 0.0             // monotonic secs of last tap buffer, 0 = none yet
    private var lastFillMono = 0.0               // monotonic secs of last silence top-up
    private var feedingSilence = false
    // (The Varispeed resampler is owned by the consumer thread's handler closure,
    // not shared state: its only caller is that thread, so it needs no lock.)
    // The drift-control ratio is computed once per second by DALIStore's flight
    // loop from OwnTone's REAL drain/playback clock (the only observable speaker
    // clock) and pushed in here. The audio thread just applies it. This replaces
    // the old per-buffer loop that steered off pendingBytes, which is blind to
    // OwnTone's internal buffers and so pinned the ratio at its floor forever.
    private var targetRatio = 1.0
    /// The ratio actually handed to the resampler: `targetRatio` approached at no
    /// more than `driftSlewPerSec`, per buffer, so no caller can ever step it.
    private var appliedRatio = 1.0
    private var lastRatio = 1.0
    private var bytesWritten = 0
    private static let bytesPerSecond = 44_100 * 2 * 2   // s16le, 2ch
    private var converterInputRate: Double = 0

    // HARD AUTHORITY RAIL for drift correction, as a fraction of rate.
    //
    // Sized from measurement, not from theory. With the varispeed pinned at
    // exactly 1.0 (drift=+0.00% on every flight line), a 553 s session on this
    // Mac measured the producer/consumer mismatch three independent ways:
    //   * item_progress_ms vs wall clock ....... -4011 ppm
    //   * d(fill)/dt ........................... +4069 ppm
    //   * engine's own `clock - pts` slope ...... +2979 ppm
    // So the plant needs ~0.4% of authority. This is NOT crystal skew (10-100
    // ppm); it is OwnTone's 10 ms setitimer player tick running slightly long,
    // so the pipe is drained ~0.4% slower than real time. A ±0.3% rail would be
    // permanently saturated AND still leak ~1000 ppm (3.6 s of latency per
    // hour), so it would not solve the bug.
    //
    // 0.5% = 8.7 cents of pitch — below the ~10 cent threshold at which a
    // trained ear notices an offset with a reference to compare against, and
    // there is no reference when streaming. It is also BELOW the old ±0.6%
    // rail, so the worst case is strictly better than what shipped before.
    static let driftRail = 0.005
    // Bit-transparency deadzone. Corrections under 200 ppm (0.35 cents) are
    // musically meaningless and cost 0.72 s of latency per hour, which the
    // start buffer absorbs indefinitely. Snapping them to exactly 1.0 makes
    // Varispeed take its bit-perfect passthrough branch, so a machine whose
    // engine tick happens to be honest never resamples at all.
    static let driftDeadzone = 0.0002
    // Hard slew rail on the ratio itself, in ratio units per second of AUDIO. The
    // refill controller already slews its command (0.25% over 8 s = 0.0003/s);
    // this is the last line of defence that keeps ANY change continuous — a
    // cut back to exactly 1.0 after a stream restart takes 0.0025/0.0005 = 5 s
    // instead of stepping 4 cents at once. At rest (target 1.0) it is inert and
    // the resampler stays on its bit-exact passthrough branch.
    static let driftSlewPerSec = 0.0005

    // Byte-weighted accounting of the correction we ACTUALLY applied this
    // interval. The commanded ratio is not the applied ratio: the silence
    // keepalive writes wall-clock-paced zeros that bypass the varispeed, so a
    // mostly-silent interval dilutes the correction toward zero. The drift loop
    // gates on this rather than trusting its own command.
    private var corrByteSum = 0.0     // Σ (ratio-1) * bytes
    private var corrByteTot = 0.0     // Σ bytes through the varispeed
    private var silenceBytesAcc = 0   // keepalive zeros written this interval
    private var tapRebuildAcc = 0     // tap rebuilds since the last readMetrics
    private var lastMetricsMono = CaptureController.monoNow()

    // Visualization levels (read by the UI at ~30Hz). Updated off the audio
    // thread on a dedicated analysis queue so the realtime capture path does
    // only convert + write, never DSP under a contended lock.
    // userInitiated, not utility: the source-silence mute and the beat clock ride
    // on this queue, and a utility thread starves under load exactly when the
    // room needs it.
    private let analysisQueue = DispatchQueue(label: "dali.analysis", qos: .userInitiated)
    private var _level: Double = 0
    private var _bass: Double = 0
    private var _treble: Double = 0
    // Running loudness reference per band, in dB. The room's light is scaled
    // against the music's own recent peak rather than full scale, so a quiet
    // record swings as much as a loud one and a beat is a beat either way.
    private var refDb: (level: Double, bass: Double, treble: Double) = (-45, -45, -45)
    /// Running average loudness per band, in dB. A beat is a buffer that stands
    /// clearly ABOVE this — which is what makes the room move with the music
    /// instead of sitting at full brightness all the time.
    private var slowDb: (level: Double, bass: Double, treble: Double) = (-45, -45, -45)
    private var levelPrimed = false
    // Peak since the UI last read. The panel polls at ~30 Hz and a transient
    // decays inside that window, so without this the canvas saw noise, not beats.
    private var peakSinceRead: (level: Double, bass: Double, treble: Double) = (0, 0, 0)
    /// Monotonic count of detected beats (bass onsets), with a refractory gap so
    /// one kick is one beat.
    private var _beatCount = 0
    private var lastLevelAt: Date?
    private var lastBeatWallAt: Date?
    private var audioClock = 0.0        // seconds of audio seen, monotonic
    private var lastBeatAt = -1.0
    private var lpSlow: Double = 0
    private var lpMid: Double = 0

    // Flight-recorder capture metrics (reset by readMetrics each interval).
    private var bufCount = 0          // tap buffers this interval
    private var maxGapMs = 0.0        // largest gap between tap buffers this interval
    private var convRebuilds = 0      // converter rebuilds (rate changes) this interval
    private var inFrames = 0          // input frames consumed this interval
    private var outBytes = 0          // bytes produced (post-convert) this interval
    private var lastTapNs: UInt64 = 0
    private var staleConversions = 0
    private var overrunsSeen = 0      // tap ring overruns already reported

    // ZERO-BUFFER CANARY.
    // Core Audio process taps are documented to enter a state where the IOProc
    // keeps firing at normal cadence with correct mHostTime/mSampleTime and a
    // normal mDataByteSize, but EVERY sample is exactly zero (Apple Developer
    // Forums thread 825780, unanswered; correlated with 44.1<->48kHz
    // renegotiation and Bluetooth state changes). Reported runs last from ~50s
    // to 16 minutes. It is indistinguishable from real silence through the API,
    // and the ONLY reliable recovery is a full teardown of BOTH the tap and its
    // aggregate — which is exactly what rebuild() does.
    //
    // We count CONSECUTIVE all-zero buffers rather than elapsed time, so a tap
    // that has simply gone idle (no buffers at all) never trips it. Rebuilding
    // during genuine digital silence is inaudible, so acting on suspicion is
    // cheap — BUT the anchored aggregate delivers zero-buffers continuously when
    // the Mac plays nothing, so an unconditional counter would rebuild the tap
    // in a loop all night during idle streaming. Gate: only treat a zero-run as
    // suspicious if we have heard real audio since the last (re)build. Idle
    // sessions never rebuild; a stream that WAS playing and goes all-zero for
    // ~10s is either true silence (rebuild inaudible) or the bug (rebuild fixes).
    private var zeroBufferRun = 0
    /// Seconds of unbroken digital silence seen from the tap.
    private var silentSec = 0.0
    private var sourceSilent = false
    /// How long the source must be silent before we call it stopped.
    private static let silenceCutDelaySec = 0.20
    /// Fired on the main actor when the source starts or stops producing audio.
    /// `true` = gone silent, `false` = audio is back.
    var onSourceSilenceChanged: ((Bool) -> Void)?
    private var heardAudioSinceBuild = false
    /// Consecutive all-zero tap buffers. ~94 buffers/sec, so 1000 ≈ 10.6s.
    var zeroBufferStreak: Int { lock.lock(); defer { lock.unlock() }; return zeroBufferRun }
    var heardAudio: Bool { lock.lock(); defer { lock.unlock() }; return heardAudioSinceBuild }
    var digitalSilenceSeconds: Double { lock.lock(); defer { lock.unlock() }; return silentSec }
    /// Wall-clock seconds since the tap last delivered ANY buffer. The zero
    /// canary counts buffers that arrive; this watchdog covers buffers that
    /// STOP arriving (anchor device unplugged, tap start silently failed).
    var secondsSinceLastBuffer: Double {
        lock.lock(); defer { lock.unlock() }
        guard lastBufferMono > 0 else { return 0 }
        return max(0, Self.monoNow() - lastBufferMono)
    }

    /// One consistent reading for the room canvas: the peak of each band since
    /// the last call (so a transient between two 30 Hz polls is not lost), plus
    /// the beat counter. Consuming — call it once per UI tick and no more.
    func readLevels() -> (at: Date?, level: Double, bass: Double, treble: Double,
                          beats: Int, beatAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        let v = (lastLevelAt,
                 max(_level, peakSinceRead.level),
                 max(_bass, peakSinceRead.bass),
                 max(_treble, peakSinceRead.treble),
                 _beatCount, lastBeatWallAt)
        peakSinceRead = (0, 0, 0)
        return v
    }

    var level: Double {
        lock.lock(); defer { lock.unlock() }
        return max(_level, peakSinceRead.level)
    }
    var bands: (bass: Double, treble: Double) {
        lock.lock(); defer { lock.unlock() }
        return (max(_bass, peakSinceRead.bass), max(_treble, peakSinceRead.treble))
    }
    /// Whether the live tap's aggregate is anchored to a real device clock
    /// (see ProcessTap.clockAnchored). For the stream-start log line.
    var isClockAnchored: Bool { lock.lock(); defer { lock.unlock() }; return tap?.clockAnchored ?? false }

    var stats: (written: Int, dropped: Int, peakPending: Int, pending: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard let f = fifo else { return (0, 0, 0, nil) }
        return (f.writtenBytes, f.droppedBytes, f.peakPending, f.pendingBytes)
    }

    /// Total bytes handed to the kernel pipe so far (post-varispeed). Compared by
    /// the flight loop against OwnTone's playback progress to estimate the true,
    /// otherwise-invisible end-to-end backlog.
    var totalWritten: Int { lock.lock(); defer { lock.unlock() }; return fifo?.writtenBytes ?? 0 }

    /// Set the varispeed drift-correction ratio (input frames consumed per output
    /// frame). >1 drains backlog (produce fewer frames), <1 fills it. Computed
    /// once/sec by DALIStore from OwnTone's real drain + playback clock.
    /// The rail is enforced HERE, at the point of use, not only at the caller:
    /// this is the last line of defence, so no future controller bug — however
    /// wound up — can command more than ±driftRail of pitch. Non-finite input
    /// (NaN from a divide-by-zero upstream) is rejected outright rather than
    /// propagated into the resampler, where it would poison the carry history.
    func setTargetRatio(_ r: Double) {
        guard r.isFinite else { return }
        lock.lock()
        targetRatio = min(max(r, 1.0 - Self.driftRail), 1.0 + Self.driftRail)
        lock.unlock()
    }

    /// Detailed flight-recorder snapshot, consumed once per interval (resets the
    /// per-interval counters). Everything needed to see WHY a glitch happened.
    struct Flight {
        var written = 0, dropped = 0, pending = 0, eagain = 0
        var bufCount = 0, maxGapMs = 0.0, convRebuilds = 0, inFrames = 0, outBytes = 0
        var inRate = 0.0   // device input sample rate seen
        var ratio = 1.0    // current varispeed ratio (drift correction)
        /// Wall seconds actually elapsed since the previous readMetrics(). The
        /// flight loop sleeps 1 s and THEN makes two HTTP calls, so its period
        /// is 1 s + API latency and varies by several percent poll to poll.
        /// Every rate in the log used to be silently divided by a nominal 1.0 s,
        /// which is why `produce=103.5%` in the old log was measuring loop
        /// jitter rather than audio. The drift loop needs a real dt.
        var intervalSec = 1.0
        /// Keepalive silence written this interval. These bytes are paced by the
        /// wall clock and bypass the varispeed entirely, so they dilute the
        /// applied correction.
        var silenceBytes = 0
        /// Tap rebuilds since the last read: a hard capture discontinuity.
        var tapRebuilds = 0
        /// Byte-weighted mean of the correction actually applied to audio this
        /// interval, as a fraction (0.004 = +0.4%). Differs from `ratio` when
        /// the ratio moved mid-interval or silence diluted it.
        var appliedCorr = 0.0
        /// Ring overflow, expired records and late conversions this interval.
        /// Nonzero means downstream capture work fell behind and lost audio.
        var tapOverruns = 0
        /// Self-healing tap rebuilds (device change / wake / stall) this interval.
        var recoveries = 0
    }
    func readMetrics() -> Flight {
        lock.lock(); defer { lock.unlock() }
        var f = Flight()
        if let t = tap {
            let o = t.overrunCount
            f.tapOverruns = max(0, o - overrunsSeen)
            overrunsSeen = o
        }
        f.tapOverruns += staleConversions; staleConversions = 0
        f.recoveries = recoveriesAcc; recoveriesAcc = 0
        if let fw = fifo { f.written = fw.writtenBytes; f.dropped = fw.droppedBytes; f.pending = fw.pendingBytes; f.eagain = fw.eagainCount }
        f.bufCount = bufCount; f.maxGapMs = maxGapMs; f.convRebuilds = convRebuilds
        f.inFrames = inFrames; f.outBytes = outBytes; f.inRate = converterInputRate
        f.ratio = lastRatio
        f.silenceBytes = silenceBytesAcc
        f.tapRebuilds = tapRebuildAcc
        let total = corrByteTot + Double(silenceBytesAcc)
        f.appliedCorr = total > 0 ? corrByteSum / total : 0
        let now = Self.monoNow()
        f.intervalSec = max(0.001, now - lastMetricsMono)
        lastMetricsMono = now
        bufCount = 0; maxGapMs = 0; convRebuilds = 0; inFrames = 0; outBytes = 0
        corrByteSum = 0; corrByteTot = 0; silenceBytesAcc = 0; tapRebuildAcc = 0
        return f
    }

    /// Synchronous entry point for non-UI callers and the isolated harness.
    func start(fifoPath: String, muteLocal: Bool = false,
               source: ProcessTap.Source = .system) throws {
        let requested = lock.withLock { sessionGeneration }
        try lifecycleQueue.sync {
            try startOwned(fifoPath: fifoPath, muteLocal: muteLocal, source: source, requestedSession: requested)
        }
    }
    func startAsync(fifoPath: String, muteLocal: Bool = false,
                    source: ProcessTap.Source = .system) async throws {
        let requested = lock.withLock { sessionGeneration }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lifecycleQueue.async { [self] in
                do {
                    try startOwned(fifoPath: fifoPath, muteLocal: muteLocal, source: source, requestedSession: requested)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func startOwned(fifoPath: String, muteLocal: Bool, source: ProcessTap.Source,
                            requestedSession: Int) throws {
        lock.lock()
        guard sessionGeneration == requestedSession else { lock.unlock(); throw CancellationError() }
        guard !_isRunning else { lock.unlock(); return }
        sessionGeneration &+= 1
        activeToken &+= 1
        let session = sessionGeneration
        let token = activeToken
        let pipe = FIFOWriter(path: fifoPath)
        let staleFifo = fifo
        pipe.beginGeneration(token)
        fifo = pipe; fifoPathInUse = fifoPath
        _isRunning = true
        lastFillMono = Self.monoNow(); bytesWritten = 0
        lastBufferMono = lastFillMono
        startParams = (fifoPath, muteLocal, source)
        stallAttempts = 0; recoveryFailures = 0; recoveryScheduled = false
        overrunsSeen = 0
        lock.unlock()
        staleFifo?.closePipe()
        let candidate = makeTap()
        attachHandler(to: candidate, pipe: pipe, token: token)
        do {
            try candidate.start(muteLocal: muteLocal, source: source)
            lock.lock()
            guard sessionGeneration == session, activeToken == token, _isRunning else {
                lock.unlock(); throw CancellationError()
            }
            tap = candidate
            startSilenceKeepaliveLocked(session: session)
            lock.unlock()
            installWakeObserver()
        } catch {
            candidate.stop(); pipe.closePipe()
            lock.lock()
            if sessionGeneration == session, activeToken == token {
                _isRunning = false; tap = nil; fifo = nil; fifoPathInUse = nil; startParams = nil
            }
            lock.unlock()
            throw error
        }
    }

    /// Swap the TAP only (source / mute change) while keeping the same FIFO and
    /// silence timer alive, so the pipe never loses its writer and OwnTone never
    /// sees an EOF. No teardown, no zero-writer gap.
    @discardableResult
    ///
    /// `keepRunningOnFailure` is for the self-healing path: a failed rebuild then
    /// leaves the session "running" (tap nil, keepalive silence flowing) so the
    /// caller's backoff retries and DALIStore's watchdog can still see it. The
    /// default (false) keeps the original contract for external callers.
    func rebuild(fifoPath: String, muteLocal: Bool, source: ProcessTap.Source,
                 expectedSession: Int? = nil, keepRunningOnFailure: Bool = false) -> Bool {
        let requested = expectedSession ?? lock.withLock { sessionGeneration }
        return lifecycleQueue.sync {
            rebuildOwned(fifoPath: fifoPath, muteLocal: muteLocal, source: source,
                         expectedSession: requested, keepRunningOnFailure: keepRunningOnFailure)
        }
    }
    func rebuildAsync(fifoPath: String, muteLocal: Bool, source: ProcessTap.Source,
                      expectedSession: Int? = nil, keepRunningOnFailure: Bool = false) async -> Bool {
        let requested = expectedSession ?? lock.withLock { sessionGeneration }
        return await withCheckedContinuation { continuation in
            lifecycleQueue.async { [self] in
                continuation.resume(returning: rebuildOwned(fifoPath: fifoPath, muteLocal: muteLocal,
                    source: source, expectedSession: requested, keepRunningOnFailure: keepRunningOnFailure))
            }
        }
    }
    private func rebuildOwned(fifoPath: String, muteLocal: Bool, source: ProcessTap.Source,
                              expectedSession: Int, keepRunningOnFailure: Bool) -> Bool {
        lock.lock()
        guard _isRunning, let pipe = fifo,
              expectedSession == sessionGeneration,
              fifoPath == fifoPathInUse else { lock.unlock(); return false }
        let session = sessionGeneration
        let oldTap = tap
        tap = nil
        startParams = (fifoPath, muteLocal, source)
        activeToken &+= 1
        recoveryScheduled = false
        let token = activeToken
        pipe.beginGeneration(token)
        overrunsSeen = 0; lastRecoveryMono = Self.monoNow()
        converterInputRate = 0; tapRebuildAcc += 1
        zeroBufferRun = 0; silentSec = 0
        let wasSilent = sourceSilent
        sourceSilent = false; heardAudioSinceBuild = false
        feedingSilence = false
        lastFillMono = Self.monoNow(); lastBufferMono = lastFillMono
        lock.unlock()
        if wasSilent { reportSourceSilence(false, token: token) }
        // Consumer cancellation is not a join guarantee. Its local converter
        // may finish, but the old token can no longer publish PCM or metrics.
        oldTap?.stop()
        lock.lock(); let current = _isRunning && activeToken == token && sessionGeneration == session; lock.unlock()
        guard current else { return false }
        let candidate = makeTap()
        attachHandler(to: candidate, pipe: pipe, token: token)
        do {
            try candidate.start(muteLocal: muteLocal, source: source)
            lock.lock()
            guard _isRunning, activeToken == token, sessionGeneration == session else {
                lock.unlock(); candidate.stop(); return false
            }
            tap = candidate; lock.unlock()
            return true
        } catch {
            candidate.stop()
            lock.lock()
            if sessionGeneration == session, activeToken == token {
                if !keepRunningOnFailure { _isRunning = false }
                tap = nil
            }
            lock.unlock()
            return false
        }
    }

    // MARK: self-healing

    /// Funnel for every "the tap is probably stale" signal: HAL invalidation
    /// (default output changed, rate change, aggregate died, coreaudiod restart),
    /// wake from sleep, and callbacks that stopped arriving. SINGLE-FLIGHT (one
    /// pending recovery at a time, extra requests coalesce), SPACED (never sooner
    /// than 3 s after the previous rebuild, doubling per consecutive failure up to
    /// 30 s), so a flapping device cannot turn into a rebuild storm.
    private func requestRecovery(_ reason: String, after delay: TimeInterval, token: Int? = nil, session: Int? = nil) {
        lock.lock()
        guard _isRunning, !recoveryScheduled, token == nil || token == activeToken,
              session == nil || session == sessionGeneration else { lock.unlock(); return }
        recoveryScheduled = true
        let session = sessionGeneration
        let recoveryToken = activeToken
        let spacing = min(3.0 * pow(2.0, Double(min(recoveryFailures, 4))), 30.0)
        let sinceLast = Self.monoNow() - lastRecoveryMono
        lock.unlock()
        let wait = max(delay, spacing - sinceLast)
        recoveryQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.runRecovery(reason: reason, session: session, token: recoveryToken)
        }
    }

    private func runRecovery(reason: String, session: Int, token: Int) {
        lock.lock()
        guard _isRunning, sessionGeneration == session, activeToken == token, let p = startParams else {
            lock.unlock(); return
        }
        recoveryScheduled = false
        lock.unlock()
        // After sleep the HAL usually needs a rebuild, but if buffers are already
        // flowing again the tap survived and rebuilding would only splice a gap.
        if reason == "wake", secondsSinceLastBuffer < 0.5 {
            onEvent?("capture_recovery_skipped: wake, tap healthy")
            return
        }
        onEvent?("capture_recovery: \(reason)")
        FileHandle.standardError.write(Data("CaptureController: rebuilding tap (\(reason))\n".utf8))
        let ok = lifecycleQueue.sync {
            guard lock.withLock({ _isRunning && activeToken == token && sessionGeneration == session }) else { return false }
            return rebuildOwned(fifoPath: p.fifoPath, muteLocal: p.muteLocal, source: p.source,
                                expectedSession: session, keepRunningOnFailure: true)
        }
        lock.lock()
        let stillOurs = _isRunning && sessionGeneration == session && activeToken == token &+ 1
        guard stillOurs else { lock.unlock(); return }
        recoveriesAcc += 1
        if ok { recoveryFailures = 0 } else if stillOurs { recoveryFailures += 1 }
        let failures = recoveryFailures
        lock.unlock()
        if !ok && stillOurs {
            let backoff = min(2.0 * pow(2.0, Double(min(failures - 1, 4))), 30.0)
            onEvent?("capture_recovery_failed: retry in \(Int(backoff))s")
            requestRecovery("retry after failed rebuild", after: backoff, token: token &+ 1)
        }
    }

    private func installWakeObserver() {
        guard observeWake, wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Devices reappear a beat after the wake notification.
            self?.requestRecovery("wake", after: 2.5)
        }
    }

    private func removeWakeObserver() {
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
    }

    /// Install the capture callback: convert, account, write, and hand a copy to
    /// the analysis queue for the visualization. The audio thread does no DSP.
    private func attachHandler(to tap: any CaptureTap, pipe: FIFOWriter, token: Int) {
        // The HAL reconfigured under the tap (default output moved, rate change,
        // aggregate died, coreaudiod restarted). Only the CURRENT tap's events count.
        tap.onInvalidated = { [weak self] reason in
            guard let self else { return }
            self.lock.lock(); let current = self.activeToken == token; self.lock.unlock()
            if current { self.requestRecovery(reason, after: 1.0, token: token) }
        }
        // Consumer-thread state (one thread per tap, so no locking needed).
        var conv: FormatConverter?
        var varispeed = Varispeed()          // smooth drift control
        tap.onBuffer = { [weak self] buffer in
            guard let self else { return }
            let conversionBegan = Self.monoNow()
            self.lock.lock()
            guard self._isRunning, self.activeToken == token else { self.lock.unlock(); return }
            let gain = self.desiredMasterGain
            self.lock.unlock()
            var rebuilt = false
            // Rebuild the converter if the device's mix rate or layout changed
            // mid-session (AirPods / DAC switching the rate); feeding 48k
            // through a 44.1k converter would corrupt timing.
            if conv == nil || !(conv!.accepts(buffer.format)) {
                conv = FormatConverter(from: buffer.format, initialGain: conv?.appliedMasterGain ?? gain)
                // The new converter is a fresh resampler with no relation to the
                // previous stream's last frame; reset varispeed so it doesn't
                // interpolate a click across the discontinuity.
                varispeed.reset()
                rebuilt = true
            }
            guard let converted = conv?.convert(buffer, masterGain: gain) else { return }
            let sourceHasAudio = !(conv?.outputWasSilent ?? true)
            // SMOOTH DRIFT CONTROL: resample by a hair to match the AirPlay speaker
            // clock. The ratio is set once/sec by the flight loop from OwnTone's
            // REAL drain + playback clock (setTargetRatio), so it tracks the actual
            // hidden backlog instead of the always-zero app-side pending buffer.
            self.lock.lock()
            guard self._isRunning, self.activeToken == token else { self.lock.unlock(); return }
            let dtBuf = min(max(Double(buffer.frameLength) / max(buffer.format.sampleRate, 1), 0), 0.25)
            let maxStep = Self.driftSlewPerSec * dtBuf
            if self.appliedRatio < self.targetRatio {
                self.appliedRatio = min(self.appliedRatio + maxStep, self.targetRatio)
            } else if self.appliedRatio > self.targetRatio {
                self.appliedRatio = max(self.appliedRatio - maxStep, self.targetRatio)
            }
            let rawRatio = self.appliedRatio
            self.lock.unlock()
            // Bit-transparency deadzone (see driftDeadzone): sub-200 ppm
            // corrections snap to exactly 1.0 so the varispeed takes its
            // bit-perfect passthrough branch and never resamples audio it
            // cannot audibly improve.
            let ratio = abs(rawRatio - 1.0) < Self.driftDeadzone ? 1.0 : rawRatio
            let data = varispeed.process(converted, ratio: ratio)
            guard !data.isEmpty else { return }

            self.beforePublish?()
            let now = DispatchTime.now().uptimeNanoseconds
            self.lock.lock()
            guard self._isRunning, self.activeToken == token else { self.lock.unlock(); return }
            // A consumer/converter stall must not turn old PCM into "fresh"
            // audio merely because it reached FIFO admission late.
            let finishedAt = Self.monoNow()
            guard finishedAt - conversionBegan <= 0.25 else {
                self.staleConversions += 1; self.lock.unlock(); return
            }
            self.lastBufferMono = finishedAt
            self.stallAttempts = 0            // callbacks are alive: re-arm the stall watchdog
            let session = self.sessionGeneration
            self.bytesWritten += data.count
            self.lastRatio = ratio
            self.corrByteSum += (ratio - 1.0) * Double(data.count)
            self.corrByteTot += Double(data.count)
            if self.lastTapNs != 0, now >= self.lastTapNs {   // UInt64 subtraction traps on underflow
                let gap = Double(now - self.lastTapNs) / 1_000_000
                if gap > self.maxGapMs { self.maxGapMs = gap }
            }
            self.lastTapNs = now
            self.bufCount += 1
            self.inFrames += Int(buffer.frameLength)
            self.outBytes += data.count
            if rebuilt { self.convRebuilds += 1; self.converterInputRate = buffer.format.sampleRate }
            // Publish under the token lock so rebuild/stop cannot occur between
            // validation and writing into a pipe shared by the replacement tap.
            pipe.write(data, generation: token)
            self.lock.unlock()
            let capturedAt = Date()
            if self.analysisBacklog.load(ordering: .relaxed) < 8 {
                _ = self.analysisBacklog.wrappingAdd(1, ordering: .relaxed)
                self.analyze(data, capturedAt: capturedAt, session: session, token: token, sourceHasAudio: sourceHasAudio)
            }
        }
    }

    /// Loudness + band split for the room visualization, off the audio thread.
    private func analyze(_ data: Data, capturedAt: Date, session: Int, token: Int, sourceHasAudio: Bool) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            defer { _ = self.analysisBacklog.wrappingSubtract(1, ordering: .relaxed) }
            self.lock.lock()
            let current = self._isRunning && self.sessionGeneration == session && self.activeToken == token
            self.lock.unlock()
            guard current else { return }
            // Zero-buffer canary (see zeroBufferRun). Early-exits on the first
            // non-zero sample, so on real audio this is a couple of comparisons.
            let anyNonZero = sourceHasAudio
            // SOURCE-SILENCE DETECTOR — how instant cut-off works for anything
            // that is not a browser video.
            //
            // The extension can tell us a YouTube video stopped, but nothing can
            // tell us Spotify, Apple Music or a game did. The tap can: when the
            // source stops, it delivers literal zeros, and that is a fact about
            // every app on the machine at once.
            //
            // Acting on it is safe in a way that flushing never was. We only
            // MUTE, and muting during genuine digital silence is by definition
            // inaudible — the worst case for a false positive is that we silence
            // silence. A quiet passage is not silence: music sits far above zero
            // even at its quietest, so this cannot fire on a fade or a rest.
            //
            // The delay before acting exists for gapless-ish sources that emit a
            // handful of zero buffers between tracks. 200 ms is long enough to
            // ride over those and short enough that the ~1 s tail is cut before
            // you register it as still playing.
            let secs = Double(data.count) / 176_400.0
            var flipped: Bool? = nil
            self.lock.lock()
            guard self._isRunning, self.sessionGeneration == session, self.activeToken == token else { self.lock.unlock(); return }
            if anyNonZero {
                self.zeroBufferRun = 0; self.heardAudioSinceBuild = true
                self.silentSec = 0
                if self.sourceSilent { self.sourceSilent = false; flipped = false }
            } else {
                self.zeroBufferRun += 1
                self.silentSec += secs
                if !self.sourceSilent && self.silentSec >= Self.silenceCutDelaySec {
                    self.sourceSilent = true; flipped = true
                }
            }
            let oldLpSlow = self.lpSlow, oldLpMid = self.lpMid
            self.lock.unlock()
            // Resuming is reported on the FIRST non-zero buffer — no delay at
            // all. Being slow to un-mute would be audible; being slow to mute is
            // only ever inaudible.
            if let f = flipped { self.reportSourceSilence(f, token: token) }

            let (instant, bass, treble, lpSlow, lpMid) = data.withUnsafeBytes { raw -> (Double, Double, Double, Double, Double) in
                let s16 = raw.bindMemory(to: Int16.self)
                guard !s16.isEmpty else { return (0, 0, 0, oldLpSlow, oldLpMid) }
                var sumSq = 0.0, bassAcc = 0.0, trebAcc = 0.0, n = 0.0
                var lpS = oldLpSlow, lpM = oldLpMid
                var i = 0
                while i < s16.count {
                    let x = Double(s16[i]) / 32768.0
                    sumSq += x * x
                    // One-pole coefficients at the DECIMATED rate (every 4th
                    // frame, left channel ≈ 11 kHz): 0.066 ≈ 120 Hz, which is
                    // where kick and bass actually live. The old 0.018 was a
                    // 32 Hz corner — under the music, so the "bass" band was
                    // reading sub-sonic rumble and barely moved.
                    lpS += 0.066 * (x - lpS)
                    lpM += 0.55 * (x - lpM)
                    bassAcc += lpS * lpS
                    let hi = x - lpM
                    trebAcc += hi * hi
                    n += 1
                    i += 8                                   // decimate, left channel-ish
                }
                func db(_ acc: Double) -> Double {
                    guard n > 0 else { return -120 }
                    let rms = (acc / n).squareRoot()
                    return rms > 0 ? 20 * log10(rms) : -120
                }
                return (db(sumSq), db(bassAcc), db(trebAcc), lpS, lpM)
            }
            self.lock.lock()
            guard self._isRunning, self.sessionGeneration == session, self.activeToken == token else { self.lock.unlock(); return }
            self.lpSlow = lpSlow; self.lpMid = lpMid
            // A level that IS the music, not a loudness meter.
            //
            // Measured over two real tracks, the old purely-loudness reading sat
            // at a median of 1.00 with a p10–p90 swing of 0.26: pinned at the top,
            // so the room glowed at full reach whatever was playing. Two parts fix
            // that, and the mix was chosen against those measurements (median
            // ~0.64, swing ~0.7):
            //
            //   loud  — how close this buffer is to the record's own recent peak
            //           (peak-hold reference letting go at ~6 dB/s, 20 dB window).
            //           Keeps a sustained loud passage lit.
            //   onset — how far this buffer stands ABOVE the running average of
            //           the last second. Zero most of the time, 1 on a hit. This
            //           is the part the eye reads as "on the beat".
            // 176400 bytes/s = 44.1 kHz, stereo, 16-bit. ~10.5 ms per buffer.
            let dt = data.count > 0 ? Double(data.count) / 176_400.0 : 0.0105
            let aSlow = 1 - exp(-dt / 1.0)
            func band(_ x: Double, _ slow: inout Double, _ ref: inout Double) -> (Double, Double) {
                let d = max(x, -90)
                if !self.levelPrimed { slow = d; ref = d }
                slow += (d - slow) * aSlow
                ref = max(d, ref - 0.07, -45)
                let loud = max(0, min(1, 1 + (d - ref) / 20))
                let onset = max(0, min(1, (d - slow) / 5))
                return (max(0, min(1, 0.28 * loud + 0.72 * onset)), onset)
            }
            let (l, _) = band(instant, &self.slowDb.level, &self.refDb.level)
            let (b, bOnset) = band(bass, &self.slowDb.bass, &self.refDb.bass)
            let (t, _) = band(treble, &self.slowDb.treble, &self.refDb.treble)
            self.levelPrimed = true
            self.lastLevelAt = capturedAt

            // The beat: a clear bass onset, at most one per 220 ms.
            self.audioClock += dt
            if bOnset > 0.55, self.audioClock - self.lastBeatAt > 0.22 {
                self.lastBeatAt = self.audioClock
                self._beatCount &+= 1
                self.lastBeatWallAt = capturedAt
            }
            // Instant attack, release fast enough that a beat is a beat.
            self._level = l > self._level ? l : self._level * 0.86 + l * 0.14
            self._bass = b > self._bass ? b : self._bass * 0.82 + b * 0.18
            self._treble = t > self._treble ? t : self._treble * 0.84 + t * 0.16
            self.peakSinceRead = (max(self.peakSinceRead.level, l),
                                  max(self.peakSinceRead.bass, b),
                                  max(self.peakSinceRead.treble, t))
            self.lock.unlock()
        }
    }

    private func reportSourceSilence(_ silent: Bool, token: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cb = self.lock.withLock {
                self._isRunning && self.activeToken == token ? self.onSourceSilenceChanged : nil
            }
            cb?(silent)
        }
    }

    // Caller holds lock. The session guard also rejects an already-fired tick
    // from a cancelled timer after a later start.
    private func startSilenceKeepaliveLocked(session: Int) {
        guard silenceTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dali.silence"))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock()
            // A tick that was already running when stop() cancelled us must not
            // touch the freshly reset state.
            guard sessionGeneration == session, let f = fifo, _isRunning, lastBufferMono > 0 else { lock.unlock(); return }
            let now = Self.monoNow()
            // Start a forward-paced keepalive promptly if the tap stops calling.
            // Never backfill the historical gap: those late zeros cannot repair
            // past audio and only queue ahead of newly resumed sound.
            let stalled = now - lastBufferMono
            let quiet = stalled > 0.12
            var fill = 0
            if quiet {
                let quantum = Self.bytesPerSecond / 20     // 50 ms
                if !feedingSilence {
                    feedingSilence = true
                    lastFillMono = now
                    fill = quantum
                } else {
                    // Clamp before the Double->Int conversion: Int(x) traps on
                    // NaN/overflow, and a wild clock delta must not be able to.
                    let gap = min(max(now - lastFillMono, 0), 1.0)
                    var bytes = Int(gap * Double(Self.bytesPerSecond))
                    bytes -= bytes % 4
                    fill = min(max(bytes, 0), quantum)
                    if fill > 0 {
                        lastFillMono += Double(fill) / Double(Self.bytesPerSecond)
                    }
                }
            } else {
                feedingSilence = false
                lastFillMono = lastBufferMono
            }
            if fill > 0 { bytesWritten += fill; silenceBytesAcc += fill }
            // Queue the zero block before releasing the same lock used by the
            // real-audio callback. This guarantees resumed PCM cannot overtake
            // an already-decided silence write.
            if fill > 0 { f.write(Data(count: fill)) }
            // STALL WATCHDOG. The tap is "running" but its callbacks stopped
            // (HAL reconfigured, sleep/wake, permission flip). Rebuild it from
            // here after 4 s, then 8 s; after that DALIStore's own >10 s
            // watchdog escalates to a full stream restart.
            var stallReason: String?
            if tap != nil, !recoveryScheduled, stallAttempts < 2,
               stalled > 4.0 * pow(2.0, Double(stallAttempts)) {
                stallAttempts += 1
                stallReason = String(format: "no tap callbacks for %.0fs", stalled)
            }
            lock.unlock()
            if let stallReason { requestRecovery(stallReason, after: 0, session: session) }
        }
        t.resume()
        silenceTimer = t
    }

    func stop() {
        lock.lock()
        let oldTap = tap, oldFifo = fifo
        let timer = silenceTimer
        silenceTimer = nil
        sessionGeneration &+= 1; activeToken &+= 1
        tap = nil; fifo = nil; fifoPathInUse = nil; startParams = nil
        recoveryScheduled = false; _isRunning = false
        lastFillMono = 0
        lastBufferMono = 0
        feedingSilence = false
        bytesWritten = 0
        targetRatio = 1.0
        appliedRatio = 1.0
        lastRatio = 1.0
        corrByteSum = 0; corrByteTot = 0; silenceBytesAcc = 0; tapRebuildAcc = 0
        lastMetricsMono = Self.monoNow()
        zeroBufferRun = 0
        heardAudioSinceBuild = false
        stallAttempts = 0; recoveryFailures = 0; recoveriesAcc = 0
        lastTapNs = 0
        bufCount = 0; maxGapMs = 0; convRebuilds = 0; inFrames = 0; outBytes = 0
        converterInputRate = 0; silentSec = 0; sourceSilent = false; staleConversions = 0
        lpSlow = 0; lpMid = 0; levelPrimed = false
        _level = 0; _bass = 0; _treble = 0
        peakSinceRead = (0, 0, 0)
        lastLevelAt = nil; lastBeatWallAt = nil
        _isRunning = false
        // Queue while holding the same lock used to admit a new start. New
        // hardware work therefore cannot overtake the old tap's teardown.
        lifecycleQueue.async { [self] in oldTap?.stop(); removeWakeObserver() }
        lock.unlock()
        timer?.cancel()
        oldFifo?.closePipe()

    }
}
