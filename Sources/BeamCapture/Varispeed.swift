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
/// Continuity across buffers is exact: the read position `pos` is carried in a
/// single consistent coordinate (leftover position past this buffer's end), and
/// the last TWO frames are carried as history so the cubic kernel keeps its full
/// 4-point support at the seam. (The old version carried the position off by one
/// full sample, re-reading ~1 sample per buffer = a periodic buzz.)
struct Varispeed {
    private var prev1L = 0.0, prev1R = 0.0   // last frame of previous buffer  (index -1)
    private var prev2L = 0.0, prev2R = 0.0   // second-to-last frame           (index -2)
    private var havePrev = false
    private var pos = 0.0   // fractional read position, measured from index -1 (the prev frame)

    /// Resample one interleaved-s16-stereo buffer by `ratio` (clamped near 1.0).
    /// At ratio == 1.0 EXACTLY this is a bit-perfect passthrough (history carry
    /// only) — the drift controller snaps sub-0.05% corrections to 1.0, so
    /// steady-state audio is never touched by the interpolator.
    mutating func process(_ input: Data, ratio: Double) -> Data {
        let r = min(max(ratio, 0.90), 1.10)
        let frameCount = input.count / 4
        guard frameCount > 0 else { return input }

        return input.withUnsafeBytes { raw -> Data in
            let inS = raw.bindMemory(to: Int16.self)
            if r == 1.0 {
                // Passthrough: keep the carry history exact so the cubic kernel
                // has its full 4-point support if a later buffer re-engages
                // drift correction — but do not touch a single sample.
                prev2L = Double(inS[max(0, frameCount - 2) * 2])
                prev2R = Double(inS[max(0, frameCount - 2) * 2 + 1])
                prev1L = Double(inS[(frameCount - 1) * 2])
                prev1R = Double(inS[(frameCount - 1) * 2 + 1])
                havePrev = true
                pos = 0
                return input
            }
            // Virtual input timeline: indices -2,-1 are the carried previous two
            // frames, then 0..<frameCount are this buffer's frames. We read at a
            // fractional position measured from index -1.
            func sample(_ i: Int) -> (Double, Double) {
                if i >= 0 {
                    let idx = min(i, frameCount - 1)
                    return (Double(inS[idx*2]), Double(inS[idx*2 + 1]))
                }
                if i == -1 { return (prev1L, prev1R) }
                return (prev2L, prev2R)   // i <= -2
            }

            var out = [Int16]()
            out.reserveCapacity(Int(Double(frameCount) / r) + 4)

            // Start position relative to index -1 (the prev frame). On the very
            // first buffer there is no history, so begin at index 0.
            var p = havePrev ? pos : 0.0
            let lastReadable = Double(frameCount - 1)
            while true {
                let base = floor(p)
                let frac = p - base
                let i = Int(base) - 1                     // shift: p=0 -> prev frame
                if Double(i) >= lastReadable { break }    // need i and i+1 within this buffer
                // Catmull-Rom over [i-1, i, i+1, i+2] at fraction frac.
                let (y0l, y0r) = sample(i - 1)
                let (y1l, y1r) = sample(i)
                let (y2l, y2r) = sample(i + 1)
                let (y3l, y3r) = sample(i + 2)
                let t = frac, t2 = frac * frac, t3 = t2 * frac
                func cr(_ y0: Double, _ y1: Double, _ y2: Double, _ y3: Double) -> Double {
                    0.5 * ((2*y1)
                         + (-y0 + y2) * t
                         + (2*y0 - 5*y1 + 4*y2 - y3) * t2
                         + (-y0 + 3*y1 - 3*y2 + y3) * t3)
                }
                let l = cr(y0l, y1l, y2l, y3l)
                let rr = cr(y0r, y1r, y2r, y3r)
                out.append(Int16(max(-32768, min(32767, l.rounded()))))
                out.append(Int16(max(-32768, min(32767, rr.rounded()))))
                p += r
            }

            // Carry: remember the last two real frames and the leftover position.
            // Frame (frameCount-1) sits at p = frameCount in this coordinate and
            // becomes index -1 next buffer (p' = 0), so the leftover is p - frameCount.
            prev2L = Double(inS[max(0, frameCount - 2) * 2])
            prev2R = Double(inS[max(0, frameCount - 2) * 2 + 1])
            prev1L = Double(inS[(frameCount - 1) * 2])
            prev1R = Double(inS[(frameCount - 1) * 2 + 1])
            havePrev = true
            pos = p - Double(frameCount)
            if pos < 0 { pos = 0 }
            return out.withUnsafeBytes { Data($0) }
        }
    }

    mutating func reset() {
        havePrev = false; pos = 0
        prev1L = 0; prev1R = 0; prev2L = 0; prev2R = 0
    }
}
