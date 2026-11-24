import Accelerate
import Foundation

/// A real spectrum of the captured audio, as `bandCount` log-spaced bands from about
/// 45 Hz to 14 kHz, each 0...1.
///
/// The room's light used to be moved by three correlated numbers (bass, mid, treble
/// onsets), so every bar rose and fell together like one. This gives each bar its own
/// frequency. Values are relative to the loudest band of the last moments, over a
/// 40 dB range, so a quiet record and a loud one fill the display alike; true silence
/// stays at zero.
///
/// Called from the capture analysis queue, never from the audio thread.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = 32
    static let size = 2048
    /// dB below the loudest band that still shows.
    static let rangeDb: Float = 40
    /// A band below this (about a 60 dB-down sine) is silence, whatever else is playing.
    static let floorDb: Float = 0
    /// How fast the reference falls back when the music gets quieter, per analysed buffer.
    static let referenceFallDb: Float = 0.06

    private let sampleRate: Double
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private let window: [Float]
    /// Bin edges of every band: `edges[k]..<edges[k + 1]`.
    private let edges: [Int]
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: size)
    private var head = 0
    private var filled = 0
    private var reference: Float = SpectrumAnalyzer.floorDb
    private var frame = [Float](repeating: 0, count: size)
    private var windowed = [Float](repeating: 0, count: size)
    private var realPart = [Float](repeating: 0, count: size / 2)
    private var imagPart = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)

    public init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: Self.size)
        vDSP_hann_window(&hann, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        window = hann
        let binHz = sampleRate / Double(Self.size)
        let low = 45.0, high = min(14_000.0, sampleRate / 2 - binHz)
        var e: [Int] = []
        for k in 0...Self.bandCount {
            let f = low * pow(high / low, Double(k) / Double(Self.bandCount))
            let bin = Int((f / binHz).rounded())
            e.append(max(bin, (e.last ?? 1) + 1))
        }
        edges = e
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// The middle frequency of a band, for tests and labelling.
    public func centerFrequency(band: Int) -> Double {
        let b = min(max(band, 0), Self.bandCount - 1)
        return Double(edges[b] + edges[b + 1]) / 2 * sampleRate / Double(Self.size)
    }

    /// Forget the recent past (a new session).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in ring.indices { ring[i] = 0 }
        head = 0; filled = 0; reference = Self.floorDb
    }

    /// Feed interleaved 16-bit stereo and get the bands for the newest window, or nil
    /// until a full window has arrived.
    public func push(stereo samples: UnsafeBufferPointer<Int16>) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let frames = samples.count / 2
        guard frames > 0 else { return nil }
        let scale: Float = 1 / (2 * 32768)
        for f in 0..<frames {
            ring[head] = (Float(samples[2 * f]) + Float(samples[2 * f + 1])) * scale
            head += 1
            if head == Self.size { head = 0 }
        }
        filled = min(Self.size, filled + frames)
        guard filled >= Self.size else { return nil }
        return bands()
    }

    private func bands() -> [Float] {
        let n = Self.size
        let tail = n - head
        for i in 0..<tail { frame[i] = ring[head + i] }
        for i in 0..<head { frame[tail + i] = ring[i] }
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                realPart.withUnsafeMutableBufferPointer { rp in
                    imagPart.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }
        // Energy per band in dB, tilted up 2 dB per octave: music falls away towards the
        // treble, and without the tilt the right half of the display would stay low.
        var db = [Float](repeating: 0, count: Self.bandCount)
        var loudest = -Float.infinity
        for k in 0..<Self.bandCount {
            var sum: Float = 0
            for bin in edges[k]..<min(edges[k + 1], n / 2) { sum += power[bin] }
            let centre = Float(centerFrequency(band: k))
            let tilt = 2 * log2(max(centre, 1) / 1000)
            db[k] = 10 * log10(sum + 1e-12) + tilt
            loudest = max(loudest, db[k])
        }
        guard loudest > Self.floorDb else { return [Float](repeating: 0, count: Self.bandCount) }
        reference = max(loudest, reference - Self.referenceFallDb, Self.floorDb)
        return db.map { min(max(($0 - (reference - Self.rangeDb)) / Self.rangeDb, 0), 1) }
    }
}
