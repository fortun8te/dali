// DALI — the glow that listens.
//
// A smooth swell of light rising out of the room card's glow, with many fine lines of
// light standing in it. The music moulds the swell's upper edge: the bass lifts the left, the mids
// the middle, the treble the right (three real bands, not one level reshaped), a kick
// pushes the low end and a beat sends a gentle ripple out from the middle. The glow
// near the pointer lifts toward it; while the room connects it breathes; when nothing
// plays it rests low.
//
// Sync: it reads only the store's delayed level path (`audioLevel`, `bassLevel`,
// `midLevel`, `trebleLevel`, `beatPlayedAt`), the sample the speakers are playing now,
// so the light moves with what is heard and not with what the tap captured earlier.
// Smoothing is kept short on purpose: every extra millisecond of easing is a millisecond
// the bars trail the sound.
//
// Budget: one Canvas, 56 thin lines and three blurred layers, 30 fps, only while the room is
// live, connecting or the pointer is over it; static otherwise; static for Reduce Motion.

import SwiftUI
import Observation

struct LivingBloom: View {
    @Environment(DALIStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pointer: CGPoint?
    @State private var smoother = SpectrumSmoother()

    private static let barCount = 56
    /// A fixed, uneven lean per bar, so neighbours are not copies of each other.
    private static let voices: [Double] = (0..<barCount).map { i in
        let v = sin(Double(i + 1) * 12.9898) * 43758.5453
        return 0.94 + 0.12 * (v - floor(v))
    }

    private var active: Bool { store.phase == .streaming || store.phase == .starting }
    private var paused: Bool { reduceMotion || (!active && pointer == nil) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            Canvas { ctx, size in draw(ctx, size: size, now: timeline.date) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        // Sampled without registering, so the timeline (not each level publish) drives frames.
        let raw = reduceMotion
            ? (store.audioLevel, store.bassLevel, store.trebleLevel, store.midLevel, store.spectrum)
            : withObservationTracking({ (store.audioLevel, store.bassLevel, store.trebleLevel, store.midLevel, store.spectrum) }, onChange: {})
        let spectrum = raw.4
        let (level, bass, treble, mid) = smoother.step(level: raw.0, bass: raw.1, treble: raw.2, mid: raw.3, at: now)
        let live = store.phase == .streaming
        let connecting = store.phase == .starting
        let presence = live ? 1.0 : connecting ? 0.75 : 0.42
        let beat = beatEnvelope(now: now)
        let kick = beatEnvelope(now: now, span: 0.30)

        let w = size.width, h = size.height
        let region = h * 0.26
        let n = Self.barCount
        let slot = w / Double(n)

        // 1. Where each bar wants to be.
        var targets = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let xn = (Double(i) + 0.5) / Double(n)
            var e: Double
            if live {
                let wb = exp(-pow((xn - 0.10) / 0.22, 2))
                let wm = exp(-pow((xn - 0.50) / 0.26, 2))
                let wt = exp(-pow((xn - 0.90) / 0.22, 2))
                let total = wb + wm + wt
                if spectrum.count == SpectrumAnalyzer.bandCount {
                    // Each bar is its own frequency: the real spectrum, read between its two nearest bands.
                    let pos = xn * Double(spectrum.count - 1)
                    let lo = Int(pos), hi = min(lo + 1, spectrum.count - 1), f = pos - Double(lo)
                    let v = Double(spectrum[lo]) * (1 - f) + Double(spectrum[hi]) * f
                    e = pow(v, 1.5) * 0.9 * Self.voices[i] + 0.02 * level
                } else {
                    e = (wb * bass + wm * mid + wt * treble) / total
                    e *= Self.voices[i]
                    e += 0.04 * level
                }
                e *= 1 + 0.12 * kick * (wb / total)                                    // a kick lifts the low end, gently
                e *= 1 + 0.06 * beatRipple(now: now, distance: abs(xn - 0.5) * 2)       // a beat runs out from the middle, barely
                e = tanh(1.1 * pow(max(e, 0), 0.9))                                      // a soft ceiling: peaks round off
            } else if connecting {
                // Connecting: the bars just breathe, calmly, all together.
                e = 0.11 + 0.07 * sin(t * 1.7 + xn * 2.5)
            } else {
                e = 0.04 + 0.025 * sin(xn * 6.0 + t * 0.7) + 0.015 * sin(xn * 17.0 - t * 1.1)   // resting, drifting
            }
            if let p = pointer {
                let dx = (xn * w - p.x) / 46
                e += 0.20 * exp(-dx * dx) * (p.y > h - region * 1.2 ? 1 : 0.35)
            }
            targets[i] = min(max(e, 0), 1)
        }
        let rough = smoother.stepBars(targets, at: now).map { $0 * region + 1.5 }
        // The swell is smoothed across neighbours so the glow flows; the fine lines only a little,
        // so they stay lively.
        let heights = Self.blurred(rough, weights: [1, 2, 3, 2, 1])
        let lineHeights = Self.blurred(rough, weights: [1, 2, 1])

        // 2. The glow itself: a smooth swell whose upper edge the music moves. It is only
        // ever drawn blurred, so there is no hard edge anywhere on it.
        let swell = Self.wave(heights, width: w, base: h)
        let crest = h - (heights.max() ?? 0)
        let breath = presence * (0.05 + 0.12 * bass + 0.10 * beat)
        // A whole-width rectangle with a radial that eases to nothing, so it has no edge to see.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                 with: .radialGradient(Self.radialFalloff(.bloomSwell, peak: breath),
                                       center: CGPoint(x: w * 0.5, y: h), startRadius: 0, endRadius: w * 0.6))
        // The swell adds light to the room's own gradient instead of covering it.
        // Blurring is the costly part: confine it to the strip the swell can reach.
        var add = ctx
        add.clip(to: Path(CGRect(x: 0, y: h - region * 1.7, width: w, height: region * 1.7)))
        add.blendMode = .plusLighter
        add.drawLayer { layer in
            layer.addFilter(.blur(radius: 20))
            layer.fill(swell, with: .linearGradient(Self.falloff(top: .bloomPeriwinkle, bottom: .bloomAzure, peak: 0.30 * presence),
                                                    startPoint: CGPoint(x: w / 2, y: crest - 14), endPoint: CGPoint(x: w / 2, y: h)))
        }
        add.drawLayer { layer in
            layer.addFilter(.blur(radius: 10))
            layer.fill(swell, with: .linearGradient(Self.falloff(top: .bloomPeriwinkle, bottom: .bloomHighlight, peak: 0.15 * presence),
                                                    startPoint: CGPoint(x: w / 2, y: crest), endPoint: CGPoint(x: w / 2, y: h)))
        }
        // A cool-to-warm drift across the same shape, so it carries the glow's colours.
        let drift = reduceMotion ? 0 : 0.18 * sin(t * 0.35)          // the colours slowly trade places
        add.drawLayer { layer in
            layer.addFilter(.blur(radius: 14))
            layer.fill(swell, with: .linearGradient(Gradient(stops: [
                .init(color: Color.bloomViolet.opacity(0.16 * presence), location: max(0, 0 + drift * 0.3)),
                .init(color: Color.bloomPeriwinkle.opacity(0.03 * presence), location: 0.5 + drift * 0.25),
                .init(color: Color.bloomAzure.opacity(0.14 * presence), location: min(1, 1 + drift * 0.3)),
            ]), startPoint: CGPoint(x: 0, y: h), endPoint: CGPoint(x: w, y: h)))
        }

        // 3. Fine lines of light, thin and bright at the foot, fading out as they rise.
        let lineW = max(1.4, slot * 0.34)
        for i in 0..<n {
            let cx = (Double(i) + 0.5) * slot
            let bh = lineHeights[i]
            let rect = CGRect(x: cx - lineW / 2, y: h - 2 - bh, width: lineW, height: bh)
            let a = presence * (0.22 + 0.26 * min(1, bh / region)) * (1 + 0.12 * beat)
            ctx.fill(Path(roundedRect: rect, cornerRadius: lineW / 2, style: .continuous),
                     with: .linearGradient(Gradient(stops: [
                        .init(color: Color.bloomHighlight.opacity(0), location: 0),
                        .init(color: Color.bloomPeriwinkle.opacity(a * 0.7), location: 0.55),
                        .init(color: Color.bloomHighlight.opacity(a), location: 1),
                     ]), startPoint: CGPoint(x: cx, y: rect.minY), endPoint: CGPoint(x: cx, y: h)))
        }
    }

    /// A radial that starts at `peak` and eases to nothing in many small steps.
    private static func radialFalloff(_ color: Color, peak: Double) -> Gradient {
        let steps = 12
        return Gradient(stops: (0...steps).map { k in
            let t = Double(k) / Double(steps)
            let ease = 1 - t * t * (3 - 2 * t)
            return .init(color: color.opacity(peak * ease), location: t)
        })
    }

    /// A vertical falloff in many small steps, so a soft, faint gradient stays smooth
    /// instead of banding.
    private static func falloff(top: Color, bottom: Color, peak: Double) -> Gradient {
        let steps = 12
        return Gradient(stops: (0...steps).map { k in
            let t = Double(k) / Double(steps)
            return .init(color: (t < 0.5 ? top : bottom).opacity(peak * t * t * (3 - 2 * t)), location: t)
        })
    }

    /// Neighbours averaged with `weights` (odd count, centre in the middle), so adjacent
    /// columns flow into each other.
    private static func blurred(_ v: [Double], weights: [Double]) -> [Double] {
        let half = weights.count / 2
        return v.indices.map { i in
            var sum = 0.0, norm = 0.0
            for (k, wgt) in weights.enumerated() {
                let j = min(max(i + k - half, 0), v.count - 1)
                sum += v[j] * wgt; norm += wgt
            }
            return sum / norm
        }
    }

    /// A smooth curve (Catmull-Rom) through the column heights, closed down to `base`.
    private static func wave(_ heights: [Double], width w: Double, base h: Double) -> Path {
        let n = heights.count
        let slot = w / Double(n)
        var pts = [CGPoint(x: 0, y: h - heights[0])]
        for i in 0..<n { pts.append(CGPoint(x: (Double(i) + 0.5) * slot, y: h - heights[i])) }
        pts.append(CGPoint(x: w, y: h - heights[n - 1]))
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: pts[0])
        for k in 0..<(pts.count - 1) {
            let p0 = pts[max(k - 1, 0)], p1 = pts[k], p2 = pts[k + 1], p3 = pts[min(k + 2, pts.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }

    /// 1 at the moment a beat reaches `distance` (0 centre, 1 edge) from the middle,
    /// travelling outward and fading, so a beat is a ripple and not a flash.
    private func beatRipple(now: Date, distance: Double) -> Double {
        guard let at = store.beatPlayedAt else { return 0 }
        let e = now.timeIntervalSince(at) - distance * 0.28
        guard e >= 0, e < 0.55 else { return 0 }
        let v = 1 - e / 0.55
        return v * v
    }

    private func smooth(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        let v = min(max((x - lo) / (hi - lo), 0), 1)
        return v * v * (3 - 2 * v)
    }

    /// 1 at the moment a beat is heard in the room, easing to 0 over `span` seconds.
    private func beatEnvelope(now: Date, span: Double = 0.9) -> Double {
        guard let at = store.beatPlayedAt else { return 0 }
        let e = now.timeIntervalSince(at)
        guard e >= 0, e < span else { return 0 }
        let v = 1 - e / span
        return v * v
    }
}

/// Light easing on the four levels and the bars: a fast rise so a hit shows at once, a
/// short fall so the shape still settles instead of flickering.
final class SpectrumSmoother {
    private var level = 0.0, bass = 0.0, treble = 0.0, mid = 0.0
    private var bars: [Double] = []
    private var last: Date?
    private var barsLast: Date?

    /// Each bar rises almost at once and falls back over a tenth of a second or so.
    func stepBars(_ targets: [Double], at now: Date) -> [Double] {
        if bars.count != targets.count { bars = [Double](repeating: 0, count: targets.count) }
        let dt = min(max(barsLast.map { now.timeIntervalSince($0) } ?? 1.0 / 60, 0), 0.1)
        barsLast = now
        for i in targets.indices {
            let target = targets[i].isFinite ? min(max(targets[i], 0), 1) : 0
            let tau = target > bars[i] ? 0.014 : 0.095
            bars[i] += (target - bars[i]) * (1 - exp(-dt / tau))
        }
        return bars
    }

    func step(level l: Double, bass b: Double, treble t: Double, mid m: Double,
              at now: Date) -> (Double, Double, Double, Double) {
        let dt = min(max(last.map { now.timeIntervalSince($0) } ?? 1.0 / 60, 0), 0.1)
        last = now
        func ema(_ v: inout Double, _ target: Double, rise: Double, fall: Double) {
            let target = target.isFinite ? min(max(target, 0), 1) : 0
            let tau = target > v ? rise : fall
            v += (target - v) * (1 - exp(-dt / tau))
        }
        ema(&level, l, rise: 0.012, fall: 0.07)
        ema(&bass, b, rise: 0.012, fall: 0.08)
        ema(&treble, t, rise: 0.010, fall: 0.05)
        ema(&mid, m, rise: 0.010, fall: 0.06)
        return (level, bass, treble, mid)
    }
}
