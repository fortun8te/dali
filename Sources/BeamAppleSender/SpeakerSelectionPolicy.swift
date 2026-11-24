import Foundation

/// When the person has finished choosing speakers in Apple's picker.
///
/// The picker applies each tick straight away and never says "done", so the
/// sender decides from what it can see: the speakers now in the route and how
/// long that set has been unchanged.
public enum SpeakerSelectionPolicy {
    /// Time the route must stay unchanged before it counts as final.
    public static let settleSeconds: TimeInterval = 6

    /// - Parameters:
    ///   - remembered: speakers wanted (used last time, or switched on in DALI).
    ///     Once all are in the route, go at once.
    ///   - current: speakers in the route now.
    ///   - stableFor: seconds `current` has been unchanged.
    public static func isFinished(remembered: [String], current: [String],
                                  stableFor: TimeInterval) -> Bool {
        guard !current.isEmpty else { return false }
        if !remembered.isEmpty, Set(remembered).isSubset(of: Set(current)) { return true }
        return stableFor >= settleSeconds
    }
}
