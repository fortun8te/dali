import Foundation
import Darwin
import XCTest
@testable import BeamEngine

private struct ChildFixture: Sendable {
    let root: URL
    let binary: URL
    let config: OwnToneConfig
    var marker: URL { URL(fileURLWithPath: config.confFile.path + ".pid") }
    var trace: URL { URL(fileURLWithPath: config.confFile.path + ".trace") }

    static func make(binaryName: String = "owntone", ignoreTerm: Bool = false) throws -> ChildFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dali-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.c")
        let binary = root.appendingPathComponent(binaryName)
        try """
        #include <stdio.h>
        #include <signal.h>
        #include <unistd.h>
        #include <string.h>
        static volatile sig_atomic_t exiting = 0;
        static void term(int signal) { exiting = 1; }
        int main(int argc, char **argv) {
            const char *path = NULL;
            for (int i = 1; i + 1 < argc; i++) {
                if (strcmp(argv[i], "-c") == 0 || strcmp(argv[i], "--device") == 0) path = argv[i + 1];
            }
            if (!path) return 2;
            char marker[4096], trace[4096];
            snprintf(marker, sizeof(marker), "%s.pid", path);
            snprintf(trace, sizeof(trace), "%s.trace", path);
            signal(SIGTERM, \(ignoreTerm ? "SIG_IGN" : "term"));
            FILE *f = fopen(marker, "w"); fprintf(f, "%d", getpid()); fclose(f);
            f = fopen(trace, "a"); fprintf(f, "start %d\\n", getpid()); fclose(f);
            while (!exiting) usleep(10000);
            // Model slow graceful release of a child's clock/audio sockets.
            usleep(150000);
            f = fopen(trace, "a"); fprintf(f, "stop %d\\n", getpid()); fclose(f);
            unlink(marker);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", binary.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw BeamAPIError(what: "fixture compile failed") }
        return ChildFixture(root: root, binary: binary,
            config: OwnToneConfig(rootDir: root.appendingPathComponent("engine"), port: 42431))
    }

    var pid: Int32? {
        guard let raw = try? String(contentsOf: marker, encoding: .utf8),
              let pid = Int32(raw),
              let identity = EngineSupervisor.processArguments(of: pid),
              identity.executable == binary.path else { return nil }
        return pid
    }
    var events: [String] {
        ((try? String(contentsOf: trace, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
    func runtime(portsFree: Bool = true) -> EngineSupervisor.Runtime {
        var runtime = EngineSupervisor.Runtime()
        runtime.tcpAccepts = { _ in self.pid != nil }
        runtime.ptpPortsAreFree = { portsFree && self.pid == nil }
        runtime.reap = { _, _ in [] }
        runtime.clearClock = {} // Tests must never unlink a live shared clock.
        runtime.ptpTimeout = 0.02
        runtime.terminateGrace = 0.5
        runtime.startupHold = 0
        return runtime
    }
    func cleanup() {
        if let pid { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class EngineLifecycleTests: XCTestCase {
    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition never became true")
                throw BeamAPIError(what: "test wait failed")
            }
            try await Task.sleep(for: .milliseconds(3))
        }
    }

    func testConcurrentStartsShareOneChildAndOneReadinessResult() async throws {
        let fixture = try ChildFixture.make()
        defer { fixture.cleanup() }
        let transport = ControlledBeamTransport()
        let api = BeamAPI(lane: RequestLane(transport: transport))
        let supervisor = EngineSupervisor(binary: fixture.binary, config: fixture.config,
                                           api: api, runtime: fixture.runtime())
        let first = Task { try await supervisor.start() }
        let second = Task { try await supervisor.start() }
        try await eventually { await transport.observation.requests.count == 1 }
        XCTAssertEqual(fixture.events.count, 1)
        await transport.reply()
        try await first.value
        try await second.value
        let state = await supervisor.state
        XCTAssertEqual(state, .running)
        await supervisor.stop()
        XCTAssertNil(fixture.pid)
        XCTAssertEqual(fixture.events.map { $0.split(separator: " ")[0] }, ["start", "stop"])
    }

    func testStopWinsDuringReadinessAndPreventsResurrection() async throws {
        let fixture = try ChildFixture.make()
        defer { fixture.cleanup() }
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let supervisor = EngineSupervisor(binary: fixture.binary, config: fixture.config,
            api: BeamAPI(lane: lane), runtime: fixture.runtime())
        let starting = Task { try await supervisor.start() }
        try await eventually { await transport.observation.requests.count == 1 }
        let stopping = Task { await supervisor.stop() }
        try await eventually { !lane.snapshot.accepting }
        await transport.reply() // server-side drain of the old readiness socket
        await stopping.value
        do { try await starting.value; XCTFail("stopped start succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await supervisor.state
        XCTAssertEqual(state, .stopped)
        XCTAssertNil(fixture.pid)
        let observed = await transport.observation
        XCTAssertEqual(observed.requests.count, 1)
        XCTAssertEqual(observed.cancellations, 0)
    }

    func testStartDuringStopWaitsForProcessExitAndOldRequestDrain() async throws {
        let fixture = try ChildFixture.make()
        defer { fixture.cleanup() }
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let api = BeamAPI(lane: lane)
        let supervisor = EngineSupervisor(binary: fixture.binary, config: fixture.config,
            api: api, runtime: fixture.runtime())
        let initial = Task { try await supervisor.start() }
        try await eventually { await transport.observation.requests.count == 1 }
        await transport.reply()
        try await initial.value
        let oldPID = fixture.pid
        let oldWrite = Task { await api.setVolumeConfirmed(outputID: "a", volume: 10) }
        try await eventually { await transport.observation.requests.count == 2 }
        let stopping = Task { await supervisor.stop() }
        try await eventually { !lane.snapshot.accepting }
        let starting = Task { try await supervisor.start() }
        try await eventually { fixture.pid == nil }
        // The old process is gone, but its HTTP task still owns the lane. No
        // successor may be spawned until that response has been drained.
        XCTAssertEqual(fixture.events.count, 2)
        let oldResult = await oldWrite.value
        XCTAssertEqual(oldResult, .unknown)
        await transport.reply()
        await stopping.value
        try await eventually { await transport.observation.requests.count == 3 }
        XCTAssertNotEqual(fixture.pid, oldPID)
        XCTAssertEqual(fixture.events.map { $0.split(separator: " ")[0] }, ["start", "stop", "start"])
        await transport.reply()
        try await starting.value
        await supervisor.stop()
        let observed = await transport.observation
        XCTAssertEqual(observed.maxActive, 1)
        XCTAssertEqual(observed.cancellations, 0)
    }

    func testCancelledStopStillCompletesGracefulTeardown() async throws {
        let fixture = try ChildFixture.make()
        defer { fixture.cleanup() }
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let supervisor = EngineSupervisor(binary: fixture.binary, config: fixture.config,
            api: BeamAPI(lane: lane), runtime: fixture.runtime())
        let starting = Task { try await supervisor.start() }
        try await eventually { await transport.observation.requests.count == 1 }
        await transport.reply()
        try await starting.value
        let before = ContinuousClock.now
        let stopping = Task { await supervisor.stop() }
        stopping.cancel()
        await stopping.value
        let elapsed = before.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100))
        XCTAssertNil(fixture.pid)
        XCTAssertEqual(fixture.events.count, 2)
        let state = await supervisor.state
        XCTAssertEqual(state, .stopped)
    }

    func testOccupiedPTPPortsFailWithoutSpawning() async throws {
        let fixture = try ChildFixture.make()
        defer { fixture.cleanup() }
        let transport = ControlledBeamTransport()
        let supervisor = EngineSupervisor(binary: fixture.binary, config: fixture.config,
            api: BeamAPI(lane: RequestLane(transport: transport)), runtime: fixture.runtime(portsFree: false))
        do { try await supervisor.start(); XCTFail("overlapping PTP startup succeeded") }
        catch { XCTAssertTrue(String(describing: error).contains("PTP")) }
        XCTAssertNil(fixture.pid)
        XCTAssertTrue(fixture.events.isEmpty)
        let observed = await transport.observation
        XCTAssertTrue(observed.requests.isEmpty)
        let ptp = await supervisor.ptpAvailable
        XCTAssertFalse(ptp)
        let state = await supervisor.state
        guard case .failed = state else { return XCTFail("startup did not report failure") }
    }

    func testCrashDuringStartupDoesNotDeadlockRecoveryOnItsOwnStartTask() async throws {
        let fixture = try ChildFixture.make()
        defer { fixture.cleanup() }
        let transport = ControlledBeamTransport()
        let lane = RequestLane(transport: transport)
        let supervisor = EngineSupervisor(binary: fixture.binary, config: fixture.config,
            api: BeamAPI(lane: lane), runtime: fixture.runtime())
        let first = Task { try await supervisor.start() }
        try await eventually { await transport.observation.requests.count == 1 }
        let oldPID = try XCTUnwrap(fixture.pid)
        kill(oldPID, SIGKILL)
        try await eventually { !lane.snapshot.accepting }
        await transport.reply()
        do { try await first.value; XCTFail("dead startup succeeded") } catch { }
        // handleDeath's recovery joins/releases the failed start, then creates a
        // new one. It must not wait recursively on a task holding its own gate.
        try await eventually { await transport.observation.requests.count == 2 }
        XCTAssertNotEqual(fixture.pid, oldPID)
        await transport.reply()
        try await eventually { await supervisor.state == .running }
        await supervisor.stop()
        XCTAssertNil(fixture.pid)
    }
    func testSpotifyConcurrentStartsAndStartDuringStopNeverOverlapChildren() async throws {
        let fixture = try ChildFixture.make(binaryName: "librespot")
        defer { fixture.cleanup() }
        // Use the config path as a disposable pipe identity, so the same fixture
        // can record exact receiver start/exit without writing any audio.
        try FileManager.default.createDirectory(at: fixture.config.etcDir, withIntermediateDirectories: true)
        let supervisor = SpotifySupervisor(binary: fixture.binary,
            pipePath: fixture.config.confFile, cacheDir: fixture.root.appendingPathComponent("cache"))
        let first = Task { try await supervisor.start() }
        let second = Task { try await supervisor.start() }
        try await first.value
        try await second.value
        XCTAssertEqual(fixture.events.count, 1)
        let stopping = Task { await supervisor.stop() }
        // Request a replacement while graceful teardown still owns the gate.
        try await eventually { await supervisor.shutdownEpoch == 1 }
        let next = Task { try await supervisor.start() }
        await stopping.value
        try await next.value
        XCTAssertEqual(fixture.events.map { $0.split(separator: " ")[0] }, ["start", "stop", "start"])
        await supervisor.stop()
        XCTAssertNil(fixture.pid)
    }

    func testSpotifyStopWinsDuringStartupAndCancellationStillTearsDown() async throws {
        let fixture = try ChildFixture.make(binaryName: "librespot")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.config.etcDir, withIntermediateDirectories: true)
        let supervisor = SpotifySupervisor(binary: fixture.binary,
            pipePath: fixture.config.confFile, cacheDir: fixture.root.appendingPathComponent("cache"))
        let starting = Task { try await supervisor.start() }
        try await eventually { fixture.pid != nil }
        let stopping = Task { await supervisor.stop() }
        stopping.cancel()
        await stopping.value
        do { try await starting.value; XCTFail("stopped receiver startup succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await supervisor.state
        XCTAssertEqual(state, .stopped)
        XCTAssertNil(fixture.pid)
        XCTAssertEqual(fixture.events.map { $0.split(separator: " ")[0] }, ["start", "stop"])
    }

    func testCancelledShutdownEscalatesExactUnresponsiveChildAfterGrace() async throws {
        let fixture = try ChildFixture.make(ignoreTerm: true)
        defer { fixture.cleanup() }
        try fixture.config.materialize()
        let child = Process()
        child.executableURL = fixture.binary
        child.arguments = ["-f", "-c", fixture.config.confFile.path]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) }; child.waitUntilExit() }
        try await eventually { fixture.pid != nil }
        let before = ContinuousClock.now
        let shutdown = Task { await ManagedChildTermination.stop(child, graceSeconds: 0.1) }
        shutdown.cancel()
        let exited = await shutdown.value
        XCTAssertTrue(exited)
        XCTAssertGreaterThanOrEqual(before.duration(to: .now), .milliseconds(100))
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
    }

    func testSpotifyFailedTeardownCannotConfirmSafeProducerHandoff() async throws {
        let fixture = try ChildFixture.make(binaryName: "librespot")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.config.etcDir, withIntermediateDirectories: true)
        let supervisor = SpotifySupervisor(binary: fixture.binary,
            pipePath: fixture.config.confFile, cacheDir: fixture.root.appendingPathComponent("cache"),
            terminate: { _, _ in false })
        try await supervisor.start()
        let result = await supervisor.stopConfirmed()
        let active = await supervisor.hasActiveProducer
        XCTAssertFalse(result)
        XCTAssertTrue(active)
        XCTAssertNotNil(fixture.pid)
        let state = await supervisor.state
        guard case .failed = state else { return XCTFail("unverified teardown did not report failure") }
        // Dispose only this isolated fixture, then a fresh barrier may confirm
        // the terminated child. No live receiver or personal FIFO is involved.
        kill(try XCTUnwrap(fixture.pid), SIGKILL)
        try await eventually { !(await supervisor.hasActiveProducer) }
        let confirmedAfterExit = await supervisor.stopConfirmed()
        XCTAssertTrue(confirmedAfterExit)
    }

    func testSpotifyConfirmedStopWaitsForGracefulExit() async throws {
        let fixture = try ChildFixture.make(binaryName: "librespot")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.config.etcDir, withIntermediateDirectories: true)
        let supervisor = SpotifySupervisor(binary: fixture.binary,
            pipePath: fixture.config.confFile, cacheDir: fixture.root.appendingPathComponent("cache"))
        try await supervisor.start()
        let confirmed = await supervisor.stopConfirmed()
        XCTAssertTrue(confirmed)
        let active = await supervisor.hasActiveProducer
        XCTAssertFalse(active)
        XCTAssertNil(fixture.pid)
        XCTAssertEqual(fixture.events.map { $0.split(separator: " ")[0] }, ["start", "stop"])
    }

    func testSpotifyNewStartDuringStopInvalidatesHandoffProof() async throws {
        let fixture = try ChildFixture.make(binaryName: "librespot")
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.config.etcDir, withIntermediateDirectories: true)
        let supervisor = SpotifySupervisor(binary: fixture.binary,
            pipePath: fixture.config.confFile, cacheDir: fixture.root.appendingPathComponent("cache"))
        try await supervisor.start()
        let stopping = Task { await supervisor.stopConfirmed() }
        try await eventually { await supervisor.shutdownEpoch == 1 }
        let starting = Task { try await supervisor.start() }
        let proof = await stopping.value
        XCTAssertFalse(proof)
        try await starting.value
        let confirmed = await supervisor.stopConfirmed()
        XCTAssertTrue(confirmed)
        XCTAssertNil(fixture.pid)
    }

}
