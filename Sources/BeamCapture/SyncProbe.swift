import Accelerate
import Foundation

/// The lip-sync check. DALI sends a few short chirps through the room in place of
/// the Mac's audio, the Mac's microphone hears them land, and the time between the
/// two is the room's real delay: the number the browser picture has to wait.
///
/// The chirps sit at irregular offsets so only one delay lines all of them up with
/// what the microphone heard; a regular beat would also match at a whole beat early
/// or late. Each chirp is a short rising sweep, which a matched filter can time to a
/// fraction of a millisecond even with music, talk or a room echo around it.
public enum SyncProbe {
    /// Quiet before the first chirp, so audio already on its way to the room
    /// finishes before the first chirp lands.
    public static let leadSec = 0.4
    /// When each chirp starts, after the lead.
    public static let burstOffsets: [Double] = [0, 0.37, 0.95, 1.71]
    public static let chirpSec = 0.06
    public static let lowHz = 500.0
    public static let highHz = 7_000.0
    /// Peak level, about -10 dBFS: clear over a quiet room, never harsh.
    public static let amplitude = 0.3
    /// The pipe's sample rate.
    public static let pipeRate = 44_100.0

    /// Seconds from the first written frame to the end of the last chirp.
    public static var patternSec: Double { leadSec + (burstOffsets.last ?? 0) + chirpSec }

    /// One chirp, `t` seconds after it starts. Zero outside the chirp.
    public static func chirp(_ t: Double) -> Double {
        guard t >= 0, t < chirpSec else { return 0 }
        let sweep = (highHz - lowHz) / chirpSec
        let phase = 2 * Double.pi * (lowHz * t + 0.5 * sweep * t * t)
        let window = 0.5 - 0.5 * cos(2 * Double.pi * t / chirpSec)
        return sin(phase) * window
    }

    /// The probe, `t` seconds after its first frame.
    public static func value(at t: Double) -> Double {
        let local = t - leadSec
        for offset in burstOffsets where local >= offset && local < offset + chirpSec {
            return chirp(local - offset) * amplitude
        }
        return 0
    }

    /// Writes the probe over interleaved s16 stereo at the pipe rate, the same
    /// chirp in both channels. After the pattern it writes silence.
    public struct Writer: Sendable {
        public private(set) var frame = 0
        public init() {}
        public var finished: Bool { Double(frame) / SyncProbe.pipeRate >= SyncProbe.patternSec }

        public mutating func write(into data: inout Data) {
            var next = frame
            data.withUnsafeMutableBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                var i = 0
                while i + 1 < samples.count {
                    let v = SyncProbe.value(at: Double(next) / SyncProbe.pipeRate)
                    let s = Int16(max(-32768, min(32767, (v * 32768).rounded())))
                    samples[i] = s
                    samples[i + 1] = s
                    i += 2
                    next += 1
                }
            }
            frame = next
        }
    }

    public struct Result: Equatable, Sendable {
        /// From the probe's first written frame to its sound reaching the microphone.
        public let delaySec: Double
        /// How many of the chirps were heard clearly.
        public let heard: Int
        /// Disagreement between the chirps, in milliseconds.
        public let spreadMs: Double
        /// Best match over the next best one more than 30 ms away.
        public let uniqueness: Double
    }

    /// Times the chirps in a microphone recording.
    ///
    /// - Parameters:
    ///   - recording: mono samples.
    ///   - recordingStart: when the first sample was heard, on the same clock (seconds)
    ///     as `emittedAt`.
    ///   - emittedAt: when the probe's first frame went into the room path.
    ///   - search: the delays to consider, in seconds.
    /// - Returns: nil when the chirps were not heard clearly enough to trust.
    public static func measure(recording: [Float], sampleRate: Double, recordingStart: Double,
                               emittedAt: Double, search: ClosedRange<Double>) -> Result? {
        guard sampleRate > 8_000, search.lowerBound >= 0 else { return nil }
        let templateCount = Int((chirpSec * sampleRate).rounded())
        guard templateCount > 16, recording.count > templateCount * 4 else { return nil }
        let template = (0..<templateCount).map { Float(chirp(Double($0) / sampleRate)) }

        // Matched filter: correlation of the recording with one chirp. Its peak
        // sits on the sample where a chirp starts.
        let outCount = recording.count - templateCount + 1
        var matched = [Float](repeating: 0, count: outCount)
        recording.withUnsafeBufferPointer { x in
            template.withUnsafeBufferPointer { f in
                matched.withUnsafeMutableBufferPointer { c in
                    vDSP_conv(x.baseAddress!, 1, f.baseAddress!, 1, c.baseAddress!, 1,
                              vDSP_Length(outCount), vDSP_Length(templateCount))
                }
            }
        }
        var magnitude = [Float](repeating: 0, count: outCount)
        vDSP_vabs(matched, 1, &magnitude, 1, vDSP_Length(outCount))
        // A 1 ms running maximum turns the filter's fine ripple into a smooth
        // envelope, so the coarse search cannot fall between two ripples.
        let half = max(1, Int(0.0005 * sampleRate))
        var envelope = [Float](repeating: 0, count: outCount)
        if outCount > 2 * half {
            let windows = outCount - 2 * half
            magnitude.withUnsafeBufferPointer { m in
                envelope.withUnsafeMutableBufferPointer { e in
                    vDSP_vswmax(m.baseAddress!, 1, e.baseAddress! + half, 1,
                                vDSP_Length(windows), vDSP_Length(2 * half + 1))
                }
            }
        }

        // The floor the chirps have to stand out from.
        let floor: Float = {
            let step = max(1, outCount / 4096)
            let sample = stride(from: 0, to: outCount, by: step).map { magnitude[$0] }.sorted()
            return max(sample[sample.count / 2], 1e-9)
        }()

        func index(_ burst: Int, delay: Double) -> Int {
            Int(((emittedAt + leadSec + burstOffsets[burst] + delay - recordingStart) * sampleRate).rounded())
        }
        let first = Int((search.lowerBound * sampleRate).rounded())
        let last = Int((search.upperBound * sampleRate).rounded())
        guard last > first else { return nil }
        var scores = [Float](repeating: 0, count: last - first + 1)
        var best = 0
        for step in 0...(last - first) {
            let delay = Double(first + step) / sampleRate
            var score: Float = 0
            for burst in burstOffsets.indices {
                let n = index(burst, delay: delay)
                if n >= 0, n < outCount { score += envelope[n] }
            }
            scores[step] = score
            if score > scores[best] { best = step }
        }
        guard scores[best] > 0 else { return nil }
        let exclusion = Int(0.03 * sampleRate)
        var runnerUp: Float = 0
        for step in scores.indices where abs(step - best) > exclusion {
            runnerUp = max(runnerUp, scores[step])
        }
        let uniqueness = Double(scores[best] / max(runnerUp, 1e-9))
        let coarse = Double(first + best) / sampleRate

        // Each chirp on its own, to the sample.
        let reach = Int(0.002 * sampleRate)
        var estimates: [Double] = []
        for burst in burstOffsets.indices {
            let centre = index(burst, delay: coarse)
            let lo = max(0, centre - reach), hi = min(outCount - 1, centre + reach)
            guard lo <= hi else { continue }
            var peak = lo
            for n in lo...hi where magnitude[n] > magnitude[peak] { peak = n }
            guard magnitude[peak] / floor >= 8 else { continue }
            let heardAt = recordingStart + Double(peak) / sampleRate
            estimates.append(heardAt - (emittedAt + leadSec + burstOffsets[burst]))
        }
        guard estimates.count >= 3 else { return nil }
        estimates.sort()
        let spreadMs = (estimates.last! - estimates.first!) * 1_000
        let median = estimates.count.isMultiple(of: 2)
            ? (estimates[estimates.count / 2 - 1] + estimates[estimates.count / 2]) / 2
            : estimates[estimates.count / 2]
        guard spreadMs <= 4, uniqueness >= 1.4 else { return nil }
        return Result(delaySec: median, heard: estimates.count, spreadMs: spreadMs, uniqueness: uniqueness)
    }
}
