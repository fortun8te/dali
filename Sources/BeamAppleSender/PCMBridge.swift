import AVFoundation
import CoreMedia
import Foundation

/// Converts the Float32 `AVAudioPCMBuffer`s delivered by `ProcessTap.onBuffer`
/// into timestamped interleaved `CMSampleBuffer`s for `AVSampleBufferAudioRenderer`.
/// Creates no tap, renderer, output context, socket or audio device.
///
/// One bridge is one timeline epoch with one sample rate and channel count. A route
/// or format rebuild must make a new bridge instead of letting timestamps jump.
public final class PCMBridge {
    public enum Failure: Error, Equatable {
        case invalidFormat, changedFormat, allocation, coreMedia(OSStatus)
    }

    private var format: AVAudioFormat?
    private var description: CMAudioFormatDescription?
    public private(set) var nextFrame: Int64 = 0

    public init() {}

    public func packet(_ pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        let input = pcm.format
        let channels = Int(input.channelCount)
        let frames = Int(pcm.frameLength)
        guard input.commonFormat == .pcmFormatFloat32, input.sampleRate.isFinite,
              input.sampleRate >= 8_000, input.sampleRate <= 192_000,
              input.sampleRate.rounded() == input.sampleRate,
              channels >= 1, channels <= 8, frames > 0, frames <= 65_536,
              let source = pcm.floatChannelData else { throw Failure.invalidFormat }
        if let format {
            guard format.sampleRate == input.sampleRate, format.channelCount == input.channelCount
            else { throw Failure.changedFormat }
        } else {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: input.sampleRate,
                                             channels: input.channelCount, interleaved: true)
            else { throw Failure.invalidFormat }
            var asbd = target.streamDescription.pointee
            var made: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &made)
            guard status == noErr, let made else { throw Failure.coreMedia(status) }
            format = target
            description = made
        }
        guard let description else { throw Failure.invalidFormat }
        let bytes = frames * channels * MemoryLayout<Float>.size
        var storage: CMBlockBuffer?
        let allocated = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &storage)
        guard allocated == kCMBlockBufferNoErr, let storage else { throw Failure.allocation }
        var contiguous = 0, total = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let mapped = CMBlockBufferGetDataPointer(storage, atOffset: 0, lengthAtOffsetOut: &contiguous,
                                                 totalLengthOut: &total, dataPointerOut: &pointer)
        guard mapped == noErr, contiguous >= bytes, let pointer else { throw Failure.allocation }
        let destination = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = input.isInterleaved ? source[0][frame * channels + channel] : source[channel][frame]
                destination[frame * channels + channel] = value.isFinite ? value : 0
            }
        }
        var packet: CMSampleBuffer?
        let made = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: storage, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: CMTime(value: nextFrame, timescale: CMTimeScale(input.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &packet)
        guard made == noErr, let packet else { throw Failure.coreMedia(made) }
        nextFrame += Int64(frames)
        return packet
    }
}
