import AVFoundation

/// Level and gain helpers for the buffers the capture tap delivers.
public enum PCMLevel {
    /// Largest absolute sample, 0...1 for normal audio.
    public static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        var top: Float = 0
        forEachSample(buffer) { top = max(top, abs($0)) }
        return top
    }

    /// Multiply every sample by `gain`, in place. A gain of exactly 1 is a no-op.
    public static func scale(_ buffer: AVAudioPCMBuffer, by gain: Float) {
        guard gain != 1, let data = buffer.floatChannelData else { return }
        let interleaved = buffer.format.isInterleaved
        let channels = interleaved ? 1 : Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength) * (interleaved ? Int(buffer.format.channelCount) : 1)
        for channel in 0..<channels { for i in 0..<count { data[channel][i] *= gain } }
    }

    private static func forEachSample(_ buffer: AVAudioPCMBuffer, _ body: (Float) -> Void) {
        guard let data = buffer.floatChannelData else { return }
        let interleaved = buffer.format.isInterleaved
        let channels = interleaved ? 1 : Int(buffer.format.channelCount)
        let count = Int(buffer.frameLength) * (interleaved ? Int(buffer.format.channelCount) : 1)
        for channel in 0..<channels { for i in 0..<count { body(data[channel][i]) } }
    }
}
