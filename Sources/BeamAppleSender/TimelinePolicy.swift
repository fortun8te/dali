import Foundation

/// When the sender's audio timeline must start over.
///
/// The Mac stops delivering audio while nothing is playing, but Apple's renderer
/// keeps its clock running. Audio that arrives after such a gap is stamped in the
/// past and would be dropped, so a long enough gap starts a fresh timeline.
public enum TimelinePolicy {
    /// A gap this long between two buffers means the clock has moved on.
    public static let restartGapSeconds: TimeInterval = 0.3

    public static func needsRestart(gapSeconds: TimeInterval) -> Bool {
        gapSeconds > restartGapSeconds
    }
}
