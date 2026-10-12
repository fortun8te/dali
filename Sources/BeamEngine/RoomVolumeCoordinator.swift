import Foundation

public enum RoomVolumeWriteResult: Sendable { case applied, superseded, unknown }

/// The only owner of output-volume requests. Intent, engine acceptance,
/// temporary setup silence and recovery eligibility are separate state. A late
/// reply may describe the old request, but cannot mutate a replacement session.
@MainActor
public final class RoomVolumeCoordinator {
    public typealias Write = @Sendable (String, Int) async -> RoomVolumeWriteResult
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Now = @MainActor () -> ContinuousClock.Instant
    public struct ObservationToken: Equatable, Sendable {
        let session: Int; let revision: Int; let writes: Int
    }
    private struct Waiter {
        let ticket: UUID
        let id: String; let value: Int; let session: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let write: Write
    private let sleep: Sleep
    private let minimumSpacing: Duration
    private let now: Now
    private var session = -1
    private var active = false
    private var desired: [String: Int] = [:]
    private var eligible: Set<String> = []
    private var temporary: [String: Int] = [:]
    private var failures: [String: Int] = [:]
    private var retryAt: [String: ContinuousClock.Instant] = [:]
    private var waiters: [Waiter] = []
    private var task: Task<Void, Never>?
    private var sleeper: Task<Void, Error>?
    private var driverGeneration = 0
    private var revision = 0
    private var writes = 0
    private var urgent = false
    public private(set) var applied: [String: Int] = [:]
    public private(set) var isWriting = false
    public private(set) var lastCompletionAt = Date.distantPast

    public init(minimumSpacing: Duration = .milliseconds(100),
                now: @escaping Now = { ContinuousClock.now },
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                write: @escaping Write) {
        self.minimumSpacing = minimumSpacing; self.now = now; self.sleep = sleep; self.write = write
    }

    public var observationToken: ObservationToken {
        ObservationToken(session: session, revision: revision, writes: writes)
    }

    public func update(session: Int, active: Bool, targets: [String: Int], eligible: Set<String>,
                       urgent: Bool = false, force: Set<String> = []) {
        if self.session != session || !active {
            invalidate()
            self.session = session
        }
        self.active = active
        guard active else { return }
        let bounded = targets.mapValues { min(max($0, 0), 100) }
        let eligibilityChanged = self.eligible != eligible
        let intentChanged = bounded != desired
        if intentChanged {
            revision += 1
            for (id, value) in bounded where desired[id] != value {
                failures[id] = nil; retryAt[id] = nil
            }
            desired = bounded
        }
        self.eligible = eligible
        for id in force { applied[id] = nil; failures[id] = nil; retryAt[id] = nil }
        self.urgent = self.urgent || urgent
        if intentChanged || eligibilityChanged || urgent || !force.isEmpty { sleeper?.cancel() }
        settleObsoleteWaiters()
        startDriver()
    }

    public func stop(session: Int) { update(session: session, active: false, targets: [:], eligible: []) }

    public func silence(_ id: String, session: Int) async -> Bool {
        guard active, self.session == session, desired[id] != nil else { return false }
        temporary[id] = 0; revision += 1; urgent = true
        failures[id] = nil; retryAt[id] = nil; sleeper?.cancel()
        return await awaitApplication(id, value: 0, session: session)
    }

    public func restore(_ id: String, session: Int) async -> Bool {
        guard active, self.session == session, let value = desired[id] else { return false }
        temporary[id] = nil; eligible.insert(id); revision += 1
        failures[id] = nil; retryAt[id] = nil; sleeper?.cancel()
        return await awaitApplication(id, value: value, session: session)
    }

    /// Polls can invalidate an accepted target only if no intent/write changed
    /// while they were in flight. Requested-value polls never confirm a write.
    public func observe(_ values: [String: Int], token: ObservationToken) {
        guard active, !isWriting, token == observationToken else { return }
        for (id, value) in values where desired[id] != nil {
            // OwnTone reports requested volume even after an RTSP failure.
            // A matching poll cannot upgrade an unknown write to acceptance.
            if value != target(id), temporary[id] == nil, eligible.contains(id),
                      abs(value - (desired[id] ?? 0)) > 1 {
                applied[id] = nil
                // A receiver echo can round by one command step. A larger
                // mismatch gets a sparse retry, rather than a write every poll.
                if retryAt[id] == nil { retryAt[id] = now().advanced(by: .seconds(30)) }
            }
        }
        finishSatisfiedWaiters()
        startDriver()
    }

    private func invalidate() {
        driverGeneration += 1; sleeper?.cancel(); sleeper = nil; task?.cancel(); task = nil; isWriting = false
        desired.removeAll(); applied.removeAll(); eligible.removeAll(); temporary.removeAll()
        failures.removeAll(); retryAt.removeAll(); urgent = false; revision += 1
        let old = waiters; waiters.removeAll()
        for waiter in old { waiter.continuation.resume(returning: false) }
    }

    private func target(_ id: String) -> Int? { temporary[id] ?? desired[id] }

    private func awaitApplication(_ id: String, value: Int, session: Int) async -> Bool {
        if applied[id] == value { return true }
        let ticket = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                waiters.append(Waiter(ticket: ticket, id: id, value: value, session: session, continuation: continuation))
                startDriver()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(ticket) }
        }
    }

    private func cancelWaiter(_ ticket: UUID) {
        guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func startDriver() {
        guard active, task == nil else { return }
        let generation = driverGeneration
        task = Task { [weak self] in await self?.drive(generation: generation) }
    }

    private func pendingIDs() -> [String] {
        desired.keys.filter { id in
            guard let value = target(id), applied[id] != value else { return false }
            return value == 0 || eligible.contains(id)
        }.sorted { a, b in
            if (target(a) == 0) != (target(b) == 0) { return target(a) == 0 }
            return a < b
        }
    }

    private func drive(generation: Int) async {
        defer { if generation == driverGeneration { task = nil; isWriting = false } }
        while active, generation == driverGeneration, !Task.isCancelled {
            let ids = pendingIDs()
            guard !ids.isEmpty else { finishSatisfiedWaiters(); return }
            let instant = now()
            guard let id = ids.first(where: { (retryAt[$0] ?? instant) <= instant }) else {
                let wake = ids.compactMap { retryAt[$0] }.min() ?? instant
                do { try await pause(instant.duration(to: wake)) } catch { return }
                continue
            }
            guard let value = target(id) else { continue }
            let epoch = session
            isWriting = true; writes += 1
            let result = await write(id, value)
            guard active, generation == driverGeneration, epoch == session, !Task.isCancelled else { return }
            isWriting = false; lastCompletionAt = Date()
            switch result {
            case .applied:
                applied[id] = value; failures[id] = nil; retryAt[id] = nil
            case .superseded:
                applied[id] = nil
            case .unknown:
                applied[id] = nil
                if target(id) == value {
                    let count = min((failures[id] ?? 0) + 1, 5)
                    failures[id] = count
                    retryAt[id] = now().advanced(by: .seconds(min(30, 3 << min(count - 1, 3))))
                    finishWaiters(id: id, success: false)
                } else {
                    // A failure of the old setting must not delay current mute
                    // or another intent that arrived while it was on the wire.
                    failures[id] = nil; retryAt[id] = nil
                }
            }
            finishSatisfiedWaiters()
            settleObsoleteWaiters()
            if !urgent {
                do { try await pause(minimumSpacing) } catch { return }
            }
            urgent = false
        }
    }

    /// Only the idle sleeper is canceled by new intent. The request itself
    /// continues to completion and its receipt is fenced by the driver epoch.
    private func pause(_ duration: Duration) async throws {
        guard duration > .zero else { return }
        let sleep = self.sleep
        let pending = Task { try await sleep(duration) }
        sleeper = pending
        do {
            try await pending.value
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // New intent woke this pause. Re-read current targets immediately.
        }
        if sleeper == pending { sleeper = nil }
    }

    private func finishWaiters(id: String, success: Bool) {
        let done = waiters.filter { $0.id == id }; waiters.removeAll { $0.id == id }
        for waiter in done { waiter.continuation.resume(returning: success) }
    }

    private func finishSatisfiedWaiters() {
        let done = waiters.filter { $0.session == session && applied[$0.id] == $0.value }
        waiters.removeAll { $0.session == session && applied[$0.id] == $0.value }
        for waiter in done { waiter.continuation.resume(returning: true) }
    }

    private func settleObsoleteWaiters() {
        let done = waiters.filter { $0.session != session || target($0.id) != $0.value }
        waiters.removeAll { $0.session != session || target($0.id) != $0.value }
        for waiter in done { waiter.continuation.resume(returning: false) }
    }
}
