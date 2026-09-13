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
