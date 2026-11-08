import Foundation
import os

public enum BeamWriteResult: Equatable, Sendable {
    case applied, superseded, unknown
}

public enum BeamRequestError: Error, Equatable, Sendable, LocalizedError {
    case superseded
    case queueFull
    case sessionInvalidated
    case deadlineExceeded

    public var errorDescription: String? {
        switch self {
        case .superseded: "A newer command replaced this queued request."
        case .queueFull: "The engine request queue is full."
        case .sessionInvalidated: "The engine session changed before this request completed."
        case .deadlineExceeded: "The engine did not reply before the caller's deadline."
        }
    }
}

/// The caller's patience must never become URLSession's socket lifetime. Historic
/// OwnTone versions crash when replying to an HTTP client that has hung up during
/// an RTSP stall. Every API for one port shares a lane and one on-wire request.
/// Caller timeout, cancellation and supersession finish only the reply slot.
protocol BeamHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
}

struct URLSessionBeamTransport: BeamHTTPTransport {
    func send(_ request: URLRequest) async throws -> Data {
        // A session per request prevents reuse of an old engine's socket.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldUsePipelining = false
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BeamAPIError(what: "\(request.httpMethod ?? "GET") \(request.url?.path ?? "?") -> \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }
}

/// Resolves once, including when cancellation precedes continuation installation.
final class ReplySlot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var finished = false

    var isResolved: Bool { lock.withLock { finished } }

    @discardableResult
    func resolve(_ result: Result<Data, Error>) -> Bool {
        var accepted = false
        let target: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            accepted = true
            let target = continuation
            continuation = nil
            if target == nil { self.result = result }
            return target
        }
        target?.resume(with: result)
        return accepted
    }

    func wait() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let completed: Result<Data, Error>? = lock.withLock {
                if let result {
                    self.result = nil
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let completed { continuation.resume(with: completed) }
        }
    }
}

final class RequestLane: @unchecked Sendable {
    struct Snapshot: Sendable {
        let queued: Int
        let inFlight: Bool
        let highWaterMark: Int
        let epoch: UInt64
        let accepting: Bool
    }

    private struct Op: Sendable {
        let request: URLRequest
        let slot: ReplySlot
        let epoch: UInt64
        let coalesceKey: String?
        let writeKind: String?
    }
    private struct State {
        var queue: [Op] = []
        var active: Op?
        var epoch: UInt64 = 0
        var accepting = true
        var notBefore = ContinuousClock.now
        var wakePending = false
        var highWaterMark = 0
        var controlStreak = 0
        var writes: [(at: Date, kind: String)] = []
        var totalWrites = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private static let registry = OSAllocatedUnfairLock(initialState: [Int: RequestLane]())
    static func shared(port: Int) -> RequestLane {
        registry.withLock { lanes in
            if let lane = lanes[port] { return lane }
            let lane = RequestLane(transport: URLSessionBeamTransport())
            lanes[port] = lane
            return lane
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let transport: any BeamHTTPTransport
    let capacity: Int

    /// Internal injection avoids creating an independent production lane for a
    /// live port. Tests own their lane and transport without touching sockets.
    init(transport: any BeamHTTPTransport, capacity: Int = 32) {
        self.transport = transport
        self.capacity = max(1, capacity)
    }

    var sessionEpoch: UInt64 { state.withLock { $0.epoch } }
    var snapshot: Snapshot {
        state.withLock { Snapshot(queued: $0.queue.count, inFlight: $0.active != nil,
                                  highWaterMark: $0.highWaterMark, epoch: $0.epoch,
                                  accepting: $0.accepting) }
    }

    func send(_ request: URLRequest, deadline: TimeInterval, epoch: UInt64,
              coalesceKey: String? = nil, writeKind: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard deadline.isFinite, deadline > 0 else { throw BeamRequestError.deadlineExceeded }
        let slot = ReplySlot()
        let op = Op(request: request, slot: slot, epoch: epoch,
                    coalesceKey: coalesceKey, writeKind: writeKind)
        // Bound the timer conversion too, even for an accidental huge deadline.
        let timer = Task {
            do { try await Task.sleep(for: .seconds(min(deadline, 86_400))) }
            catch { return }
            self.abandon(slot, error: BeamRequestError.deadlineExceeded)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            enqueue(op)
            return try await slot.wait()
        } onCancel: {
            self.abandon(slot, error: CancellationError())
        }
    }

    private func enqueue(_ op: Op) {
        let completions: [(ReplySlot, BeamRequestError)] = state.withLock { s in
            s.queue.removeAll { $0.slot.isResolved }
            guard !op.slot.isResolved else { return [] }
            guard s.accepting, op.epoch == s.epoch else { return [(op.slot, .sessionInvalidated)] }
            var completions: [(ReplySlot, BeamRequestError)] = []
            if let key = op.coalesceKey {
                completions = s.queue.filter { $0.coalesceKey == key }.map { ($0.slot, .superseded) }
                s.queue.removeAll { $0.coalesceKey == key }
            }
            guard s.queue.count < capacity else { return completions + [(op.slot, .queueFull)] }
            s.queue.append(op)
            s.highWaterMark = max(s.highWaterMark, s.queue.count)
            return completions
        }
        for (slot, error) in completions { slot.resolve(.failure(error)) }
        pump()
    }

    private func abandon(_ slot: ReplySlot, error: Error) {
        // Removal is immediate; a stalled active socket cannot retain an abandoned
        // queued caller or allow that command to run after its deadline.
        slot.resolve(.failure(error))
        state.withLock { $0.queue.removeAll { $0.slot === slot } }
        pump()
    }

    @discardableResult
    func invalidateSession() -> UInt64 { invalidate(accepting: nil) }
    func suspendSession() { _ = invalidate(accepting: false) }
    func resumeSession() { _ = invalidate(accepting: true) }

    private func invalidate(accepting: Bool?) -> UInt64 {
        let invalidated: ([ReplySlot], UInt64) = state.withLock { s in
            s.epoch &+= 1
            if let accepting { s.accepting = accepting }
            let slots = s.queue.map(\.slot) + (s.active.map { [$0.slot] } ?? [])
            s.queue.removeAll()
            s.controlStreak = 0
            return (slots, s.epoch)
        }
        for slot in invalidated.0 { slot.resolve(.failure(BeamRequestError.sessionInvalidated)) }
        pump()
        return invalidated.1
    }

    /// A stopped engine closes its old connection server-side. A new engine may
    /// only start after this drain, so a selected-but-not-yet-sent operation cannot
    /// land on the successor. No socket is cancelled to speed up this wait.
    func waitForDrain() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { s in
                if s.active == nil && s.queue.isEmpty { return true }
                s.drainWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func recentWrites(window: TimeInterval) -> [String: Int] {
        let cutoff = Date().addingTimeInterval(-window)
        return state.withLock { s in
            s.writes.removeAll { $0.at < Date().addingTimeInterval(-600) }
            var counts: [String: Int] = [:]
            for write in s.writes where write.at >= cutoff { counts[write.kind, default: 0] += 1 }
            return counts
        }
    }
    var totalWrites: Int { state.withLock { $0.totalWrites } }

    func holdOff(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        state.withLock { $0.notBefore = max($0.notBefore, .now.advanced(by: .seconds(min(seconds, 60)))) }
        pump()
    }

    private enum Next { case none, run(Op), wait(Duration), drained([CheckedContinuation<Void, Never>]) }
    private func pump() {
        let next: Next = state.withLock { s in
            guard s.active == nil else { return .none }
            s.queue.removeAll { $0.slot.isResolved }
            guard !s.queue.isEmpty else {
                let waiters = s.drainWaiters
                s.drainWaiters.removeAll()
                return .drained(waiters)
            }
            let now = ContinuousClock.now
            if s.notBefore > now {
                guard !s.wakePending else { return .none }
                s.wakePending = true
                return .wait(now.duration(to: s.notBefore))
            }
            // Current controls get the next turn; after three controls a queued
            // health read gets a turn. Both classes retain their internal order.
            let read = s.queue.firstIndex { $0.writeKind == nil }
            let control = s.queue.firstIndex { $0.writeKind != nil }
            let index: Int
            if let read, s.controlStreak >= 3 || control == nil {
                index = read
                s.controlStreak = 0
            } else if let control {
                index = control
                s.controlStreak += 1
            } else {
                index = 0
                s.controlStreak = 0
            }
            let op = s.queue.remove(at: index)
            s.active = op
            return .run(op)
        }
        switch next {
        case .none: break
        case .drained(let waiters): for waiter in waiters { waiter.resume() }
        case .wait(let hold):
            Task {
                try? await Task.sleep(for: hold)
                self.state.withLock { $0.wakePending = false }
                self.pump()
            }
        case .run(let op):
            // Unstructured ownership is deliberate. Caller cancellation must not
            // propagate to the URLSession task serving an old OwnTone connection.
            Task {
                await self.perform(op)
                self.state.withLock { $0.active = nil }
                self.pump()
            }
        }
    }

    private func perform(_ op: Op) async {
        let allowed = state.withLock { s in
            guard s.accepting, op.epoch == s.epoch, !op.slot.isResolved else { return false }
            if let kind = op.writeKind {
                s.writes.removeAll { $0.at < Date().addingTimeInterval(-600) }
                if s.writes.count >= 4096 { s.writes.removeFirst() }
                s.writes.append((Date(), kind))
                s.totalWrites += 1
            }
            return true
        }
        guard allowed else { return }
        do { op.slot.resolve(.success(try await transport.send(op.request))) }
        catch { op.slot.resolve(.failure(error)) }
    }
}
