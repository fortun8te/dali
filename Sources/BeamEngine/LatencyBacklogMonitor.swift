import Foundation

/// Detects a room that has fallen permanently behind the Mac.
///
/// The app-side PCM queue only grows when OwnTone has stopped reading the
/// pipe, which it does once its own input buffer reaches INPUT_BUFFER_THRESHOLD
/// (96000 frames, ~2.18 s). After a network drop or a player stall, the engine
/// fills that buffer, the app queue takes the rest, and when playback resumes
/// both are drained at exactly real time. Nothing ever shrinks them again. The
/// room then plays 2.18 s plus the queue later than the nominal room delay, and
/// browser video, which follows the nominal delay, is that far out of sync.
///
/// Measured 2026-10-11: a 3 s network drop left a steady 1.17 s app queue
/// (`hold=backpressure`) for the rest of the session. Before the drop the queue
/// was empty on every flight sample. Replaying the pipe after discarding the
/// queue is the only reset.
public struct LatencyBacklogMonitor {
    public static let bytesPerSecond = 176_400.0

    /// Same line the timing controller uses for `backpressure`.
    public var thresholdSec = 0.25
    /// A queue must stay above the line this long while the player plays.
    public var sustainSec = 5.0
    /// Minimum spacing between replays. Doubles each time a replay is followed
    /// by another backlog within `repeatWindowSec` of the cooldown ending, so a
    /// cause a replay cannot fix costs one dip, then progressively rarer ones.
    public var cooldownSec = 60.0
    public var maxCooldownSec = 1_800.0
    public var repeatWindowSec = 300.0

    private var aboveSec = 0.0
    private var sinceFlushSec = Double.infinity
    private var repeats = 0

    public init() {}

    /// One flight sample. `playing` is nil when the player state is unknown
    /// (API busy or slow); unknown samples neither count nor clear progress.
    /// Returns true when the caller should discard the queue and replay.
    public mutating func update(dt: Double, pendingBytes: Int, playing: Bool?) -> Bool {
        let dt = dt.isFinite ? min(max(dt, 0), 5) : 1
        sinceFlushSec += dt
        guard let playing else { return false }
        guard playing, Double(max(pendingBytes, 0)) / Self.bytesPerSecond > thresholdSec else {
            aboveSec = 0
            return false
        }
        aboveSec += dt
        guard aboveSec >= sustainSec, sinceFlushSec >= requiredCooldownSec else { return false }
        // Measured past the cooldown, so a backoff that has grown beyond the
        // window does not reset itself to the shortest spacing.
        repeats = sinceFlushSec < requiredCooldownSec + repeatWindowSec ? repeats + 1 : 0
        aboveSec = 0
        sinceFlushSec = 0
        return true
    }

    var requiredCooldownSec: Double {
        min(cooldownSec * pow(2, Double(min(repeats, 10))), maxCooldownSec)
    }
}
