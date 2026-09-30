import Foundation

/// Smooth, continuously-variable resampler for interleaved s16 stereo, used to
/// match our production rate to the AirPlay speakers' clock without clicks.
///
/// The Mac and the speakers run on different clocks, so feeding a fixed 44100/s
/// makes the pipe backlog drift until it overflows (mass drops) or underruns.
/// Chunky frame drop/dup fixes the count but warbles the pitch. Instead we
/// resample by a ratio very close to 1.0 (well under 1.5%), driven by the true
/// downstream backlog: a sub-cent pitch nudge that is inaudible but holds the
/// buffer steady with zero drops.
///
/// `ratio` = input frames consumed per output frame. ratio > 1 produces FEWER
/// output frames (drains our backlog / "speeds up"); ratio < 1 produces more.
///
/// Interpolation is 4-point Catmull-Rom (cubic Hermite). Linear interpolation
/// at a ratio that lands on a different fractional phase every sample injects a
/// continuous, music-correlated aliasing haze (~-25 dB near Nyquist); cubic
/// drops that to ~-65 dB for a few extra multiplies — inaudible on music.
///
/// SEAM EXACTNESS. Work happens on a virtual timeline W = [3 carried history
/// frames][this buffer's n frames]. An output at position q needs W[floor(q)-1
/// ... floor(q)+2], all real: we emit only while floor(q)+2 fits inside W, so the
/// kernel NEVER reads past the end of the data (the old code clamped the 4th tap
/// to the last frame, a small error injected once per buffer = a ~94 Hz buzz).
/// The unconsumed tail stays in the 3-frame history and q carries over shifted
/// by n, so the read position is continuous across buffers to the sub-sample.
struct Varispeed {
    private var hist = [Double](repeating: 0, count: 6)   // 3 frames x (L,R): W[0..2]
    private var haveHist = false
    private var q = 3.0            // carried read position in W coordinates (>= 1)
    private var interpolating = false   // q holds a pending fractional phase
    private var out = [Int16]()
    private var nh = [Double](repeating: 0, count: 6)   // scratch for carryHistory
    private var rng: UInt32 = 0x2545F491                // xorshift32 dither state

    @inline(__always)
    private static func clip16(_ v: Double) -> Int16 {
        if v.isNaN { return 0 }
        return Int16(max(-32768, min(32767, v.rounded())))
    }

    /// Resample one interleaved-s16-stereo buffer by `ratio` (clamped near 1.0).
    /// At ratio == 1.0 EXACTLY this is a bit-perfect passthrough (history carry
    /// only) — the drift controller snaps sub-0.05% corrections to 1.0, so
    /// steady-state audio is never touched by the interpolator.
    mutating func process(_ input: Data, ratio: Double) -> Data {
        // NaN survives min/max (every comparison is false) and would reach
        // Int(NaN) below, which traps. A non-finite command means "no correction".
        let r = ratio.isFinite ? min(max(ratio, 0.90), 1.10) : 1.0
        let n = input.count / 4
        guard n > 0 else { return Data() }

        return input.withUnsafeBytes { raw -> Data in
            let inS = raw.bindMemory(to: Int16.self)

            if !haveHist {
                // No history yet: seed it with the first frame so the kernel sees
                // a constant, not a jump from silence (which would ring).
                let l = Double(inS[0]), rr = Double(inS[1])
                for k in 0..<3 { hist[k * 2] = l; hist[k * 2 + 1] = rr }
                haveHist = true
                q = 3.0
                interpolating = false
            }

            // W[j] channel c
            func at(_ j: Int, _ c: Int) -> Double {
                j < 3 ? hist[j * 2 + c] : Double(inS[(j - 3) * 2 + c])
            }
            // New history = last three frames of W (W' = W shifted by n).
            func carryHistory() {
                for k in 0..<3 {
                    nh[k * 2] = at(n + k, 0)
                    nh[k * 2 + 1] = at(n + k, 1)
                }
                swap(&hist, &nh)
            }

            if r == 1.0 {
                // Passthrough: do not touch a single sample. If the previous buffer
                // left a fractional phase pending, first release the (at most two)
                // frames it was still holding back so none are skipped.
                var result: Data
                if interpolating {
                    result = Data()
                    let firstPending = Int(q.rounded(.up))
                    if firstPending <= 2 {
                        for j in max(firstPending, 0)...2 {
                            var l = Self.clip16(hist[j * 2]), rr = Self.clip16(hist[j * 2 + 1])
                            withUnsafeBytes(of: &l) { result.append(contentsOf: $0) }
                            withUnsafeBytes(of: &rr) { result.append(contentsOf: $0) }
                        }
                    }
                    result.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n * 4)
                } else if input.count == n * 4 {
                    result = input
                } else {
                    result = Data(input.prefix(n * 4))
                }
                carryHistory()
                q = 3.0
                interpolating = false
                return result
            }

            out.removeAll(keepingCapacity: true)
            out.reserveCapacity(Int(Double(n) / r) + 8)

            let len = n + 3
            var p = (q.isFinite && q >= 1 && q < Double(len) + 4) ? q : 3.0
            while true {
                let base = Int(p)                 // p finite and small: safe
                if base + 2 > len - 1 { break }   // kernel would read past the data
                let t = p - Double(base), t2 = t * t, t3 = t2 * t
                for c in 0..<2 {
                    let y0 = at(base - 1, c), y1 = at(base, c)
                    let y2 = at(base + 1, c), y3 = at(base + 2, c)
                    // Catmull-Rom over [base-1, base, base+1, base+2] at fraction t.
                    let v = 0.5 * ((2 * y1)
                                 + (-y0 + y2) * t
                                 + (2 * y0 - 5 * y1 + 4 * y2 - y3) * t2
                                 + (-y0 + 3 * y1 - 3 * y2 + y3) * t3)
                    // TPDF dither (+-1 LSB) before rounding, since this stage
                    // requantises to s16. Digital silence (all taps 0) stays 0.
                    var d = 0.0
                    if y0 != 0 || y1 != 0 || y2 != 0 || y3 != 0 {
                        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
                        let a = Double(rng) * (1.0 / 4294967296.0)
                        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
                        d = a + Double(rng) * (1.0 / 4294967296.0) - 1.0
                    }
                    out.append(Self.clip16(v + d))
                }
                p += r
            }

            // Carry: history shifts by n, so the read position does too. The loop
            // exits with floor(p) >= n+1, hence the carried q is always >= 1.
            carryHistory()
            q = p - Double(n)
            interpolating = true
            return out.withUnsafeBytes { Data($0) }
        }
    }

    mutating func reset() {
        haveHist = false
        q = 3.0
        interpolating = false
        for k in 0..<hist.count { hist[k] = 0 }
    }
}

/// SELF-HEALING REFILL CONTROLLER — the one-sided, low-authority replacement for
/// the retired closed-loop rate matcher.
///
/// WHY. With the varispeed pinned at 1.0 the engine's read-ahead ("fill") starts
/// at the start buffer, wears down ~0.01-0.02 s per 10 min, and takes sudden
/// 0.1-0.3 s step drops (engine stalls on RTSP volume writes catch up by reading
/// ahead). Nothing ever gives the depth back, so after a few hours any jitter is
/// an underrun. The old matcher fought the engine's own pacing in BOTH directions
/// and its damage (phantom fill ramps, lockouts, drains into a suspend) was worse
/// than the disease. This controller is deliberately the opposite:
///
///  * ONE-SIDED. It only ever STRETCHES (ratio < 1, more output frames than
///    input, i.e. it ADDS audio). Fill above target => it does nothing. It can
///    never remove audio, so it cannot starve the engine (no read_deficit debt).
///  * DEAD BAND + HYSTERESIS. Arms only when the (already smoothed) fill sits
///    more than `bandSec` under target for `persistSec`, and stands down once
///    fill is within `exitBandSec` of target. Hysteresis is 0.07 s wide, so it
///    cannot chatter around a threshold.
///  * LOW AUTHORITY, SLEW-LIMITED. eps (= 1 - ratio) is capped at 0.25 % (~4
///    cents) and moves at capEps/rampSec per second: >= 8 s in, >= 8 s out, no
///    steps, no warble. Step-drops are therefore healed slowly, never chased.
///  * HARD BUDGET. A leaky bucket of ADDED AUDIO (0.6 s per rolling 10 min), a
///    per-session ceiling, and a "did it work?" check: if 60 s of stretching did
///    not lift fill by `noEffectGainSec` the measurement (or the plant) is not
///    what we think, so stop and back off 10 min (doubling, up to 80 min).
///  * FREEZES ON BAD DATA. Any invalid-measurement reason from the flight loop
///    holds eps for at most `holdMaxSec` (a soft blip), or eases out at once when
///    the pipeline itself was discontinuous (`hard`). Nothing is learned or
///    integrated, so there is nothing to wind up.
///
/// The sign convention matches the plant: fill' = +eps while stretching.
struct RefillController {
    struct Config {
        var bandSec = 0.10          // arm when smoothed fill < target - band
        var exitBandSec = 0.03      // stand down when smoothed fill >= target - exitBand
        var capEps = 0.0025         // hard authority: 0.25 % ~ 4.3 cents of pitch
        var rampInSec = 8.0         // time to slew 0 -> capEps (>= 5 s required)
        var rampOutSec = 8.0        // time to slew capEps -> 0
        var settleSec = 15.0        // continuous valid seconds required before arming
        var persistSec = 15.0       // deficit must persist this long (valid seconds)
        var noEffectAfterSec = 60.0 // active seconds before judging "did fill improve"
        var noEffectGainSec = 0.03  // required improvement (expected ~0.09 s)
        var backoffSec = 600.0      // base back-off after a no-effect trip (doubles, max x8)
        var bucketSec = 0.6         // budget: seconds of audio we may add per window
        var bucketWindowSec = 600.0
        var sessionCapSec = 3.0     // absolute ceiling per session
        var holdMaxSec = 20.0       // how long a soft invalid reading may hold eps
        var pGain = 0.025           // eps per second of deficit (cap reached at 0.10 s)
        var floorEps = 0.0006       // minimum useful stretch while healing
        var maxStepSec = 2.0        // dt clamp so a late tick cannot jump the slew
    }

    enum Mode: String { case idle, stretching, easing }
    enum Event {
        case started(fill: Double, target: Double)
        case easing(reason: String, fill: Double, addedSec: Double)
        case finished(reason: String, backoffSec: Double, addedSec: Double)
        case blocked(reason: String)
    }

    var cfg = Config()
    private(set) var mode = Mode.idle
    /// Current stretch fraction, >= 0. The commanded varispeed ratio is 1 - eps.
    private(set) var eps = 0.0
    private(set) var validSec = 0.0
    private var lowSec = 0.0
    private var activeSec = 0.0
    private var invalidSec = 0.0
    private var startFill = 0.0
    /// Lowest smoothed fill seen this episode. The smoothing lags a step drop by ~20 s,
    /// so `startFill` can still be ABOVE the true level; gain is judged from the trough.
    private var minFill = 0.0
    private var episodeAdded = 0.0
    private var easeReason = ""
    private var pendingBackoff = 0.0
    private(set) var backoffLeft = 0.0
    private var noEffectStreak = 0
    private(set) var bucketUsed = 0.0
    private(set) var sessionAdded = 0.0
    private var disabled = false
    private var blockedLogged = false

    /// Short state for logs and health: idle / arming / stretching / easing / backoff.
    var label: String {
        switch mode {
        case .stretching: return "stretching"
        case .easing: return "easing"
        case .idle:
            if disabled { return "disabled" }
            if backoffLeft > 0 { return "backoff" }
            return lowSec > 0 ? "arming" : "idle"
        }
    }

    /// Back to a bit-exact 1.0 with a clean slate (new stream / engine restart).
    /// The capture side slew-limits the actual ratio, so this never steps audio.
    mutating func reset() {
        let c = cfg
        self = RefillController()
        cfg = c
    }

    /// One tick (~1 s). `fillSlow` is the smoothed end-to-end fill in seconds;
    /// `holdReason` is non-empty whenever the measurement is not trustworthy;
    /// `hard` marks a pipeline discontinuity (eases out immediately).
    @discardableResult
    mutating func update(dt rawDt: Double, target: Double, fillSlow: Double?,
                         holdReason: String, hard: Bool) -> Event? {
        let dt = min(max(rawDt.isFinite ? rawDt : 1.0, 0.05), cfg.maxStepSec)
        bucketUsed = max(0, bucketUsed - cfg.bucketSec / cfg.bucketWindowSec * dt)
        if backoffLeft > 0 { backoffLeft = max(0, backoffLeft - dt) }
        var event: Event?
        let fs = fillSlow.flatMap { $0.isFinite ? $0 : nil }
        let valid = holdReason.isEmpty && fs != nil && target.isFinite

        if !valid {
            validSec = 0; lowSec = 0
            if mode == .stretching {
                invalidSec += dt
                if hard || invalidSec > cfg.holdMaxSec {
                    event = beginEasing("hold:" + (holdReason.isEmpty ? "noanchor" : holdReason),
                                        fill: fs ?? startFill)
                }
            }
        } else if let fs {
            invalidSec = 0
            validSec += dt
            let deficit = target - fs
            switch mode {
            case .idle:
                if !disabled, backoffLeft <= 0, validSec >= cfg.settleSec, deficit > cfg.bandSec {
                    lowSec += dt
                    if lowSec >= cfg.persistSec {
                        if bucketUsed >= cfg.bucketSec {
                            // Stay armed but do nothing; say so once, not every second.
                            if !blockedLogged { blockedLogged = true; event = .blocked(reason: "budget") }
                        } else {
                            mode = .stretching
                            activeSec = 0; lowSec = 0; startFill = fs; minFill = fs; episodeAdded = 0
                            blockedLogged = false
                            event = .started(fill: fs, target: target)
                        }
                    }
                } else {
                    lowSec = 0
                    if deficit <= cfg.bandSec { blockedLogged = false }
                }
            case .stretching:
                activeSec += dt
                minFill = min(minFill, fs)
                if deficit <= cfg.exitBandSec {
                    noEffectStreak = 0
                    event = beginEasing("healed", fill: fs)
                } else if bucketUsed >= cfg.bucketSec {
                    event = beginEasing("budget", fill: fs)
                } else if sessionAdded >= cfg.sessionCapSec {
                    disabled = true
                    event = beginEasing("session_cap", fill: fs)
                } else if activeSec >= cfg.noEffectAfterSec, fs - minFill < cfg.noEffectGainSec {
                    noEffectStreak += 1
                    pendingBackoff = cfg.backoffSec * Double(1 << min(noEffectStreak - 1, 3))
                    event = beginEasing("noeffect", fill: fs)
                }
            case .easing:
                break
            }
        }

        // Slew. Up only while stretching on a valid reading; held on a soft
        // invalid reading; otherwise down. Never a step.
        let slewIn = cfg.capEps / cfg.rampInSec * dt
        let slewOut = cfg.capEps / cfg.rampOutSec * dt
        if mode == .stretching {
            if valid, let fs {
                let want = min(cfg.capEps, max(cfg.floorEps, cfg.pGain * max(target - fs, 0)))
                if eps < want { eps = min(want, eps + slewIn) }
                else { eps = max(want, eps - slewOut) }
            }
            // else: hold eps unchanged
        } else {
            eps = max(0, eps - slewOut)
            if mode == .easing, eps == 0 {
                mode = .idle
                if pendingBackoff > 0 { backoffLeft = pendingBackoff }
                event = .finished(reason: easeReason, backoffSec: pendingBackoff, addedSec: episodeAdded)
                pendingBackoff = 0
                lowSec = 0
            }
        }
        let added = eps * dt
        bucketUsed += added; sessionAdded += added; episodeAdded += added
        return event
    }

    private mutating func beginEasing(_ reason: String, fill: Double) -> Event {
        mode = .easing
        easeReason = reason
        return .easing(reason: reason, fill: fill, addedSec: episodeAdded)
    }
}
