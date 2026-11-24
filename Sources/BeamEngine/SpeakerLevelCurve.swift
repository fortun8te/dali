import Foundation

/// A speaker's loudness adjustment as a function of the macOS master volume,
/// relative to a reference speaker that stays at 100 %.
///
/// macOS moves its output volume in sixteenths (the 16 chiclets). The curve is
/// defined at those steps, is smooth between them (monotone cubic, so it never
/// overshoots a neighbouring value), holds its first value below step 1 and its
/// last value above the last step. Values are the physical listening targets
/// Michael supplied on 13 Oct 2026; they describe a gain applied to the
/// receiver command, not a measured loudness.
public struct SpeakerLevelCurve: Equatable, Sendable {
    public static let stepsPerFullScale = 16.0

    /// (macOS volume step, gain multiplier), ascending by step.
    public let knots: [(step: Double, gain: Double)]

    public init?(knots: [(step: Double, gain: Double)]) {
        guard !knots.isEmpty,
              knots.allSatisfy({ $0.step.isFinite && $0.gain.isFinite && $0.gain > 0 }),
              zip(knots, knots.dropFirst()).allSatisfy({ $0.step < $1.step })
        else { return nil }
        self.knots = knots
    }

    /// Gains for steps 1...n (as percentages), held after step n. The curve
    /// finishes flat at the last value by step 16.
    public init?(percentPerStep: [Double]) {
        guard !percentPerStep.isEmpty, percentPerStep.count <= 16,
              percentPerStep.allSatisfy({ $0.isFinite && $0 >= 25 && $0 <= 400 })
        else { return nil }
        var knots = percentPerStep.enumerated().map { (step: Double($0.offset + 1), gain: $0.element / 100) }
        if let last = knots.last, last.step < Self.stepsPerFullScale {
            knots.append((step: Self.stepsPerFullScale, gain: last.gain))
        }
        self.init(knots: knots)
    }

    public static func == (lhs: SpeakerLevelCurve, rhs: SpeakerLevelCurve) -> Bool {
        lhs.knots.count == rhs.knots.count
            && zip(lhs.knots, rhs.knots).allSatisfy { $0.step == $1.step && $0.gain == $1.gain }
    }

    /// Michael's targets by macOS volume step (revised 13 Oct 2026 after listening,
    /// low end raised, top unchanged): 1 = 250 %, 2 = 205 %, 3 = 182 %,
    /// 4 = 156 %, 5 = 143 %, 6 = 136 %, 7 = 136 %. Higher steps continue the
    /// flattening trend, so they stay at 136 %.
    public static let michaelD = SpeakerLevelCurve(percentPerStep: [250, 205, 182, 156, 143, 136, 136])!

    /// The built-in curve for a speaker, if one has been measured. Names are
    /// matched case-insensitively; Michael calls this speaker "dali".
    public static func builtIn(forSpeakerNamed name: String) -> SpeakerLevelCurve? {
        name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("MICHAEL D") == .orderedSame
            ? michaelD : nil
    }

    /// Human-readable curve, e.g. "Step 1 250% · 2 205% · … · 7 136% and up".
    public var stepSummary: String {
        var parts: [String] = []
        for (i, knot) in knots.enumerated() {
            if i > 0, i == knots.count - 1, knot.gain == knots[i - 1].gain { break }
            let percent = Int((knot.gain * 100).rounded())
            parts.append(i == 0 ? "Step \(Int(knot.step)) \(percent)%" : "\(Int(knot.step)) \(percent)%")
        }
        return parts.joined(separator: " \u{00B7} ") + " and up"
    }

    /// Gain multiplier at a macOS master volume scalar (0...1).
    public func gain(atMaster master: Double) -> Double {
        let step = (master.isFinite ? min(max(master, 0), 1) : 0) * Self.stepsPerFullScale
        guard let first = knots.first, let last = knots.last else { return 1 }
        if step <= first.step { return first.gain }
        if step >= last.step { return last.gain }
        var i = 0
        while i + 2 < knots.count, knots[i + 1].step <= step { i += 1 }
        let x0 = knots[i], x1 = knots[i + 1]
        let h = x1.step - x0.step
        let t = (step - x0.step) / h
        let m0 = slope(at: i), m1 = slope(at: i + 1)
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * x0.gain + (t3 - 2 * t2 + t) * h * m0
            + (-2 * t3 + 3 * t2) * x1.gain + (t3 - t2) * h * m1
    }

    /// Fritsch-Carlson monotone slopes: flat wherever the data is flat or turns.
    private func slope(at i: Int) -> Double {
        func delta(_ k: Int) -> Double {
            (knots[k + 1].gain - knots[k].gain) / (knots[k + 1].step - knots[k].step)
        }
        if knots.count < 2 { return 0 }
        if i == 0 || i == knots.count - 1 {
            // One-sided estimate, clamped so the end segment stays monotone.
            let k = i == 0 ? 0 : knots.count - 2
            let d = delta(k)
            let h0 = knots[k + 1].step - knots[k].step
            if knots.count < 3 { return d }
            let k2 = i == 0 ? 1 : knots.count - 3
            let d2 = delta(k2)
            let h1 = knots[k2 + 1].step - knots[k2].step
            var m = ((2 * h0 + h1) * d - h0 * d2) / (h0 + h1)
            if m * d <= 0 { m = 0 }
            else if d * d2 <= 0, abs(m) > 3 * abs(d) { m = 3 * d }
            return m
        }
        let dl = delta(i - 1), dr = delta(i)
        if dl * dr <= 0 { return 0 }
        let hl = knots[i].step - knots[i - 1].step
        let hr = knots[i + 1].step - knots[i].step
        let w1 = 2 * hr + hl, w2 = hr + 2 * hl
        return (w1 + w2) / (w1 / dl + w2 / dr)
    }
}
