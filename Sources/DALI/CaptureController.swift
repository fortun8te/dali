// Wires ProcessTap -> FormatConverter -> FIFOWriter inside the app.
// Owns the audio objects; everything here is off the main thread except
// start/stop entry points.

import Foundation
import AVFoundation

final class CaptureController: @unchecked Sendable {
    private var tap: ProcessTap?
    private var fifo: FIFOWriter?
    private let lock = NSLock()
    // Hardware start/stop may wait for an audio callback, so serialize lifecycle
    // operations separately from the callback's state lock. In particular stop
    // must wait for a detached rebuild to finish before tearing down its tap.
    private let lifecycleLock = NSLock()
    private var sessionGeneration = 0
    var sessionID: Int {
        lock.lock(); defer { lock.unlock() }
        return sessionGeneration
    }
    private(set) var isRunning = false

    // OwnTone's pipe playback needs a CONTINUOUS, REAL-TIME byte stream: it plays
    // exactly 44100*4 bytes per wall-clock second and trusts that contract. We
    // pin the TOTAL bytes written to elapsed wall-clock by topping up with
    // silence, so audio-time never drifts from real time (drift caused the
    // slow-building stutters/stops).
    private var silenceTimer: DispatchSourceTimer?
    private var lastBufferAt = Date.distantPast
    private var lastFillAt = Date.distantPast    // wall clock of last silence top-up
    private var feedingSilence = false
    private var varispeed = Varispeed()          // smooth drift control
    // The drift-control ratio is computed once per second by DALIStore's flight
    // loop from OwnTone's REAL drain/playback clock (the only observable speaker
    // clock) and pushed in here. The audio thread just applies it. This replaces
    // the old per-buffer loop that steered off pendingBytes, which is blind to
    // OwnTone's internal buffers and so pinned the ratio at its floor forever.
    private var targetRatio = 1.0
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

    // Byte-weighted accounting of the correction we ACTUALLY applied this
    // interval. The commanded ratio is not the applied ratio: the silence
    // keepalive writes wall-clock-paced zeros that bypass the varispeed, so a
    // mostly-silent interval dilutes the correction toward zero. The drift loop
    // gates on this rather than trusting its own command.
    private var corrByteSum = 0.0     // Σ (ratio-1) * bytes
    private var corrByteTot = 0.0     // Σ bytes through the varispeed
    private var silenceBytesAcc = 0   // keepalive zeros written this interval
    private var tapRebuildAcc = 0     // tap rebuilds since the last readMetrics
    private var lastMetricsAt = Date()

    // Visualization levels (read by the UI at ~15Hz). Updated off the audio
    // thread on a dedicated analysis queue so the realtime capture path does
    // only convert + write, never DSP under a contended lock.
    private let analysisQueue = DispatchQueue(label: "dali.analysis", qos: .utility)
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
    // Peak since the UI last read. The panel polls at ~15 Hz and a transient
    // decays inside that window, so without this the canvas saw noise, not beats.
    private var peakSinceRead: (level: Double, bass: Double, treble: Double) = (0, 0, 0)
    /// Monotonic count of detected beats (bass onsets), with a refractory gap so
    /// one kick is one beat.
    private var _beatCount = 0
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
        guard lastBufferAt != .distantPast else { return 0 }
        return Date().timeIntervalSince(lastBufferAt)
    }

    /// One consistent reading for the room canvas: the peak of each band since
    /// the last call (so a transient between two 15 Hz polls is not lost), plus
    /// the beat counter. Consuming — call it once per UI tick and no more.
    func readLevels() -> (level: Double, bass: Double, treble: Double, beats: Int) {
        lock.lock(); defer { lock.unlock() }
        let v = (max(_level, peakSinceRead.level),
                 max(_bass, peakSinceRead.bass),
                 max(_treble, peakSinceRead.treble),
                 _beatCount)
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
    }
    func readMetrics() -> Flight {
        lock.lock(); defer { lock.unlock() }
        var f = Flight()
        if let fw = fifo { f.written = fw.writtenBytes; f.dropped = fw.droppedBytes; f.pending = fw.pendingBytes; f.eagain = fw.eagainCount }
        f.bufCount = bufCount; f.maxGapMs = maxGapMs; f.convRebuilds = convRebuilds
        f.inFrames = inFrames; f.outBytes = outBytes; f.inRate = converterInputRate
        f.ratio = lastRatio
        f.silenceBytes = silenceBytesAcc
        f.tapRebuilds = tapRebuildAcc
        let total = corrByteTot + Double(silenceBytesAcc)
        f.appliedCorr = total > 0 ? corrByteSum / total : 0
        let now = Date()
        f.intervalSec = max(0.001, now.timeIntervalSince(lastMetricsAt))
        lastMetricsAt = now
        bufCount = 0; maxGapMs = 0; convRebuilds = 0; inFrames = 0; outBytes = 0
        corrByteSum = 0; corrByteTot = 0; silenceBytesAcc = 0; tapRebuildAcc = 0
        return f
    }

    /// Throws ProcessTap.TapError when TCC is denied or tap creation fails.
    func start(fifoPath: String, muteLocal: Bool = false,
               source: ProcessTap.Source = .system) throws {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        sessionGeneration += 1
        let pipe = fifo ?? FIFOWriter(path: fifoPath)
        fifo = pipe
        if lastFillAt == .distantPast { lastFillAt = Date(); bytesWritten = 0 }
        lastBufferAt = Date()
        lock.unlock()

        let tap = ProcessTap()
        attachHandler(to: tap, pipe: pipe)
        try tap.start(muteLocal: muteLocal, source: source)
        lock.lock(); self.tap = tap; isRunning = true; lock.unlock()
        startSilenceKeepalive()
    }

    /// Swap the TAP only (source / mute change) while keeping the same FIFO and
    /// silence timer alive, so the pipe never loses its writer and OwnTone never
    /// sees an EOF. No teardown, no zero-writer gap.
    @discardableResult
    func rebuild(fifoPath: String, muteLocal: Bool, source: ProcessTap.Source,
                 expectedSession: Int? = nil) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        lock.lock()
        guard isRunning, let pipe = fifo else { lock.unlock(); return false }
        guard expectedSession == nil || expectedSession == sessionGeneration else {
            lock.unlock(); return false
        }
        let oldTap = tap
        tap = nil
        converterInputRate = 0
        tapRebuildAcc += 1       // hard discontinuity: the drift loop must freeze
        zeroBufferRun = 0        // fresh tap, fresh canary
        silentSec = 0
        // Clearing `sourceSilent` silently used to strand every listener on the
        // stale value: the flag went false in here, so the first non-zero buffer
        // from the new tap saw nothing to flip and never fired "audio is back".
        // Anyone holding a mute on that signal held it forever.
        let wasSilent = sourceSilent
        sourceSilent = false
        heardAudioSinceBuild = false
        let silenceCB = onSourceSilenceChanged
        feedingSilence = false
        lastFillAt = Date()
        lastBufferAt = Date()    // fresh grace period for the no-buffers watchdog
        lock.unlock()
        if wasSilent, let silenceCB { Task { @MainActor in silenceCB(false) } }
        oldTap?.stop()

        let newTap = ProcessTap()
        attachHandler(to: newTap, pipe: pipe)
        do {
            try newTap.start(muteLocal: muteLocal, source: source)
            lock.lock(); tap = newTap; lock.unlock()
            return true
        } catch {
            // Never leave a failed tap masquerading as a running capture. The
            // caller can stop the stream and surface the real error instead of
            // silently sending zeros and retrying forever.
            lock.lock(); isRunning = false; tap = nil; lock.unlock()
            return false
        }
    }

    /// Install the capture callback: convert, account, write, and hand a copy to
    /// the analysis queue for the visualization. The audio thread does no DSP.
    private func attachHandler(to tap: ProcessTap, pipe: FIFOWriter) {
        var conv: FormatConverter?
        tap.onBuffer = { [weak self] buffer in
            guard let self else { return }
            var rebuilt = false
            // Rebuild the converter if the device's mix rate changed mid-session
            // (AirPods / DAC switching the rate); feeding 48k through a 44.1k
            // converter would corrupt timing.
            if conv == nil || self.converterInputRate != buffer.format.sampleRate {
                conv = FormatConverter(from: buffer.format)
                self.converterInputRate = buffer.format.sampleRate
                // The new converter is a fresh resampler with no relation to the
                // previous stream's last frame; reset varispeed so it doesn't
                // interpolate a click across the discontinuity.
                self.lock.lock(); self.varispeed.reset(); self.lock.unlock()
                rebuilt = true
            }
            guard let converted = conv?.convert(buffer) else { return }
            // SMOOTH DRIFT CONTROL: resample by a hair to match the AirPlay speaker
            // clock. The ratio is set once/sec by the flight loop from OwnTone's
            // REAL drain + playback clock (setTargetRatio), so it tracks the actual
            // hidden backlog instead of the always-zero app-side pending buffer.
            self.lock.lock(); let rawRatio = self.targetRatio; self.lock.unlock()
            // Bit-transparency deadzone (see driftDeadzone): sub-200 ppm
            // corrections snap to exactly 1.0 so the varispeed takes its
            // bit-perfect passthrough branch and never resamples audio it
            // cannot audibly improve.
            let ratio = abs(rawRatio - 1.0) < Self.driftDeadzone ? 1.0 : rawRatio
            let data = self.varispeed.process(converted, ratio: ratio)

            let now = DispatchTime.now().uptimeNanoseconds
            self.lock.lock()
            self.lastBufferAt = Date()
            self.bytesWritten += data.count
            self.lastRatio = ratio
            self.corrByteSum += (ratio - 1.0) * Double(data.count)
            self.corrByteTot += Double(data.count)
            if self.lastTapNs != 0 {
                let gap = Double(now - self.lastTapNs) / 1_000_000
                if gap > self.maxGapMs { self.maxGapMs = gap }
            }
            self.lastTapNs = now
            self.bufCount += 1
            self.inFrames += Int(buffer.frameLength)
            self.outBytes += data.count
            if rebuilt { self.convRebuilds += 1 }
            self.lock.unlock()
            pipe.write(data)
            self.analyze(data)
        }
    }

    /// Loudness + band split for the room visualization, off the audio thread.
    private func analyze(_ data: Data) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            // Zero-buffer canary (see zeroBufferRun). Early-exits on the first
            // non-zero sample, so on real audio this is a couple of comparisons.
            let anyNonZero = data.withUnsafeBytes { raw -> Bool in
                raw.bindMemory(to: Int16.self).contains { $0 != 0 }
            }
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
            let cb = self.onSourceSilenceChanged
            self.lock.unlock()
            // Resuming is reported on the FIRST non-zero buffer — no delay at
            // all. Being slow to un-mute would be audible; being slow to mute is
            // only ever inaudible.
            if let f = flipped, let cb { Task { @MainActor in cb(f) } }

            let (instant, bass, treble) = data.withUnsafeBytes { raw -> (Double, Double, Double) in
                let s16 = raw.bindMemory(to: Int16.self)
                guard !s16.isEmpty else { return (0, 0, 0) }
                var sumSq = 0.0, bassAcc = 0.0, trebAcc = 0.0, n = 0.0
                var lpS = self.lpSlow, lpM = self.lpMid
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
                self.lpSlow = lpS; self.lpMid = lpM
                func db(_ acc: Double) -> Double {
                    guard n > 0 else { return -120 }
                    let rms = (acc / n).squareRoot()
                    return rms > 0 ? 20 * log10(rms) : -120
                }
                return (db(sumSq), db(bassAcc), db(trebAcc))
            }
            self.lock.lock()
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

            // The beat: a clear bass onset, at most one per 220 ms.
            self.audioClock += dt
            if bOnset > 0.55, self.audioClock - self.lastBeatAt > 0.22 {
                self.lastBeatAt = self.audioClock
                self._beatCount &+= 1
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

    private func startSilenceKeepalive() {
        guard silenceTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dali.silence"))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock()
            let now = Date()
            // Start a forward-paced keepalive promptly if the tap stops calling.
            // Never backfill the historical gap: those late zeros cannot repair
            // past audio and only queue ahead of newly resumed sound.
            let quiet = now.timeIntervalSince(lastBufferAt) > 0.12
            var fill = 0
            if quiet {
                let quantum = Self.bytesPerSecond / 20     // 50 ms
                if !feedingSilence {
                    feedingSilence = true
                    lastFillAt = now
                    fill = quantum
                } else {
                    let gap = now.timeIntervalSince(lastFillAt)
                    var bytes = Int(gap * Double(Self.bytesPerSecond))
                    bytes -= bytes % 4
                    fill = min(max(bytes, 0), quantum)
                    if fill > 0 {
                        lastFillAt = lastFillAt.addingTimeInterval(
                            Double(fill) / Double(Self.bytesPerSecond)
                        )
                    }
                }
            } else {
                feedingSilence = false
                lastFillAt = lastBufferAt
            }
            let f = fifo
            if fill > 0 { bytesWritten += fill; silenceBytesAcc += fill }
            // Queue the zero block before releasing the same lock used by the
            // real-audio callback. This guarantees resumed PCM cannot overtake
            // an already-decided silence write.
            if fill > 0 { f?.write(Data(count: fill)) }
            lock.unlock()
        }
        t.resume()
        silenceTimer = t
    }

    func stop() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        silenceTimer?.cancel()
        silenceTimer = nil
        // DEADLOCK FIX. tap.stop() calls AudioDeviceStop + AudioDeviceDestroy-
        // IOProcID, both of which BLOCK until the IOProc block is no longer
        // executing — and that block's first act is `self.lock.lock()`. Calling
        // them while holding `lock` therefore deadlocks whenever a buffer is
        // in flight: the HAL waits for the block, the block waits for us. Since
        // stop() runs on the main actor (stopStream / shutdown / video mode),
        // the symptom is a hung app, not a dropped stream.
        // Same reason rebuild() already unlocks before oldTap?.stop().
        // closePipe() is likewise a queue.sync onto the writer queue and has no
        // business running under this lock either.
        lock.lock()
        let oldTap = tap
        let oldFifo = fifo
        sessionGeneration += 1
        tap = nil
        fifo = nil
        lock.unlock()
        oldTap?.stop()
        oldFifo?.closePipe()

        lock.lock(); defer { lock.unlock() }
        lastFillAt = .distantPast
        lastBufferAt = .distantPast
        feedingSilence = false
        bytesWritten = 0
        varispeed.reset()
        targetRatio = 1.0
        lastRatio = 1.0
        corrByteSum = 0; corrByteTot = 0; silenceBytesAcc = 0; tapRebuildAcc = 0
        lastMetricsAt = Date()
        zeroBufferRun = 0
        heardAudioSinceBuild = false
        isRunning = false
    }
}
