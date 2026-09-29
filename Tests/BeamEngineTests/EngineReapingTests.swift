import Foundation
import Darwin
import XCTest
@testable import BeamEngine

final class EngineReapingTests: XCTestCase {
    func testOwnToneIdentityRequiresExactExecutableAndArguments() {
        let config = "/tmp/DALI engine/owntone.conf"
        XCTAssertTrue(EngineSupervisor.matchesOwnTone(
            executablePath: "/Applications/DALI.app/Contents/Helpers/owntone/owntone",
            arguments: ["-f", "-c", config], configPath: config))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(
            executablePath: "/bin/sh", arguments: ["-c", "owntone -f -c \(config)"],
            configPath: config))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(
            executablePath: "/tmp/owntone-debug", arguments: ["-f", "-c", config],
            configPath: config))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(
            executablePath: "/tmp/owntone", arguments: ["-f", "-c", config + ".old"],
            configPath: config))
        XCTAssertFalse(EngineSupervisor.matchesOwnTone(
            executablePath: "/tmp/owntone", arguments: ["-c", config, "-f"],
            configPath: config))
    }

    func testReapIgnoresUnrelatedProcessMentioningConfig() throws {
        let config = "/tmp/dali-engine-reap-test-\(UUID().uuidString).conf"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 5", config]
        try shell.run()
        defer {
            if shell.isRunning { shell.terminate() }
            shell.waitUntilExit()
        }

        XCTAssertEqual(EngineSupervisor.reapEngines(matchingConfig: config, graceSeconds: 0), [])
        XCTAssertTrue(shell.isRunning)
    }

    func testReapEscalatesOnlyMatchingOwnToneFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-reap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A disposable stand-in that ignores TERM, as the observed orphan did.
        // Compile it under the actual process name so pgrep and KERN_PROCARGS2
        // exercise the same path as the real engine.
        let source = root.appendingPathComponent("fixture.c")
        try """
        #include <signal.h>
        #include <stdio.h>
        #include <unistd.h>
        int main(void) {
            signal(SIGTERM, SIG_IGN);
            puts("ready");
            fflush(stdout);
            for (;;) pause();
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("owntone")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", binary.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)

        let config = root.appendingPathComponent("unique.conf").path
        let fixture = Process()
        fixture.executableURL = binary
        fixture.arguments = ["-f", "-c", config]
        let output = Pipe()
        fixture.standardOutput = output
        try fixture.run()
        defer {
            if fixture.isRunning { kill(fixture.processIdentifier, SIGKILL) }
            fixture.waitUntilExit()
        }
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readData(ofLength: 6),
                              as: UTF8.self), "ready\n")

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sh")
        unrelated.arguments = ["-c", "sleep 5", config]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
            unrelated.waitUntilExit()
        }

        let killed = EngineSupervisor.reapEngines(matchingConfig: config, graceSeconds: 0.1)
        XCTAssertEqual(killed, [fixture.processIdentifier])
        fixture.waitUntilExit()
        XCTAssertEqual(fixture.terminationReason, .uncaughtSignal)
        XCTAssertEqual(fixture.terminationStatus, SIGKILL)
        XCTAssertTrue(unrelated.isRunning)
    }
}
