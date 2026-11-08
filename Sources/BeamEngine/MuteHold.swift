import Foundation

/// Keeps the speakers' volume for a short moment after the Mac volume reaches zero
/// from the quiet end, so a brush through zero never reaches the speakers.
///
/// The captured audio is silenced at once, so nothing new is sent. Muting the
/// speakers themselves is a slow write to each one in turn, and bringing them back
/// is another pair of slow writes, so a quick brush through zero used to cut both
/// speakers for about a second with one returning half a second after the other.
///
/// Only the quiet end is held. A mute from a louder level is applied at once, because
/// the speakers still hold about a room delay of audio and an immediate mute is what
/// cuts it short.
public struct MuteHold: Sendable {
    public static let holdSeconds: TimeInterval = 0.5
    /// Mac volume (0...1) at or below which a mute is held: the first two of 16 steps.
    public static let quietEndMaster: Double = 2.0 / 16 + 0.001

    public struct Resolution: Equatable, Sendable {
        /// The volumes to send to the speakers now.
        public let targets: [String: Int]
        /// When set, ask again after this many seconds: the hold is still running.
        public let recheckAfter: TimeInterval?
    }

    private var lastAudible: [String: Int] = [:]
    private var lastMaster: Double = 1
    private var zeroSince: Date?

    public init() {}

    /// - Parameters:
    ///   - targets: what the volume plan wants for each speaker.
    ///   - master: the Mac volume driving the room, nil when it is not (other sources).
    ///   - mutedByOther: the room is muted for another reason (a browser cut), which is
    ///     never held.
    public mutating func resolve(targets: [String: Int], master: Double?, mutedByOther: Bool,
                                 now: Date) -> Resolution {
        let masterIsZero = master == 0 && !mutedByOther
        let allZero = !targets.isEmpty && targets.values.allSatisfy { $0 == 0 }
        if let master, master > 0 { lastMaster = master }
        guard masterIsZero, allZero else {
            zeroSince = nil
            // Remember what the room last really sent, zeros included, so a stale
            // volume is never raised again by a later mute.
            lastAudible = targets
            return Resolution(targets: targets, recheckAfter: nil)
        }
        // Nothing audible to hold, or the Mac was well above the quiet end: apply at once.
        guard lastAudible.values.contains(where: { $0 > 0 }), lastMaster <= Self.quietEndMaster else {
            return Resolution(targets: targets, recheckAfter: nil)
        }
        let since = zeroSince ?? now
        zeroSince = since
        let remaining = Self.holdSeconds - now.timeIntervalSince(since)
        guard remaining > 0 else { return Resolution(targets: targets, recheckAfter: nil) }
        let held = Dictionary(uniqueKeysWithValues: targets.keys.map { ($0, lastAudible[$0] ?? 0) })
        return Resolution(targets: held, recheckAfter: remaining + 0.02)
    }

    /// Forget everything, for a new session.
    public mutating func reset() {
        lastAudible = [:]
        lastMaster = 1
        zeroSince = nil
    }
}
