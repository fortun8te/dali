import Foundation
import AVFoundation
import Synchronization

private struct Failure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}
private func trySignal(_ signal: DispatchSemaphore) -> Bool { signal.wait(timeout: .now()) == .success }
private func waitSignal(_ signal: DispatchSemaphore) async throws {
    for _ in 0..<500 {
        if trySignal(signal) { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw Failure(description: "Timed out waiting for the controlled test boundary")
}
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw Failure(description: "Timed out waiting for a capture result")
}
private final class FakeTap: CaptureTap, @unchecked Sendable {
    var clockAnchored = true
    var overrunCount = 0
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onInvalidated: ((String) -> Void)?
    var onStart: (@Sendable () throws -> Void)?
    var onStop: (@Sendable () -> Void)?
    private let state = Mutex((starts: 0, stops: 0, source: ProcessTap.Source.system))
    var stops: Int { state.withLock { $0.stops } }
    var source: ProcessTap.Source { state.withLock { $0.source } }
    func start(muteLocal: Bool, source: ProcessTap.Source) throws {
        state.withLock { $0.starts += 1; $0.source = source }
        try onStart?()
    }
    func stop() { state.withLock { $0.stops += 1 }; onStop?() }
    func emit(value: Float = 0.5, rate: Double = 48000, frames: UInt32 = 1024) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcm.frameLength = frames
        for channel in 0..<2 { for frame in 0..<Int(frames) { pcm.floatChannelData![channel][frame] = value } }
        onBuffer?(pcm)
    }
}
private final class TapFactory: @unchecked Sendable {
    let taps = Mutex<[FakeTap]>([])
    var configure: (@Sendable (FakeTap) -> Void)?
    func make() -> any CaptureTap {
        let tap = FakeTap(); configure?(tap); taps.withLock { $0.append(tap) }; return tap
    }
    var latest: FakeTap { taps.withLock { $0.last! } }
    var count: Int { taps.withLock { $0.count } }
}
private final class PipeFixture {
    let dir: URL
    let path: String
    let reader: Int32
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dali-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("audio.pipe").path
        guard mkfifo(path, 0o600) == 0 else { throw Failure(description: "Cannot create test FIFO") }
        reader = open(path, O_RDONLY | O_NONBLOCK)
        guard reader >= 0 else { throw Failure(description: "Cannot open test FIFO reader") }
    }
    func readAvailable() -> [UInt8] {
        var result = [UInt8](), buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<128 {
            let count = read(reader, &buffer, buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    deinit { close(reader); try? FileManager.default.removeItem(at: dir) }
}

@main
private struct CaptureLifecycleTests {
    static func main() async throws {
        try await stopWhileStarting()
        try await replaceDuringConversion()
        try await converterStallCannotRefreshOldAudio()
        try await muteAfterAttachBeforeFirstBuffer()
        try await mutedStartRebuildAndSourceSelection()
        try await stopCannotWaitForHardware()
        try await failedStartCanRetryAndSilenceIsPaced()
        print("PASS: production CaptureController lifecycle, stale conversion, mute/rebuild/source, stop latency and paced silence")
    }

    static func stopWhileStarting() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        factory.configure = { tap in tap.onStart = { entered.signal(); release.wait() } }
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false)
        let starting = Task { [path = fixture.path] in try await capture.startAsync(fifoPath: path) }
        try await waitSignal(entered)
        let begin = DispatchTime.now().uptimeNanoseconds
        capture.stop()
        try expect(DispatchTime.now().uptimeNanoseconds - begin < 100_000_000, "stop waited for HAL start")
        factory.latest.emit() // callback from the unfinished, invalidated start
        try expect(capture.readMetrics().outBytes == 0, "Cancelled startup published PCM")
        release.signal()
        do { try await starting.value; throw Failure(description: "Stopped startup succeeded") }
        catch is CancellationError {}
        try expect(!capture.isRunning, "Stopped startup resurrected capture")
    }

    static func replaceDuringConversion() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let converted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let blockOnce = Mutex(true)
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, beforePublish: {
            if blockOnce.withLock({ let value = $0; $0 = false; return value }) {
                converted.signal(); release.wait()
            }
        })
        try await capture.startAsync(fifoPath: fixture.path)
        let old = factory.latest
        DispatchQueue.global().async { old.emit(); finished.signal() }
        try await waitSignal(converted) // production conversion has completed
        let session = capture.sessionID
        let replaced = await capture.rebuildAsync(fifoPath: fixture.path, muteLocal: true, source: .process(123), expectedSession: session)
        try expect(replaced, "Replacement failed")
        release.signal(); try await waitSignal(finished)
        try expect(capture.readMetrics().outBytes == 0, "Retired converted buffer mutated new session metrics")
        try expect(capture.totalWritten == 0, "Retired converted buffer reached shared FIFO")
        old.emit() // also reject handlers which begin after replacement
        try expect(capture.readMetrics().bufCount == 0, "Late old tap updated current metrics")
        factory.latest.emit()
        try await eventually { capture.totalWritten > 0 }
        try expect(factory.latest.source == .process(123), "Process source was lost")
        capture.stop()
    }

    static func converterStallCannotRefreshOldAudio() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false,
                                        beforePublish: { usleep(300_000) })
        try await capture.startAsync(fifoPath: fixture.path)
        factory.latest.emit()
        let flight = capture.readMetrics()
        try expect(flight.outBytes == 0 && flight.tapOverruns == 1, "Late conversion refreshed old PCM instead of discarding it")
        // The timer can deliver fresh paced zeros while conversion is stalled.
        try expect(fixture.readAvailable().allSatisfy { $0 == 0 }, "Stale converted audio reached FIFO")
        capture.stop()
    }

    static func muteAfterAttachBeforeFirstBuffer() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        factory.configure = { tap in tap.onStart = { entered.signal(); release.wait() } }
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false)
        let starting = Task { [path = fixture.path] in try await capture.startAsync(fifoPath: path) }
        try await waitSignal(entered)
        capture.setMasterGain(0) // handler was attached at gain 1, HAL still starting
        release.signal(); try await starting.value
        factory.latest.emit()
        try await eventually { capture.totalWritten > 0 }
        let first = fixture.readAvailable()
        try expect(!first.isEmpty && first.allSatisfy { $0 == 0 }, "Mute during startup leaked a ramp from stale full gain")
        capture.stop()
    }

    static func mutedStartRebuildAndSourceSelection() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false)
        capture.setMasterGain(0)
        try await capture.startAsync(fifoPath: fixture.path, muteLocal: true, source: .system)
        factory.latest.emit()
        try await eventually { capture.totalWritten > 0 && capture.heardAudio }
        let first = fixture.readAvailable()
        try expect(!first.isEmpty && first.allSatisfy { $0 == 0 }, "Muted start leaked audio")
        try expect(capture.zeroBufferStreak == 0 && capture.digitalSilenceSeconds == 0, "Master mute looked like a dead or silent source")
        let session = capture.sessionID
        let rebuilt = await capture.rebuildAsync(fifoPath: fixture.path, muteLocal: true, source: .process(456), expectedSession: session)
        try expect(rebuilt, "Muted source switch failed")
        let written = capture.totalWritten
        factory.latest.emit(rate: 44100)
        try await eventually { capture.totalWritten > written && capture.heardAudio }
        let second = fixture.readAvailable()
        try expect(!second.isEmpty && second.allSatisfy { $0 == 0 }, "Muted rebuild leaked audio")
        capture.setMasterGain(.nan) // invalid updates preserve the current mute
        factory.latest.emit()
        try expect(capture.zeroBufferStreak == 0, "Gain affected zero-buffer canary")
        try expect(factory.latest.source == .process(456), "Source selection did not reach tap")
        capture.stop()
        try await capture.startAsync(fifoPath: fixture.path)
        factory.latest.emit()
        try await eventually { capture.totalWritten > 0 }
        try expect(fixture.readAvailable().allSatisfy { $0 == 0 }, "Desired mute did not survive stop/start")
        capture.stop()
    }

    static func stopCannotWaitForHardware() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false)
        try await capture.startAsync(fifoPath: fixture.path)
        factory.latest.onStop = { entered.signal(); release.wait() }
        let begin = DispatchTime.now().uptimeNanoseconds
        capture.stop()
        try expect(DispatchTime.now().uptimeNanoseconds - begin < 100_000_000, "stop blocked caller on hardware")
        try await waitSignal(entered)
        // This queued start must lose to the second stop while teardown stalls.
        let pending = Task { [path = fixture.path] in try await capture.startAsync(fifoPath: path) }
        try await Task.sleep(for: .milliseconds(20))
        capture.stop(); release.signal()
        do { try await pending.value; throw Failure(description: "Queued pre-stop start resurrected capture") }
        catch is CancellationError {}
        try expect(factory.count == 1 && !capture.isRunning, "Obsolete queued start created hardware")
    }

    static func failedStartCanRetryAndSilenceIsPaced() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let failOnce = Mutex(true)
        factory.configure = { tap in
            tap.onStart = {
                if failOnce.withLock({ let value = $0; $0 = false; return value }) { throw Failure(description: "Injected tap creation failure") }
            }
        }
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false)
        do { try await capture.startAsync(fifoPath: fixture.path); throw Failure(description: "Injected start failure disappeared") }
        catch let error as Failure { try expect(error.description == "Injected tap creation failure", "Wrong failure") }
        try expect(!capture.isRunning && factory.latest.stops == 1, "Failed start was not cleaned up")
        try await capture.startAsync(fifoPath: fixture.path)
        try await Task.sleep(for: .milliseconds(350))
        let flight = capture.readMetrics()
        try expect(flight.silenceBytes > 0 && flight.silenceBytes <= 176_400 / 2, "Keepalive backfilled old silence instead of pacing forward")
        capture.stop()
    }
}
