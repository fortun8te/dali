import Foundation

extension Output {
    /// A selected preference can survive a dead AirPlay session. AP2 receivers
    /// may remain connected-only while carrying audio, so either live backend
    /// state is sufficient. Older engines omit both fields.
    public var isSessionReady: Bool {
        guard selected else { return false }
        if streaming != nil || connected != nil {
            return (streaming ?? false) || (connected ?? false)
        }
        return true
    }
}

public enum OutputReadiness {
    /// Account for time spent waiting on HTTP as well as polling sleeps. The old
    /// sleep-only counter turned an eight-second deadline into minutes when the
    /// engine was slow. Cancellation also prevents stale replies declaring an
    /// abandoned session ready.
    public static func missing(
        ids: Set<String>,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(250),
        failFastAfter: Duration? = nil,
        query: @escaping @Sendable () async throws -> [Output]
    ) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var missing = ids
        let began = clock.now
        while !Task.isCancelled, clock.now < deadline {
            // The group is cancelled at the deadline, which only makes BeamAPI
            // stop WAITING: the request itself is never aborted mid-serve (that
            // is what crashes OwnTone), and its late reply is discarded.
            let outputs = await withTaskGroup(of: [Output]?.self) { group in
                group.addTask { try? await query() }
                group.addTask {
                    try? await clock.sleep(until: deadline)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let outputs {
                guard !Task.isCancelled, clock.now < deadline else { return missing }
                let ready = Set(outputs.filter(\.isSessionReady).map(\.id))
                missing = ids.subtracting(ready)
                if missing.isEmpty { return [] }
                // Every requested output was deselected by the engine (probe /
                // activation failed): nothing is warming, so waiting out the
                // deadline only delays the reset by seconds.
                if let grace = failFastAfter, clock.now >= began.advanced(by: grace) {
                    let asked = outputs.filter { ids.contains($0.id) }
                    if Set(asked.map(\.id)) == ids,
                       asked.allSatisfy({ !$0.selected && $0.connected == false && $0.streaming == false }) {
                        return missing
                    }
                }
            }
            guard !Task.isCancelled, clock.now < deadline else { break }
            // Floor the interval: a query that fails instantly (engine down,
            // connection refused) with a zero interval would spin the CPU.
            let wake = min(clock.now.advanced(by: max(pollInterval, .milliseconds(10))), deadline)
            do { try await clock.sleep(until: wake) }
            catch { break }
        }
        return missing
    }
}

/// One full-room reset is permitted only after the engine explicitly reports
/// every requested session failed. Missing discovery or a still-selected,
/// warming receiver must never tear down a potentially healthy partner.
public struct RoomStartupRecovery {
    private var used = false
    public init() {}

    public mutating func claimReset(ids: Set<String>, missing: Set<String>, outputs: [Output]) -> Bool {
        guard !used, !ids.isEmpty, missing == ids else { return false }
        let requested = outputs.filter { ids.contains($0.id) }
        guard Set(requested.map(\.id)) == ids,
              requested.allSatisfy({ !$0.selected && $0.connected == false && $0.streaming == false }) else {
            return false
        }
        used = true
        return true
    }
}
