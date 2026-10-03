import Foundation
import XCTest
@testable import BeamEngine

@MainActor
final class RoomSessionControllerTests: XCTestCase {
    @MainActor
    private final class Gate {
        var isWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    private final class Fixture {
        var calls: [String] = []
        var events: [RoomSessionController.Event] = []
        var time: TimeInterval = 0
        var current = true
        var captureRunning = false
        var selections = 0
        var captures = 0
        var reads = 0
        var playbackReads = 0
        var uriReads = 0
        var stops = 0
        var allowsCaptureReset = true
        var prepareGate: Gate?
        var selectionGate: Gate?
        var captureGate: Gate?
        var outputGate: Gate?
        var cleanupGate: Gate?
        var captureError: (any Error)?
        var playing: (Int) -> Bool = { _ in true }
        var trackURI: (Int) -> String? = { _ in "pipe:beam.pipe" }
        var manualPlayError: (any Error)?
        var outputsForSelection: (Int) -> [Output] = { _ in [ready("front"), ready("back")] }
        var outputDelay: TimeInterval = 0
        var plan = RoomSessionController.Plan(speakers: [
            .init(id: "front", name: "Front"), .init(id: "back", name: "Back")
        ])

        func makeController() -> RoomSessionController {
            RoomSessionController(now: { self.time }, sleep: { interval in
                try Task.checkCancellation()
                self.time += interval
                await Task.yield()
            })
        }

        var dependencies: RoomSessionController.Dependencies {
            .init(
                prepare: { _ in
                    self.calls.append("prepare")
                    if let gate = self.prepareGate { await gate.wait() }
                    return .init(speakers: self.plan.speakers, allowsCaptureReset: self.allowsCaptureReset)
                },
                isCurrent: { self.current },
                settle: { context in
                    try context.check()
                    self.calls.append("settle")
                },
                setOutputs: { ids in
                    if !ids.isEmpty { self.selections += 1 }
                    self.calls.append("select:\(ids.joined(separator: ","))")
                    if !ids.isEmpty, let gate = self.selectionGate { await gate.wait() }
                },
                setSelected: { id, selected in self.calls.append("member:\(id):\(selected)") },
                outputs: {
                    self.reads += 1
                    self.calls.append("outputs")
                    if let gate = self.outputGate { await gate.wait() }
                    self.time += self.outputDelay
                    return self.outputsForSelection(self.selections)
                },
                silenceOutputs: { ids in self.calls.append("silent:\(ids.joined(separator: ","))") },
                startCapture: { _ in
                    self.captures += 1
                    self.calls.append("capture:start")
                    if let gate = self.captureGate { await gate.wait() }
                    if let error = self.captureError { throw error }
                    // Simulate an OS operation that ignores cancellation and
                    // completes after Stop, producing a resource to clean up.
                    self.captureRunning = true
                    self.calls.append("capture:ready")
                },
                stopCapture: {
                    self.calls.append("capture:stop")
                    self.captureRunning = false
                },
                stopPlayback: {
                    self.stops += 1
                    self.calls.append("playback:stop")
                    if self.stops > 1, let gate = self.cleanupGate { await gate.wait() }
                },
                setResumePlayback: { enabled in self.calls.append("resume:\(enabled)") },
                isPlaying: {
                    self.playbackReads += 1
                    self.calls.append("playing")
                    return self.playing(self.playbackReads)
                },
                rescan: { self.calls.append("rescan") },
                pipeTrackURI: {
                    self.uriReads += 1
                    self.calls.append("uri")
                    return self.trackURI(self.uriReads)
                },
                playPipe: { uri in
                    self.calls.append("play:\(uri)")
                    if let error = self.manualPlayError { throw error }
                },
                didTearDown: { self.calls.append("teardown") },
                event: { self.events.append($0) }
            )
        }

        static func ready(_ id: String) -> Output {
            Output(id: id, name: id, type: "AirPlay 2", selected: true,
                   connected: true, streaming: false, volume: 25)
        }
        static func warming(_ id: String) -> Output {
            Output(id: id, name: id, type: "AirPlay 2", selected: true,
                   connected: false, streaming: false, volume: 25)
        }
        static func failed(_ id: String) -> Output {
            Output(id: id, name: id, type: "AirPlay 2", selected: false,
                   connected: false, streaming: false, volume: 25)
        }
        static func unknown(_ id: String) -> Output {
            Output(id: id, name: id, type: "AirPlay 2", selected: false,
                   connected: nil, streaming: nil, volume: 25)
        }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition never became true", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    private func failure(_ controller: RoomSessionController, fixture: Fixture) async -> RoomSessionController.Failure? {
        do {
            _ = try await controller.start(using: fixture.dependencies)
            XCTFail("Expected startup failure")
            return nil
        } catch { return error as? RoomSessionController.Failure }
    }

    func testProductionStartupStopsBeforeSelectingAndStartsSilent() async throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        let result = try await controller.start(using: fixture.dependencies)
        XCTAssertEqual(Array(fixture.calls.prefix(9)), [
            "prepare", "settle", "playback:stop", "select:front,back", "silent:front,back",
            "capture:start", "capture:ready", "resume:true", "playing"
        ])
        XCTAssertEqual(result?.readyIDs, ["front", "back"])
        XCTAssertEqual(result?.missing, [])
        XCTAssertEqual(controller.state, .streaming)
        XCTAssertTrue(fixture.captureRunning)
        XCTAssertTrue(fixture.events.isEmpty)
        await controller.invalidateAndStop().value
    }

    func testRestartReleasesWarmOutputsInsteadOfSpendingTheEntireSettleTimeout() async throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        var warmSession = false
        var dependencies = fixture.dependencies
        let stopPlayback = dependencies.stopPlayback
        dependencies.stopPlayback = {
            try await stopPlayback()
            // OwnTone's /player/stop flushes, then retains the connection for
            // ten seconds. The facade's bounded settle waits another six
            // seconds whenever that old connection is still reported.
            warmSession = true
        }
        let setOutputs = dependencies.setOutputs
        dependencies.setOutputs = { ids in
            try await setOutputs(ids)
            if ids.isEmpty { warmSession = false }
        }
        dependencies.settle = { context in
            try context.check()
            fixture.calls.append("settle")
            guard fixture.captures > 0 else { return }
            fixture.time += 2.5 // Existing receiver teardown safety floor.
            if warmSession { fixture.time += 6 }
        }
        _ = try await controller.start(using: dependencies)
        await controller.invalidateAndStop().value
        let began = fixture.time
        let result = try await controller.start(using: dependencies)
        XCTAssertEqual(result?.missing, [])
        XCTAssertEqual(fixture.time - began, 2.5,
                       "Restart must retain the safety floor without the avoidable six-second timeout")
        await controller.invalidateAndStop().value
    }

    func testReplacementWaitsForWarmOutputReleaseToFinish() async throws {
        let fixture = Fixture()
        let controller = fixture.makeController()
        let release = Gate()
        var dependencies = fixture.dependencies
        let setOutputs = dependencies.setOutputs
        dependencies.setOutputs = { ids in
            try await setOutputs(ids)
            if ids.isEmpty { await release.wait() }
        }
        _ = try await controller.start(using: dependencies)
        let cleanup = controller.invalidateAndStop()
        try await eventually { release.isWaiting || controller.state == .idle }
        XCTAssertTrue(release.isWaiting, "Stop must explicitly release the engine's warm connections")
        let next = Fixture()
        let restart = Task { try await controller.start(using: next.dependencies) }
        await Task.yield()
        XCTAssertTrue(next.calls.isEmpty, "Replacement cannot select while teardown is still pending")
        release.release()
        await cleanup.value
        let result = try await restart.value
        XCTAssertEqual(result?.missing, [])
        await controller.invalidateAndStop().value
    }

    func testSecondStartSharesFirstStartupAndResult() async throws {
        let fixture = Fixture()
        let gate = Gate()
        fixture.prepareGate = gate
        let controller = fixture.makeController()
        let first = Task { try await controller.start(using: fixture.dependencies) }
        try await eventually { gate.isWaiting }
        let second = Task { try await controller.start(using: fixture.dependencies) }
        await Task.yield()
        XCTAssertEqual(fixture.calls, ["prepare"])
        gate.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(fixture.calls.filter { $0 == "prepare" }.count, 1)
        XCTAssertEqual(fixture.captures, 1)
        let third = try await controller.start(using: fixture.dependencies)
        XCTAssertEqual(third, firstResult)
        XCTAssertEqual(fixture.captures, 1)
        await controller.invalidateAndStop().value
    }

    func testObsoleteScheduledStartCannotClaimReplacementStartup() async throws {
        let obsolete = Fixture()
        obsolete.current = false
        let current = Fixture()
        let gate = Gate()
        current.prepareGate = gate
        defer { gate.release() }
        let controller = current.makeController()
        var oldCompleted = false
        let oldStart = Task {
            let result = try await controller.start(using: obsolete.dependencies)
            oldCompleted = true
            return result
        }
        let newStart = Task { try await controller.start(using: current.dependencies) }
        try await eventually { oldCompleted }
        let oldResult = try await oldStart.value
        XCTAssertNil(oldResult)
        XCTAssertTrue(obsolete.calls.isEmpty)
        try await eventually { gate.isWaiting }
        gate.release()
        let newResult = try await newStart.value
        XCTAssertEqual(newResult?.readyIDs, ["front", "back"])
        XCTAssertEqual(current.captures, 1)
        XCTAssertEqual(controller.state, .streaming)
        await controller.invalidateAndStop().value
    }

    func testObsoleteCallerCannotJoinAnAlreadyPendingCurrentStart() async throws {
        let current = Fixture()
        let gate = Gate()
        current.prepareGate = gate
        let controller = current.makeController()
        let start = Task { try await controller.start(using: current.dependencies) }
        try await eventually { gate.isWaiting }
        defer { gate.release() }
        let obsolete = Fixture()
        obsolete.current = false
        var obsoleteCompleted = false
        let obsoleteTask = Task {
            let result = try await controller.start(using: obsolete.dependencies)
            obsoleteCompleted = true
            return result
        }
        try await eventually { obsoleteCompleted }
        let result = try await obsoleteTask.value
        XCTAssertNil(result, "Obsolete caller must return without sharing the pending task")
        XCTAssertTrue(obsolete.calls.isEmpty)
        XCTAssertEqual(controller.state, .starting)
        gate.release()
        let currentResult = try await start.value
        XCTAssertEqual(currentResult?.readyIDs, ["front", "back"])
        // The facade's admission predicate describes starting. Once the room
        // is already running, repeated start remains an idempotent result read.
        current.current = false
        let cached = try await controller.start(using: current.dependencies)
        XCTAssertEqual(cached, currentResult)
        await controller.invalidateAndStop().value
    }

    func testStopDuringSelectionRejectsLateReplyAndBlocksReplacement() async throws {
        let old = Fixture()
        let selection = Gate()
        old.selectionGate = selection
        let controller = old.makeController()
        let first = Task { try await controller.start(using: old.dependencies) }
        try await eventually { selection.isWaiting }
        let stop = controller.invalidateAndStop()
        let next = Fixture()
        let second = Task { try await controller.start(using: next.dependencies) }
        await Task.yield()
        XCTAssertTrue(next.calls.isEmpty, "Replacement must wait for the sent selection request")
        selection.release()
        let oldResult = try await first.value
        await stop.value
        let newResult = try await second.value
        XCTAssertNil(oldResult)
        XCTAssertEqual(old.captures, 0)
        XCTAssertFalse(old.calls.contains("resume:true"))
        XCTAssertEqual(Array(old.calls.suffix(4)), ["capture:stop", "playback:stop", "select:", "resume:false"])
        XCTAssertEqual(newResult?.readyIDs, ["front", "back"])
        await controller.invalidateAndStop().value
    }

    func testStopDuringTapCreationClosesLateCaptureAndWaitsForActualCleanup() async throws {
        let old = Fixture()
        let capture = Gate(), cleanup = Gate()
        old.captureGate = capture
        old.cleanupGate = cleanup
        let controller = old.makeController()
        let first = Task { try await controller.start(using: old.dependencies) }
        try await eventually { capture.isWaiting }
        let stop = controller.invalidateAndStop()
        XCTAssertFalse(old.captureRunning)
        let next = Fixture()
        let second = Task { try await controller.start(using: next.dependencies) }
        capture.release()
        try await eventually { cleanup.isWaiting }
        XCTAssertFalse(old.captureRunning, "Late OS creation must be stopped after startup drains")
        XCTAssertTrue(next.calls.isEmpty, "A completed startup reply is not completed teardown")
        XCTAssertFalse(old.calls.contains("resume:true"))
        cleanup.release()
        await stop.value
        let oldResult = try await first.value
        let newResult = try await second.value
        XCTAssertNil(oldResult)
        XCTAssertEqual(newResult?.missing, [])
        XCTAssertTrue(old.calls.contains("capture:ready"), "Fixture must exercise actual late creation")
        XCTAssertEqual(old.calls.filter { $0 == "capture:stop" }.count, 2)
        await controller.invalidateAndStop().value
    }

    func testStopDuringReadinessNeverAcceptsLateReadyOutput() async throws {
        let fixture = Fixture()
        let gate = Gate()
        fixture.outputGate = gate
        let controller = fixture.makeController()
        let start = Task { try await controller.start(using: fixture.dependencies) }
        try await eventually { gate.isWaiting }
        let stop = controller.invalidateAndStop()
        gate.release()
        let result = try await start.value
        await stop.value
        XCTAssertNil(result)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(fixture.captureRunning)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertEqual(fixture.selections, 1)
    }

    func testExternalGenerationInvalidationAlsoCleansUpWithoutStreaming() async throws {
        let fixture = Fixture()
        let gate = Gate()
        fixture.outputGate = gate
        let controller = fixture.makeController()
        let start = Task { try await controller.start(using: fixture.dependencies) }
        try await eventually { gate.isWaiting }
        fixture.current = false
        gate.release()
        let result = try await start.value
        XCTAssertNil(result)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(fixture.captureRunning)
        XCTAssertEqual(fixture.calls.last, "resume:false")
    }

    func testExplicitTotalFailureGetsOneFreshCaptureSession() async throws {
        let fixture = Fixture()
        fixture.outputsForSelection = { selection in
            selection == 1 ? [Fixture.failed("front"), Fixture.failed("back")]
                : [Fixture.ready("front"), Fixture.ready("back")]
        }
        let controller = fixture.makeController()
        let result = try await controller.start(using: fixture.dependencies)
        XCTAssertEqual(result?.missing, [])
        XCTAssertEqual(fixture.events, [.reset(["front", "back"])])
        XCTAssertEqual(fixture.captures, 2)
        XCTAssertEqual(fixture.stops, 2)
        let reset = try XCTUnwrap(fixture.calls.firstIndex(of: "teardown"))
        XCTAssertEqual(Array(fixture.calls[reset...].prefix(5)), [
            "teardown", "settle", "select:front,back", "capture:start", "capture:ready"
        ])
        await controller.invalidateAndStop().value
    }

    func testHealthyPartnerIsPreservedWithFullRoomReassert() async throws {
        let fixture = Fixture()
        fixture.outputsForSelection = { selection in
            selection == 1 ? [Fixture.ready("front"), Fixture.failed("back")]
                : [Fixture.ready("front"), Fixture.ready("back")]
        }
        let controller = fixture.makeController()
        let result = try await controller.start(using: fixture.dependencies)
        XCTAssertEqual(result?.missing, [])
        XCTAssertEqual(fixture.events, [.reassert(attempt: 1, missing: ["back"])])
        XCTAssertEqual(fixture.captures, 1)
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertFalse(fixture.calls.contains { $0.hasPrefix("member:") })
        XCTAssertEqual(fixture.selections, 2)
        await controller.invalidateAndStop().value
    }

    func testWarmingMissingAndUnknownMembersDoNotTriggerTotalFailureReset() async throws {
        let observations: [[Output]] = [
            [Fixture.warming("front"), Fixture.failed("back")],
            [Fixture.failed("front")],
            [Fixture.unknown("front"), Fixture.failed("back")]
        ]
        for initial in observations {
            let fixture = Fixture()
            fixture.outputsForSelection = { selection in
                selection == 1 ? initial : [Fixture.ready("front"), Fixture.ready("back")]
            }
            let controller = fixture.makeController()
            let result = try await controller.start(using: fixture.dependencies)
            XCTAssertEqual(result?.missing, [])
            XCTAssertEqual(fixture.captures, 1)
            XCTAssertFalse(fixture.events.contains { if case .reset = $0 { true } else { false } })
            XCTAssertGreaterThanOrEqual(fixture.time, 6, "Unknown or warming state needs the full initial wait")
            await controller.invalidateAndStop().value
        }
    }

    func testEveryReassertRevalidatesThePreviouslyReadyPartner() async throws {
        let fixture = Fixture()
        fixture.outputsForSelection = { selection in
            switch selection {
            case 1: [Fixture.ready("front"), Fixture.warming("back")]
            case 2: [Fixture.warming("front"), Fixture.ready("back")]
            default: [Fixture.ready("front"), Fixture.ready("back")]
            }
        }
        let controller = fixture.makeController()
        let result = try await controller.start(using: fixture.dependencies)
        XCTAssertEqual(result?.missing, [])
        XCTAssertEqual(fixture.events, [
            .reassert(attempt: 1, missing: ["back"]), .reassert(attempt: 2, missing: ["front"])
        ])
        XCTAssertEqual(fixture.selections, 3)
        await controller.invalidateAndStop().value
    }

    func testHardRejoinTargetsMissingMemberThenChecksEntireRoomAgain() async throws {
        let fixture = Fixture()
        fixture.outputsForSelection = { selection in
            selection < 4 ? [Fixture.ready("front"), Fixture.warming("back")]
                : [Fixture.warming("front"), Fixture.ready("back")]
        }
        let controller = fixture.makeController()
        let result = try await controller.start(using: fixture.dependencies)
        XCTAssertEqual(result?.missing, ["front"])
        XCTAssertEqual(result?.readyIDs, ["back"])
        XCTAssertEqual(fixture.events, [
            .reassert(attempt: 1, missing: ["back"]), .reassert(attempt: 2, missing: ["back"]),
            .hardRejoin(["back"])
        ])
        XCTAssertEqual(fixture.calls.filter { $0.hasPrefix("member:") }, ["member:back:false"])
        XCTAssertEqual(fixture.selections, 4)
        XCTAssertTrue(fixture.captureRunning, "A partial room keeps its working speaker")
        await controller.invalidateAndStop().value
    }

    func testFailedResetCannotLoopAndSpotifyNeverResetsItsWriter() async {
        for allowReset in [true, false] {
            let fixture = Fixture()
            fixture.allowsCaptureReset = allowReset
            fixture.outputsForSelection = { _ in [Fixture.failed("front"), Fixture.failed("back")] }
            let controller = fixture.makeController()
            let error = await failure(controller, fixture: fixture)
            XCTAssertEqual(error, .noSpeakersReady(["front", "back"]))
            XCTAssertEqual(controller.state, .failed)
            XCTAssertEqual(fixture.captures, allowReset ? 2 : 1)
            XCTAssertEqual(fixture.selections, allowReset ? 5 : 4)
            XCTAssertEqual(fixture.events.filter { if case .reset = $0 { true } else { false } }.count,
                           allowReset ? 1 : 0)
            XCTAssertEqual(fixture.calls.filter { $0.hasPrefix("member:") }, ["member:front:false", "member:back:false"])
            XCTAssertFalse(fixture.captureRunning)
            XCTAssertEqual(fixture.calls.last, "resume:false")
        }
    }

    func testBoundedManualPlaybackFallbackToleratesAutostartRace() async throws {
        let fixture = Fixture()
        fixture.playing = { $0 > 8 }
        fixture.trackURI = { $0 > 2 ? "pipe:beam.pipe" : nil }
        fixture.manualPlayError = RoomSessionController.Failure.notPlaying
        let controller = fixture.makeController()
        let result = try await controller.start(using: fixture.dependencies)
        XCTAssertEqual(result?.missing, [])
        XCTAssertEqual(fixture.playbackReads, 10)
        XCTAssertEqual(fixture.uriReads, 3)
        XCTAssertTrue(fixture.calls.contains("play:pipe:beam.pipe"))
        let rescan = try XCTUnwrap(fixture.calls.firstIndex(of: "rescan"))
        XCTAssertEqual(fixture.calls[rescan - 1], "playing")
        await controller.invalidateAndStop().value
    }

    func testNoPlaybackHasBoundedAttemptsAndCleansCaptureBeforeFailure() async {
        let fixture = Fixture()
        fixture.playing = { _ in false }
        fixture.trackURI = { _ in nil }
        let controller = fixture.makeController()
        let error = await failure(controller, fixture: fixture)
        XCTAssertEqual(error, .notPlaying)
        XCTAssertEqual(fixture.playbackReads, 14)
        XCTAssertEqual(fixture.uriReads, 6)
        XCTAssertEqual(fixture.reads, 0, "Readiness is meaningful only after playback starts")
        XCTAssertFalse(fixture.captureRunning)
        XCTAssertEqual(fixture.calls.last, "resume:false")
        XCTAssertEqual(controller.state, .failed)
    }

    func testSlowLateReadyRepliesConsumeEachReadinessBudget() async {
        let fixture = Fixture()
        fixture.outputDelay = 20
        let controller = fixture.makeController()
        let error = await failure(controller, fixture: fixture)
        XCTAssertEqual(error, .noSpeakersReady(["front", "back"]))
        XCTAssertEqual(fixture.reads, 5, "Four bounded readiness waits and one reset-proof query")
        XCTAssertEqual(fixture.selections, 4)
        XCTAssertEqual(fixture.captures, 1, "A late ready reply is not explicit proof of failure")
        XCTAssertFalse(fixture.captureRunning)
    }

    func testRoomResetRechecksPlaybackEvenWhenReceiversStayConnected() async {
        let fixture = Fixture()
        fixture.outputsForSelection = { selection in
            selection == 1 ? [Fixture.failed("front"), Fixture.failed("back")]
                : [Fixture.ready("front"), Fixture.ready("back")]
        }
        fixture.playing = { $0 == 1 }
        let controller = fixture.makeController()
        let error = await failure(controller, fixture: fixture)
        XCTAssertEqual(error, .notPlaying)
        XCTAssertEqual(fixture.captures, 2)
        XCTAssertEqual(fixture.playbackReads, 15)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertFalse(fixture.captureRunning)
        XCTAssertEqual(fixture.calls.last, "resume:false")
    }

    func testFinalReadinessDoesNotAcceptConnectedRoomWithStoppedPlayer() async {
        let fixture = Fixture()
        fixture.playing = { $0 == 1 }
        let controller = fixture.makeController()
        let error = await failure(controller, fixture: fixture)
        XCTAssertEqual(error, .notPlaying)
        XCTAssertEqual(fixture.playbackReads, 15)
        XCTAssertGreaterThan(fixture.reads, 0)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertFalse(fixture.captureRunning)
    }

    func testReplacementWaitsForErrorCleanupAndStopCleanup() async throws {
        let old = Fixture()
        let cleanup = Gate()
        old.cleanupGate = cleanup
        old.captureError = RoomSessionController.Failure.notPlaying
        let controller = old.makeController()
        let first = Task { try await controller.start(using: old.dependencies) }
        try await eventually { cleanup.isWaiting }
        let stop = controller.invalidateAndStop()
        let next = Fixture()
        let second = Task { try await controller.start(using: next.dependencies) }
        await Task.yield()
        XCTAssertTrue(next.calls.isEmpty)
        old.cleanupGate = nil
        cleanup.release()
        await stop.value
        let oldResult = try await first.value
        let newResult = try await second.value
        XCTAssertNil(oldResult)
        XCTAssertEqual(newResult?.missing, [])
        XCTAssertFalse(old.captureRunning)
        XCTAssertEqual(old.calls.last, "resume:false")
        XCTAssertEqual(old.stops, 3)
        await controller.invalidateAndStop().value
    }
}
