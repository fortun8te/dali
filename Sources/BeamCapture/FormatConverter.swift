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
    private var outBuf: AVAudioPCMBuffer?

    public init?(from inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: Self.pipeSampleRate,
                                      channels: Self.pipeChannels,
                                      interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        // The tap almost always delivers 48k while the AirPlay pipe contract is
        // 44.1k, so EVERY sample passes through this resampler. The default SRC
        // quality is .medium — that, not the (lossless) ALAC AirPlay encode, is
        // what made the stream sound compressed. .max is the same SRC Core
        // Audio uses for sample-accurate offline conversion.
        conv.sampleRateConverterQuality = .max
        outFormat = out
        inFormat = inputFormat
        converter = conv
    }

    /// True when `format` has the rate and channel count this converter was built
    /// for. A mismatch means the device reconfigured and a new converter is needed.
    public func accepts(_ format: AVAudioFormat) -> Bool {
        format.sampleRate == inFormat.sampleRate && format.channelCount == inFormat.channelCount
    }

    /// Convert one buffer; returns interleaved s16le bytes ready for the pipe.
    public func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inRate = buffer.format.sampleRate
        // A zero/NaN rate would make the capacity math inf/NaN, and
        // AVAudioFrameCount(inf) is a hard trap.
        guard inRate.isFinite, inRate > 0, buffer.frameLength > 0 else { return nil }
        let want = (Double(buffer.frameLength) * (outFormat.sampleRate / inRate)).rounded(.up) + 64
        guard want.isFinite, want > 0, want < 16_000_000 else { return nil }
        let capacity = AVAudioFrameCount(want)
        if outBuf == nil || outBuf!.frameCapacity < capacity {
            guard let b = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
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
              let ch = outBuf.int16ChannelData else { return nil }
        let byteCount = Int(outBuf.frameLength) * Int(outFormat.channelCount) * MemoryLayout<Int16>.size
        return Data(bytes: ch[0], count: byteCount)
    }
}
