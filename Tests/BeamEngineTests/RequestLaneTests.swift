import Foundation
import XCTest
@testable import BeamEngine

actor ControlledBeamTransport: BeamHTTPTransport {
    struct Observation: Sendable {
        let requests: [URLRequest]
        let active: Int
        let maxActive: Int
        let cancellations: Int
    }
    private var requests: [URLRequest] = []
    private var replies: [CheckedContinuation<Data, Error>] = []
    private var active = 0
    private var maxActive = 0
    private var cancellations = 0

    func send(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1; if Task.isCancelled { cancellations += 1 } }
        return try await withCheckedThrowingContinuation { replies.append($0) }
    }
    var observation: Observation {
        Observation(requests: requests, active: active, maxActive: maxActive, cancellations: cancellations)
    }
    func reply(_ data: Data = Data()) {
        precondition(!replies.isEmpty)
        replies.removeFirst().resume(returning: data)
    }
}

@MainActor
final class RequestLaneTests: XCTestCase {
    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition never became true", file: file, line: line)
                throw BeamAPIError(what: "test wait failed")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func command(_ lane: RequestLane, path: String, key: String? = nil,
                         deadline: TimeInterval = 2, epoch: UInt64? = nil,
                         read: Bool = false) -> Task<Result<Data, Error>, Never> {
        var request = URLRequest(url: URL(string: "http://isolated.invalid/\(path)")!)
        request.httpMethod = read ? "GET" : "PUT"
        let selectedEpoch = epoch ?? lane.sessionEpoch
        let requestCopy = request
        return Task {
            do { return .success(try await lane.send(requestCopy, deadline: deadline,
                epoch: selectedEpoch, coalesceKey: key, writeKind: read ? nil : "volume")) }
            catch { return .failure(error) }
        }
    }

    private func error(_ result: Result<Data, Error>) -> Error? {
        if case .failure(let error) = result { return error }
        XCTFail("request unexpectedly succeeded")
        return nil
    }

    func testAllProductionAPIsForPortShareOneLane() {
        XCTAssertTrue(RequestLane.shared(port: 42421) === RequestLane.shared(port: 42421))
        XCTAssertFalse(RequestLane.shared(port: 42421) === RequestLane.shared(port: 42422))
    }

    func testBurstKeepsOneLatestIntentAndReportsSupersession() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport, capacity: 4)
        let first = command(lane, path: "first", key: "volume:a")
        try await eventually { await transport.observation.requests.count == 1 }
        var replaced: [Task<Result<Data, Error>, Never>] = []
        for value in 0..<100 {
            replaced.append(command(lane, path: "v\(value)", key: "volume:a"))
            try await eventually { lane.snapshot.queued == 1 }
            // Each launched task has replaced its predecessor before the next.
            if value > 0 { _ = await replaced[value - 1].value }
        }
        XCTAssertEqual(lane.snapshot.queued, 1)
        XCTAssertEqual(lane.snapshot.highWaterMark, 1)
        for task in replaced.dropLast() {
            let result = await task.value
            XCTAssertEqual(error(result) as? BeamRequestError, .superseded)
        }
        await transport.reply()
        _ = try await first.value.get()
        try await eventually { await transport.observation.requests.count == 2 }
        await transport.reply()
        _ = try await replaced.last!.value.get()
        await lane.waitForDrain()
        let observed = await transport.observation
        XCTAssertEqual(observed.requests.map { $0.url!.lastPathComponent }, ["first", "v99"])
        XCTAssertEqual(observed.maxActive, 1)
        XCTAssertEqual(lane.totalWrites, 2)
    }

    func testLateReplyAfterDeadlineDrainsBeforeNextCommand() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let first = command(lane, path: "slow", deadline: 0.02)
        try await eventually { await transport.observation.requests.count == 1 }
        let result = await first.value
        XCTAssertEqual(error(result) as? BeamRequestError, .deadlineExceeded)
        let latest = command(lane, path: "latest")
        try await eventually { lane.snapshot.queued == 1 }
        let before = await transport.observation
        XCTAssertEqual(before.requests.count, 1)
        XCTAssertEqual(before.active, 1)
        await transport.reply(Data("late".utf8))
        try await eventually { await transport.observation.requests.count == 2 }
        await transport.reply(Data("current".utf8))
        let data = try await latest.value.get()
        XCTAssertEqual(data, Data("current".utf8))
        await lane.waitForDrain()
        let observed = await transport.observation
        XCTAssertEqual(observed.maxActive, 1)
        XCTAssertEqual(observed.cancellations, 0)
    }

    func testCancellationDropsQueuedCommandButNeverCancelsSentSocket() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let sent = command(lane, path: "sent")
        try await eventually { await transport.observation.requests.count == 1 }
        let queued = command(lane, path: "queued")
        try await eventually { lane.snapshot.queued == 1 }
        queued.cancel()
        let queuedResult = await queued.value
        XCTAssertTrue(error(queuedResult) is CancellationError)
        XCTAssertEqual(lane.snapshot.queued, 0)
        sent.cancel()
        let sentResult = await sent.value
        XCTAssertTrue(error(sentResult) is CancellationError)
        XCTAssertTrue(lane.snapshot.inFlight)
        await transport.reply()
        await lane.waitForDrain()
        let observed = await transport.observation
        XCTAssertEqual(observed.requests.count, 1)
        XCTAssertEqual(observed.cancellations, 0)
    }

    func testCancelledBeforeEnqueueDoesNotSend() async {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let task = command(lane, path: "cancelled")
        task.cancel()
        let result = await task.value
        XCTAssertTrue(error(result) is CancellationError)
        let observed = await transport.observation
        XCTAssertTrue(observed.requests.isEmpty)
    }

    func testQueueBoundRejectsExcessAndExpiredQueueNeverSends() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport, capacity: 2)
        let sent = command(lane, path: "sent")
        try await eventually { await transport.observation.requests.count == 1 }
        let a = command(lane, path: "a", deadline: 0.03)
        let b = command(lane, path: "b", deadline: 0.03)
        try await eventually { lane.snapshot.queued == 2 }
        let excess = command(lane, path: "excess")
        let excessResult = await excess.value
        XCTAssertEqual(error(excessResult) as? BeamRequestError, .queueFull)
        let aResult = await a.value
        let bResult = await b.value
        XCTAssertEqual(error(aResult) as? BeamRequestError, .deadlineExceeded)
        XCTAssertEqual(error(bResult) as? BeamRequestError, .deadlineExceeded)
        XCTAssertEqual(lane.snapshot.queued, 0)
        XCTAssertEqual(lane.snapshot.highWaterMark, 2)
        await transport.reply()
        _ = try await sent.value.get()
        await lane.waitForDrain()
        let observed = await transport.observation
        XCTAssertEqual(observed.requests.count, 1)
    }

    func testSessionFenceRejectsQueuedAndLateOldEpochWithoutCancellingDrain() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let oldEpoch = lane.sessionEpoch
        let active = command(lane, path: "old-active")
        try await eventually { await transport.observation.requests.count == 1 }
        let obsolete = command(lane, path: "obsolete")
        try await eventually { lane.snapshot.queued == 1 }
        lane.suspendSession()
        let activeResult = await active.value
        let obsoleteResult = await obsolete.value
        XCTAssertEqual(error(activeResult) as? BeamRequestError, .sessionInvalidated)
        XCTAssertEqual(error(obsoleteResult) as? BeamRequestError, .sessionInvalidated)
        let stopped = await command(lane, path: "stopped").value
        XCTAssertEqual(error(stopped) as? BeamRequestError, .sessionInvalidated)
        lane.resumeSession()
        let lateOld = await command(lane, path: "late-old", epoch: oldEpoch).value
        XCTAssertEqual(error(lateOld) as? BeamRequestError, .sessionInvalidated)
        let current = command(lane, path: "current")
        try await eventually { lane.snapshot.queued == 1 }
        await transport.reply()
        try await eventually { await transport.observation.requests.count == 2 }
        await transport.reply()
        _ = try await current.value.get()
        await lane.waitForDrain()
        let observed = await transport.observation
        XCTAssertEqual(observed.requests.map { $0.url!.lastPathComponent }, ["old-active", "current"])
        XCTAssertEqual(observed.cancellations, 0)
    }

    func testCurrentControlsArePrioritizedWithoutStarvingHealth() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let blocker = command(lane, path: "blocker", read: true)
        try await eventually { await transport.observation.requests.count == 1 }
        let health = command(lane, path: "health", read: true)
        try await eventually { lane.snapshot.queued == 1 }
        var controls: [Task<Result<Data, Error>, Never>] = []
        for n in 1...5 {
            controls.append(command(lane, path: "c\(n)"))
            try await eventually { lane.snapshot.queued == n + 1 }
        }
        for count in 1...7 {
            try await eventually { await transport.observation.requests.count == count }
            await transport.reply()
        }
        _ = try await blocker.value.get()
        _ = try await health.value.get()
        for control in controls { _ = try await control.value.get() }
        let observed = await transport.observation
        XCTAssertEqual(observed.requests.map { $0.url!.lastPathComponent },
                       ["blocker", "c1", "c2", "c3", "health", "c4", "c5"])
    }

    func testAPIReceiptsDistinguishAppliedSupersededAndUnknown() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let api = BeamAPI(lane: lane)
        let blocking = command(lane, path: "blocker", read: true)
        try await eventually { await transport.observation.requests.count == 1 }
        let obsolete = Task { await api.setVolumeConfirmed(outputID: "a", volume: 10) }
        try await eventually { lane.snapshot.queued == 1 }
        let latest = Task { await api.setVolumeConfirmed(outputID: "a", volume: 20) }
        let obsoleteResult = await obsolete.value
        XCTAssertEqual(obsoleteResult, .superseded)
        await transport.reply()
        _ = try await blocking.value.get()
        try await eventually { await transport.observation.requests.count == 2 }
        await transport.reply()
        let latestResult = await latest.value
        XCTAssertEqual(latestResult, .applied)
        let unknown = Task { await api.setVolumeConfirmed(outputID: "a", volume: 30) }
        try await eventually { await transport.observation.requests.count == 3 }
        unknown.cancel()
        let unknownResult = await unknown.value
        XCTAssertEqual(unknownResult, .unknown)
        await transport.reply()
        await lane.waitForDrain()
    }

    func testMultiStepPlayCannotContinueAgainstRestartedSession() async throws {
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let api = BeamAPI(lane: lane)
        let play = Task { try await api.playPipe(uri: "pipe") }
        try await eventually { await transport.observation.requests.count == 1 }
        api.invalidateSession()
        await transport.reply()
        do { try await play.value; XCTFail("old play transaction succeeded") }
        catch { XCTAssertEqual(error as? BeamRequestError, .sessionInvalidated) }
        await lane.waitForDrain()
        let observed = await transport.observation
        XCTAssertEqual(observed.requests.count, 1)
    }
}
