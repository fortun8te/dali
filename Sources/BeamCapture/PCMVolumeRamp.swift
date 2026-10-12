import Foundation

// One common gain for every channel. Local to a tap's converter; desired gain
// is read from CaptureController's lock once per buffer. A new tap starts at
// the desired level so a muted start never emits an initial full-volume frame.
struct PCMVolumeRamp {
    private(set) var applied: Double
    private var target: Double
    private var remaining = 0
    private var step = 0.0
    static let rampSeconds = 0.015

    init(initialGain: Double = 1) {
        let gain = initialGain.isFinite ? min(max(initialGain, 0), 1) : 0
        applied = gain; target = gain
    }
    mutating func apply(to samples: UnsafeMutableBufferPointer<Float>, channels: Int,
                        sampleRate: Double, gain: Double) {
        guard channels > 0, sampleRate.isFinite, sampleRate > 0 else { return }
        let requested = gain.isFinite ? min(max(gain, 0), 1) : target
        if requested != target {
            target = requested
            remaining = max(1, Int(min(sampleRate, 768_000) * Self.rampSeconds))
            step = (target - applied) / Double(remaining)
        }
        // Unity bypass does not touch the samples, preserving existing dither,
        // SRC and bit-exact varispeed passthrough behavior.
        if applied == 1, target == 1 { return }
        let frames = samples.count / channels
        for frame in 0..<frames {
            if remaining > 0 {
                remaining -= 1
                applied = remaining == 0 ? target : applied + step
            }
            let g = Float(applied)
            for channel in 0..<channels {
                let index = frame * channels + channel
                // Exactly-zero mute also suppresses any nonfinite input before
                // quantization; otherwise quantize performs normal sanitization.
                samples[index] = g == 0 ? 0 : samples[index] * g
            }
        }
    }
}
