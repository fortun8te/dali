import Foundation

/// The signal the speaker test sends: soft pink-ish noise in one channel, so each
/// corner of the room can be heard on its own. Noise is used because it can be
/// placed by ear, and it starts and stops on a short ramp so there is never a click.
/// Consumer-thread state: one per tap, like the varispeed.
struct SpeakerTestSignal {
    enum Output: Equatable, Sendable { case silence, left, right, circle }

    /// Seconds for a sound to go once round the room.
    static let circleSeconds = 5.0

    /// RMS of the noise, about -20 dBFS: under typical music, so it never jumps out.
    static let level = 0.1
    /// Fade length in frames, about 5 ms at the pipe rate.
    static let rampFrames = 220.0

    private var seed: UInt32 = 0x7F4A7C15
    private var low = 0.0
    private var mid = 0.0
    private var gain = (left: 0.0, right: 0.0)
    private var circleFrame = 0.0
    private var inPhase = HilbertPath(coefficients: [0.6923878, 0.9360654322959, 0.9882295226860, 0.9987488452737])
    private var quadrature = HilbertPath(coefficients: [0.4021921162426, 0.8561710882420, 0.9722909545651, 0.9952884791278])
    private var quadratureDelay = 0.0
    private var circleGain = 0.0

    /// Half of a wideband 90-degree phase splitter: a chain of second-order all-passes.
    private struct HilbertPath {
        var stages: [(a: Double, x1: Double, x2: Double, y1: Double, y2: Double)]
        init(coefficients: [Double]) { stages = coefficients.map { ($0 * $0, 0, 0, 0, 0) } }
        mutating func process(_ input: Double) -> Double {
            var x = input
            for i in stages.indices {
                let y = stages[i].a * (x + stages[i].y2) - stages[i].x2
                stages[i].x2 = stages[i].x1; stages[i].x1 = x
                stages[i].y2 = stages[i].y1; stages[i].y1 = y
                x = y
            }
            return x
        }
    }

    /// The left and right that place a sound at `angle` (0 ahead, clockwise) the way a
    /// surround mix does: the side is the balance, ahead or behind is the phase between
    /// the channels. It goes through the real decoder, so it proves the whole path.
    private mutating func circleSample(_ noise: Double) -> (left: Double, right: Double) {
        let angle = 2 * Double.pi * circleFrame / (Self.circleSeconds * 44_100)
        circleFrame += 1
        if circleFrame >= Self.circleSeconds * 44_100 { circleFrame = 0 }
        let i = inPhase.process(noise)
        let q = quadratureDelay
        quadratureDelay = quadrature.process(noise)
        let side = sin(angle), ahead = cos(angle)
        let balance = (side + 1) * Double.pi / 4
        let phase = (1 - ahead) * Double.pi / 2
        let root2 = 2.0.squareRoot()
        return (cos(balance) * i * root2, sin(balance) * (cos(phase) * i + sin(phase) * q) * root2)
    }

    /// Replace an interleaved s16 stereo buffer in place, at the same length, so
    /// pipe pacing and the drift controller carry on exactly as with real audio.
    mutating func write(_ output: Output, into data: inout Data) {
        let wanted = (left: output == .left ? 1.0 : 0.0, right: output == .right ? 1.0 : 0.0)
        let step = 1.0 / Self.rampFrames
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var frame = 0
            while frame + 1 < samples.count {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let white = Double(seed) / Double(UInt32.max) * 2 - 1
                // Two leaky stages tilt white noise down, so it sounds soft and full.
                low += 0.03 * (white - low)
                mid += 0.25 * (white - mid)
                let noise = (2.4 * low + 0.9 * mid + 0.22 * white) * Self.level / 0.32
                circleGain += max(-step, min(step, (output == .circle ? 1.0 : 0.0) - circleGain))
                if output == .circle || circleGain > 0 {
                    let placed = circleSample(noise)
                    gain.left += max(-step, min(step, wanted.left - gain.left))
                    gain.right += max(-step, min(step, wanted.right - gain.right))
                    samples[frame] = Self.sample(placed.left * circleGain + noise * gain.left)
                    samples[frame + 1] = Self.sample(placed.right * circleGain + noise * gain.right)
                    frame += 2
                    continue
                }
                gain.left += max(-step, min(step, wanted.left - gain.left))
                gain.right += max(-step, min(step, wanted.right - gain.right))
                samples[frame] = Self.sample(noise * gain.left)
                samples[frame + 1] = Self.sample(noise * gain.right)
                frame += 2
            }
        }
    }

    private static func sample(_ value: Double) -> Int16 {
        Int16(max(-32768, min(32767, (value * 32768).rounded())))
    }
}
