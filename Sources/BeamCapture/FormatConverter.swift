// Converts tap buffers (any Float32 layout/rate) to OwnTone pipe format:
// PCM signed 16-bit little-endian, 44100 Hz, 2 channels, interleaved.

import Foundation
import AVFoundation

public final class FormatConverter {
    public static let pipeSampleRate: Double = 44100
    public static let pipeChannels: AVAudioChannelCount = 2

    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private let inFormat: AVAudioFormat
    // Reused across calls: one allocation per stream instead of one per buffer.
    private var outBuf: AVAudioPCMBuffer?     // Float32 interleaved @ 44.1k
    private let floatFormat: AVAudioFormat
    private var s16Scratch = [Int16]()
    private var rng: UInt32 = 0x9E3779B9      // xorshift32 state, persists across buffers

    private var volume: PCMVolumeRamp
    public var appliedMasterGain: Double { volume.applied }
    // Source state before software master gain, for tap/silence recovery.
    public private(set) var outputWasSilent = true

    public init?(from inputFormat: AVAudioFormat, initialGain: Double = 1) {
        volume = PCMVolumeRamp(initialGain: initialGain)
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: Self.pipeSampleRate,
                                      channels: Self.pipeChannels,
                                      interleaved: true),
              let flt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Self.pipeSampleRate,
                                      channels: Self.pipeChannels,
                                      interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: flt) else { return nil }
        // The tap almost always delivers 48k while the AirPlay pipe contract is
        // 44.1k, so EVERY sample passes through this resampler. The default SRC
        // quality is .medium — that, not the (lossless) ALAC AirPlay encode, is
        // what made the stream sound compressed. .max is the same SRC Core
        // Audio uses for sample-accurate offline conversion.
        conv.sampleRateConverterQuality = .max
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        // Streaming: do not prime with leading silence (adds latency / a gap).
        conv.primeMethod = .none
        // SRC stays in Float32; the only Int16 quantisation is our dithered one.
        outFormat = out
        floatFormat = flt
        inFormat = inputFormat
        converter = conv
    }

    /// True when `format` has the rate and channel count this converter was built
    /// for. A mismatch means the device reconfigured and a new converter is needed.
    public func accepts(_ format: AVAudioFormat) -> Bool {
        format == inFormat
    }

    /// Convert one buffer; returns interleaved s16le bytes ready for the pipe.
    public func convert(_ buffer: AVAudioPCMBuffer, masterGain: Double = 1) -> Data? {
        let inRate = buffer.format.sampleRate
        // A zero/NaN rate would make the capacity math inf/NaN, and
        // AVAudioFrameCount(inf) is a hard trap.
        guard inRate.isFinite, inRate > 0, buffer.frameLength > 0 else { return nil }
        let want = (Double(buffer.frameLength) * (outFormat.sampleRate / inRate)).rounded(.up) + 64
        guard want.isFinite, want > 0, want < 16_000_000 else { return nil }
        let capacity = AVAudioFrameCount(want)
        if outBuf == nil || outBuf!.frameCapacity < capacity {
            guard let b = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: capacity) else { return nil }
            outBuf = b
        }
        guard let outBuf else { return nil }
        outBuf.frameLength = 0

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, outBuf.frameLength > 0,
              let ch = outBuf.floatChannelData else { return nil }
        let count = Int(outBuf.frameLength) * Int(outFormat.channelCount)
        let samples = UnsafeMutableBufferPointer(start: ch[0], count: count)
        outputWasSilent = !samples.contains { $0 != 0 }
        volume.apply(to: samples, channels: Int(outFormat.channelCount),
                     sampleRate: outFormat.sampleRate, gain: masterGain)
        if s16Scratch.count < count { s16Scratch = [Int16](repeating: 0, count: count + 1024) }
        s16Scratch.withUnsafeMutableBufferPointer { dst in
            Self.quantize(UnsafeBufferPointer(start: ch[0], count: count), into: dst, rng: &rng)
        }
        return s16Scratch.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count * MemoryLayout<Int16>.size) }
    }

    /// Float32 [-1,1] -> S16 with TPDF dither (+-1 LSB), round-to-nearest, clamped.
    /// An all-zero input stays exactly zero (no dither on digital silence).
    /// Non-finite samples become 0. `rng` is xorshift32 state, must be nonzero.
    static func quantize(_ src: UnsafeBufferPointer<Float>, into dst: UnsafeMutableBufferPointer<Int16>,
                         rng: inout UInt32) {
        let n = src.count
        var silent = true
        for i in 0..<n where src[i] != 0 { silent = false; break }
        if silent { for i in 0..<n { dst[i] = 0 }; return }
        var s = rng == 0 ? 0x9E3779B9 : rng
        let inv = Float(1.0 / 4294967296.0)
        for i in 0..<n {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            let a = Float(s) * inv
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            let b = Float(s) * inv
            let d = a + b - 1.0                       // triangular in (-1, 1) LSB
            let x = src[i]
            if !x.isFinite { dst[i] = 0; continue }
            let v = (x * 32768.0 + d).rounded(.toNearestOrAwayFromZero)
            dst[i] = Int16(max(-32768, min(32767, v)))
        }
        rng = s
    }
}
