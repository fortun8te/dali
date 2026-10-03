import XCTest
@testable import BeamEngine

private actor VolumeTransportFixture {
    struct Request: Sendable { let id: String; let value: Int }
    var requests: [Request] = []
    var replies: [CheckedContinuation<RoomVolumeWriteResult, Never>] = []
    func write(_ id: String, _ value: Int) async -> RoomVolumeWriteResult {
        requests.append(Request(id: id, value: value))
        return await withCheckedContinuation { replies.append($0) }
    }
    func finish(_ result: RoomVolumeWriteResult = .applied) { replies.removeFirst().resume(returning: result) }
    var count: Int { requests.count }
    var last: Int? { requests.last?.value }
}

private actor RetryingVolumeFixture {
    var calls: [Int] = []
    func write(_ value: Int) -> RoomVolumeWriteResult {
        calls.append(value)
        return calls.count <= 3 ? .unknown : .applied
    }
    var count: Int { calls.count }
}

@MainActor
private final class VolumeClockFixture {
    var instant = ContinuousClock.now
    func advance(_ duration: Duration) { instant = instant.advanced(by: duration) }
}

@MainActor
final class RoomVolumeCoordinatorTests: XCTestCase {
    private func equal<T: Equatable>(_ actual: T, _ expected: T) { XCTAssertEqual(actual, expected) }
    private func isTrue(_ value: Bool) { XCTAssertTrue(value) }
    private func isFalse(_ value: Bool) { XCTAssertFalse(value) }
    private func waitFor(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Coordinator did not reach the expected state")
    }

    func testSliderBurstConvergesOnLatestIntentWithTwoRequests() async {
        let transport = VolumeTransportFixture()
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero) { await transport.write($0, $1) }
        coordinator.update(session: 1, active: true, targets: ["front": 40], eligible: ["front"])
        await waitFor { await transport.count == 1 }
        for value in 1...100 { coordinator.update(session: 1, active: true, targets: ["front": value], eligible: ["front"]) }
        await transport.finish()
        await waitFor { await transport.count == 2 }
        let last = await transport.last
        XCTAssertEqual(last, 100)
        await transport.finish()
        await waitFor { coordinator.applied["front"] == 100 }
        let count = await transport.count
        XCTAssertEqual(count, 2)
        coordinator.stop(session: 2)
    }

    func testLateCompletionCannotAlterReplacementSession() async {
        let transport = VolumeTransportFixture()
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero) { await transport.write($0, $1) }
        coordinator.update(session: 1, active: true, targets: ["front": 40], eligible: ["front"])
        await waitFor { await transport.count == 1 }
        coordinator.stop(session: 2)
        coordinator.update(session: 3, active: true, targets: ["front": 5], eligible: ["front"])
        await waitFor { await transport.count == 2 }
        await transport.finish()
        XCTAssertNil(coordinator.applied["front"])
        await transport.finish()
        await waitFor { coordinator.applied["front"] == 5 }
        coordinator.stop(session: 4)
    }

    func testTemporarySilenceRetainsLatestIntentUntilRestore() async {
        let transport = VolumeTransportFixture()
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero) { await transport.write($0, $1) }
        coordinator.update(session: 1, active: true, targets: ["front": 20], eligible: [])
        let silence = Task { await coordinator.silence("front", session: 1) }
        await waitFor { await transport.count == 1 }
        equal(await transport.last, 0)
        coordinator.update(session: 1, active: true, targets: ["front": 30], eligible: ["front"])
        await transport.finish()
        isTrue(await silence.value)
        equal(await transport.count, 1)
        let restore = Task { await coordinator.restore("front", session: 1) }
        await waitFor { await transport.count == 2 }
        equal(await transport.last, 30)
        await transport.finish()
        isTrue(await restore.value)
        coordinator.stop(session: 2)
    }

    func testStaleObservationCannotResurrectOldTarget() async {
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero) { _, _ in .applied }
        coordinator.update(session: 1, active: true, targets: ["front": 20], eligible: ["front"])
        await waitFor { coordinator.applied["front"] == 20 }
        let old = coordinator.observationToken
        coordinator.update(session: 1, active: true, targets: ["front": 5], eligible: ["front"])
        await waitFor { coordinator.applied["front"] == 5 }
        coordinator.observe(["front": 20], token: old)
        XCTAssertEqual(coordinator.applied["front"], 5)
        coordinator.stop(session: 2)
    }

    func testCanceledSetupWaiterFinishesWithoutAbandoningWireRequest() async {
        let transport = VolumeTransportFixture()
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero) { await transport.write($0, $1) }
        coordinator.update(session: 1, active: true, targets: ["front": 20], eligible: [])
        let waiter = Task { await coordinator.silence("front", session: 1) }
        await waitFor { await transport.count == 1 }
        waiter.cancel()
        isFalse(await waiter.value)
        await transport.finish()
        await waitFor { coordinator.applied["front"] == 0 }
        coordinator.stop(session: 2)
    }

    func testThreeUnknownWritesRetryUnchangedIntentUntilAcceptance() async {
        let transport = RetryingVolumeFixture()
        let clock = VolumeClockFixture()
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero, now: { clock.instant },
                                                sleep: { await clock.advance($0); await Task.yield() }) {
            _, value in await transport.write(value)
        }
        coordinator.update(session: 1, active: true, targets: ["front": 20], eligible: ["front"])
        await waitFor { coordinator.applied["front"] == 20 }
        equal(await transport.count, 4)
        coordinator.stop(session: 2)
    }

    func testMatchingRequestedVolumeCannotConfirmAnUnknownWrite() async {
        let transport = VolumeTransportFixture()
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero) { await transport.write($0, $1) }
        coordinator.update(session: 1, active: true, targets: ["front": 20], eligible: ["front"])
        await waitFor { await transport.count == 1 }
        await transport.finish(.unknown)
        await waitFor { !coordinator.isWriting }
        coordinator.observe(["front": 20], token: coordinator.observationToken)
        XCTAssertNil(coordinator.applied["front"], "Engine poll reports request intent, not the failed RTSP receipt")
        coordinator.update(session: 1, active: true, targets: ["front": 20], eligible: ["front"], force: ["front"])
        await waitFor { await transport.count == 2 }
        await transport.finish()
        await waitFor { coordinator.applied["front"] == 20 }
        coordinator.stop(session: 2)
    }

    func testUrgentMuteWakesRetryBackoffWithoutWaitingForCooldown() async {
        let transport = VolumeTransportFixture()
        let coordinator = RoomVolumeCoordinator(minimumSpacing: .zero) { await transport.write($0, $1) }
        coordinator.update(session: 1, active: true, targets: ["front": 20], eligible: ["front"])
        await waitFor { await transport.count == 1 }
        await transport.finish(.unknown)
        await waitFor { !coordinator.isWriting }
        // The driver is now waiting in the three-second retry cooldown.
        for _ in 0..<20 { await Task.yield() }
        coordinator.update(session: 1, active: true, targets: ["front": 0], eligible: [], urgent: true)
        await waitFor { await transport.count == 2 }
        equal(await transport.last, 0)
        await transport.finish()
        await waitFor { coordinator.applied["front"] == 0 }
        coordinator.stop(session: 2)
    }

}
