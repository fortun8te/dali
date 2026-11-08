import Foundation

/// Keeps the two halves of a quiet-end volume change together.
///
/// Below the second Mac volume step, a change has two parts: the speakers' own
/// volume, which takes effect at once, and the shared digital gain, which only
/// reaches the speakers after the audio already in flight has played, about one
/// room delay later. Sent together they were heard as two separate changes with
/// a second between them. Holding the speaker volume back by that delay makes
/// them land as one.
public enum FloorSync {
    /// A write to a speaker takes roughly this long to take effect.
    public static let writeLatencySeconds: TimeInterval = 0.25

    /// How long to hold the speaker volume after the digital gain has changed.
    public static func holdSeconds(roomDelaySeconds: TimeInterval) -> TimeInterval {
        min(max(roomDelaySeconds - writeLatencySeconds, 0), 2)
    }

    /// True when the speaker volume should wait for the digital gain to arrive.
    /// A mute on either side is never held: silence must be immediate.
    public static func shouldHold(previousGain: Double, newGain: Double) -> Bool {
        guard previousGain > 0, newGain > 0 else { return false }
        return abs(newGain - previousGain) > 0.005
    }
}
