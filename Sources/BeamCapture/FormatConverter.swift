// Converts tap buffers (any Float32 layout/rate) to OwnTone pipe format:
// PCM signed 16-bit little-endian, 44100 Hz, 2 channels, interleaved.

import Foundation
import AVFoundation

public final class FormatConverter {
    public static let pipeSampleRate: Double = 44100
    public static let pipeChannels: AVAudioChannelCount = 2

    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat

    public init?(from inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
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
        converter = conv
    }

    /// Convert one buffer; returns interleaved s16le bytes ready for the pipe.
    public func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

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
