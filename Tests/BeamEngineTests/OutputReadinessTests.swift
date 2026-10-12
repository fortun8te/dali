import XCTest
@testable import BeamEngine

final class OutputReadinessTests: XCTestCase, @unchecked Sendable {
    private actor Query {
        var calls = 0
        let delay: Duration
        let outputs: [Output]
        init(delay: Duration, outputs: [Output] = []) {
            self.delay = delay
            self.outputs = outputs
        }
        func read() async throws -> [Output] {
            calls += 1
            try await Task.sleep(for: delay)
            return outputs
        }
        func readIgnoringCancellation() async -> [Output] {
            calls += 1
            try? await Task.sleep(for: delay)
            return outputs
        }
    }

    private func output(selected: Bool = true, connected: Bool? = true,
                        streaming: Bool? = false) -> Output {
        Output(id: "front", name: "Front", type: "AirPlay 2", selected: selected,
               connected: connected, streaming: streaming, volume: 25)
    }

    func testFailFastReturnsOnceEveryOutputIsExplicitlyDeselected() async {
        let failed = output(selected: false, connected: false, streaming: false)
        let began = ContinuousClock.now
        let missing = await OutputReadiness.missing(ids: ["front"], timeout: .seconds(6),
                                                    failFastAfter: .milliseconds(100)) { [failed] }
        XCTAssertEqual(missing, ["front"])
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
    }

    func testFailFastDoesNotTriggerForWarmingOrSelectedOutputs() async {
        let warming = output(selected: true, connected: false, streaming: false)
        let began = ContinuousClock.now
        let missing = await OutputReadiness.missing(ids: ["front"], timeout: .milliseconds(600),
                                                    failFastAfter: .milliseconds(50)) { [warming] }
        XCTAssertEqual(missing, ["front"])
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(500))
    }

    func testConnectedAP2IsReadyButStaleSelectionIsNot() async {
        let ready = output()
        let missing = await OutputReadiness.missing(ids: ["front"], timeout: .seconds(1)) {
            [ready]
        }
        XCTAssertTrue(missing.isEmpty)
        XCTAssertFalse(output(connected: false).isSessionReady)
        XCTAssertFalse(output(selected: false).isSessionReady)
        XCTAssertTrue(output(connected: nil, streaming: nil).isSessionReady)
    }

    func testRoomReadinessDetectsPartnerLostDuringRejoin() async {
        let front = output()
        let back = Output(id: "back", name: "Back", type: "AirPlay 2", selected: true,
                          connected: true, streaming: true, volume: 25)
        let disconnectedFront = output(connected: false, streaming: false)
        let disconnectedBack = Output(id: "back", name: "Back", type: "AirPlay 2", selected: true,
                                      connected: false, streaming: false, volume: 25)
        let room: Set<String> = ["front", "back"]
        let initial = await OutputReadiness.missing(ids: room, timeout: .milliseconds(30)) {
            [front, disconnectedBack]
        }
        XCTAssertEqual(initial, ["back"])
        // After reselecting the group, the back has joined but its AP2 partner
        // has disconnected. A room check must expose the new missing member.
        let afterRejoin = await OutputReadiness.missing(ids: room, timeout: .milliseconds(30)) {
            [disconnectedFront, back]
        }
        XCTAssertEqual(afterRejoin, ["front"])
        let recovered = await OutputReadiness.missing(ids: room, timeout: .milliseconds(30)) {
            [front, back]
        }
        XCTAssertTrue(recovered.isEmpty)
    }

    func testFailedRoomResetIsBoundedAndPreservesHealthyOrWarmingPartner() {
        let room: Set<String> = ["front", "back"]
        let failedFront = output(selected: false, connected: false, streaming: false)
        let failedBack = Output(id: "back", name: "Back", type: "AirPlay 2", selected: false,
                                connected: false, streaming: false, volume: 25)
        var recovery = RoomStartupRecovery()
        XCTAssertFalse(recovery.claimReset(ids: room, missing: ["back"], outputs: [output(), failedBack]))
        XCTAssertFalse(recovery.claimReset(ids: room, missing: room,
                                          outputs: [output(connected: false), failedBack]),
                       "Selected but warming is not a confirmed failure")
        XCTAssertFalse(recovery.claimReset(ids: room, missing: room, outputs: [failedFront]),
                       "Missing discovery is not proof the entire room failed")
        XCTAssertFalse(recovery.claimReset(ids: room, missing: room,
                                          outputs: [output(selected: false, connected: nil, streaming: nil), failedBack]),
                       "Older engine fields cannot prove failure")
        XCTAssertTrue(recovery.claimReset(ids: room, missing: room, outputs: [failedFront, failedBack]))
        XCTAssertFalse(recovery.claimReset(ids: room, missing: room, outputs: [failedFront, failedBack]),
                       "A failed reset must not create an endless restart cycle")
    }

    func testSlowRequestsConsumeRecoveryDeadline() async {
        let query = Query(delay: .milliseconds(120))
        let clock = ContinuousClock()
        let start = clock.now
        let missing = await OutputReadiness.missing(
            ids: ["front"], timeout: .milliseconds(100), pollInterval: .milliseconds(1)
        ) { try await query.read() }
        let calls = await query.calls
        XCTAssertEqual(missing, ["front"])
        XCTAssertEqual(calls, 1, "Slow HTTP must consume the deadline, not earn another polling budget")
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
    }

    func testCancellationDoesNotAcceptLateReadyReply() async {
        let query = Query(delay: .seconds(2), outputs: [output()])
        let task = Task {
            await OutputReadiness.missing(ids: ["front"], timeout: .seconds(5)) {
                // Simulate a transport which still returns a response after its
                // caller cancels, as an in-flight local request can do.
                await query.readIgnoringCancellation()
            }
        }
        // Wait for the request to be in flight so this checks a late reply,
        // not merely a task which happened to be cancelled before starting.
        while await query.calls == 0 { await Task.yield() }
        task.cancel()
        let missing = await task.value
        XCTAssertEqual(missing, ["front"])
    }
}
