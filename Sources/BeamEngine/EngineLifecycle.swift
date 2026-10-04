import Foundation
import Darwin

/// An actor can reenter while waiting for child termination. This gate keeps the
/// entire stop/start transaction exclusive across those suspension points.
actor EngineLifecycleGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().resume() }
    }
}

/// Retain the exact Foundation child until it has exited. Clearing the handle
/// before verified teardown lets a successor overlap the old engine's sockets.
enum ManagedChildTermination {
    static func stop(_ process: Process, graceSeconds: TimeInterval) async -> Bool {
        await Task.detached { await stopUncancelled(process, graceSeconds: graceSeconds) }.value
    }

    private static func stopUncancelled(_ process: Process, graceSeconds: TimeInterval) async -> Bool {
        guard process.isRunning else { return true }
        guard isSameChild(process) else { return !process.isRunning }
        process.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(graceSeconds))
        while process.isRunning && clock.now < deadline {
            // Lifecycle work owns this task, not a caller that can cancel it.
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            // Recheck executable and argv immediately before escalation. A PID
            // reused between exit and Foundation notification is not our child.
            if isSameChild(process) { kill(process.processIdentifier, SIGKILL) }
            let killDeadline = clock.now.advanced(by: .seconds(1))
            while process.isRunning && clock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return !process.isRunning
    }
    private static func isSameChild(_ process: Process) -> Bool {
        guard let expected = process.executableURL,
              let actual = EngineSupervisor.processArguments(of: process.processIdentifier) else { return false }
        return URL(fileURLWithPath: actual.executable).resolvingSymlinksInPath().path
            == expected.resolvingSymlinksInPath().path
            && Array(actual.argv.dropFirst()) == (process.arguments ?? [])
    }

}
