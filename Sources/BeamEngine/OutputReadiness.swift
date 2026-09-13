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
        query: @escaping @Sendable () async throws -> [Output]
    ) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var missing = ids
        while !Task.isCancelled, clock.now < deadline {
            // URLSession cooperates with cancellation, so a stalled request is
            // also cut off at the deadline instead of adding its own timeout.
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
            }
            guard !Task.isCancelled, clock.now < deadline else { break }
            let wake = min(clock.now.advanced(by: pollInterval), deadline)
            do { try await clock.sleep(until: wake) }
            catch { break }
        }
        return missing
    }
}
