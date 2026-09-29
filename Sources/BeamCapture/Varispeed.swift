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
                var nh = [Double](repeating: 0, count: 6)
                for k in 0..<3 {
                    nh[k * 2] = at(n + k, 0)
                    nh[k * 2 + 1] = at(n + k, 1)
                }
                hist = nh
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
                    out.append(Self.clip16(v))
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
