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
        try await signalSnapshotsDistinguishMuteSilenceAndMissingMeasurements()
        try await stopCannotWaitForHardware()
        try await failedStartCanRetryAndSilenceIsPaced()
        try await slowTapStartIsNotMistakenForAStall()
        try await recoveryEvidenceRequiresFreshPublishedBuffers()
        try await gapDiscardsVarispeedHistory(returnToUnity: false)
        try await gapDiscardsVarispeedHistory(returnToUnity: true)
        var recoveryFailures = [String]()
        do { try await keepaliveUpdatesSilenceWithoutInventingCallbacks() }
        catch { recoveryFailures.append(String(describing: error)) }
        do { try await failedExternalRebuildCleansUpAndCanRestart() }
        catch { recoveryFailures.append(String(describing: error)) }
        try expect(recoveryFailures.isEmpty, recoveryFailures.joined(separator: "; "))
        try await inactiveSourceDoesNotSpendCaptureRecovery()
        try await inactiveSourceDoesNotSpendCaptureRecovery(nextActivity: nil)
        try await activeSourceFirstCallbackStaysHealthy()
        try sourceActivityClassifiesOnlyEligibleProcesses()
        try await blockedActivityProbeCannotBlockKeepaliveOrPolluteNewTap()
        try await queuedStallBecomingIdleDoesNotSpendAnAttempt()
        try await fakeCallDucksRoomAndRestoresAfterHangUp()
        print("PASS: production CaptureController lifecycle, stale conversion, mute/rebuild/source, stop latency and paced silence")
    }

    static func queuedStallBecomingIdleDoesNotSpendAnAttempt() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let active = Mutex<Bool?>(true)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockOnce = Mutex(true), skipped = Mutex(false)
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false,
            stallRebuildAfter: 0.4, sourceActivity: { _ in active.withLock { $0 } })
        capture.onEvent = { event in
            if event.hasPrefix("capture_recovery:"), blockOnce.withLock({ let old = $0; $0 = false; return old }) {
                entered.signal(); release.wait()
            }
            if event.hasPrefix("capture_recovery_skipped:") { skipped.withLock { $0 = true } }
        }
        defer { release.signal(); capture.stop() }
        try await capture.startAsync(fifoPath: fixture.path)
        try await waitSignal(entered)
        active.withLock { $0 = false }
        try await eventually { capture.callbackExpectation.sourceIsInactive }
        release.signal()
        try await eventually { skipped.withLock { $0 } || factory.count > 1 }
        try expect(factory.count == 1, "Queued callback recovery rebuilt a source which had become idle")
        active.withLock { $0 = true }
        try await eventually { !capture.callbackExpectation.sourceIsInactive }
        let began = ContinuousClock.now
        try await eventually { factory.count == 2 }
        try expect(began.duration(to: .now) < .milliseconds(700),
                   "Skipped idle recovery spent an attempt and doubled the next callback grace")
    }

    static func inactiveSourceDoesNotSpendCaptureRecovery(nextActivity: Bool? = true) async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let active = Mutex<Bool?>(false)
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false,
            stallRebuildAfter: 0.2, sourceActivity: { _ in active.withLock { $0 } })
        try await capture.startAsync(fifoPath: fixture.path)
        defer { capture.stop() }
        try await Task.sleep(for: .milliseconds(650))
        try expect(factory.count == 1, "Idle source without callbacks triggered a false tap rebuild")
        try expect(capture.callbackExpectation.sourceIsInactive &&
                   capture.callbackExpectation.secondsMissingExpectedBuffer == 0,
                   "Idle source was not excluded from callback recovery")
        try expect(capture.publicationProgress.publishedBuffers == 0 && capture.secondsSinceLastBuffer > 0.5,
                   "Idle eligibility fabricated real callback evidence or reset the actual clock")
        active.withLock { $0 = nextActivity }
        try await eventually { !capture.callbackExpectation.sourceIsInactive }
        try expect(capture.callbackExpectation.secondsMissingExpectedBuffer < 0.2,
                   "An active source inherited the entire idle interval as starvation")
        try await eventually { factory.count == 2 }
        try expect(capture.publicationProgress.publishedBuffers == 0,
                   "Activity alone was counted as a captured buffer")
    }

    static func sourceActivityClassifiesOnlyEligibleProcesses() throws {
        typealias Output = AudioSourceActivity.ProcessOutput
        let own = Output(pid: 123, isRunningOutput: true)
        let idle = Output(pid: 456, isRunningOutput: false)
        let active = Output(pid: 789, isRunningOutput: true)
        try expect(AudioSourceActivity.classify([own, idle], source: .system, ownPID: 123) == false,
                   "Own aggregate output was counted as system-source audio")
        try expect(AudioSourceActivity.classify([own, idle, active], source: .system, ownPID: 123) == true,
                   "External output-active source was ignored")
        try expect(AudioSourceActivity.classify([own, idle, active], source: .process(456), ownPID: 123) == false,
                   "Another process incorrectly activated the selected-process source")
        try expect(AudioSourceActivity.classify([own, active], source: .process(789), ownPID: 123) == true,
                   "Selected output-active PID was ignored")
        try expect(AudioSourceActivity.classify([Output(pid: nil, isRunningOutput: nil)],
                   source: .system, ownPID: 123) == nil, "Failed process query was misclassified as proven idle")
    }

    static func blockedActivityProbeCannotBlockKeepaliveOrPolluteNewTap() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let firstEntered = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
        let queriedSources = Mutex<[ProcessTap.Source]>([])
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false,
            stallRebuildAfter: 10, sourceActivity: { source in
                let count = queriedSources.withLock { $0.append(source); return $0.count }
                if count == 1 { firstEntered.signal(); releaseFirst.wait(); return false }
                if count == 2 { secondEntered.signal(); releaseSecond.wait() }
                return true
            })
        defer { releaseFirst.signal(); releaseSecond.signal(); capture.stop() }
        try await capture.startAsync(fifoPath: fixture.path)
        try await waitSignal(firstEntered)
        try await Task.sleep(for: .milliseconds(300))
        try expect(capture.readMetrics().silenceBytes > 0 && queriedSources.withLock { $0.count } == 1,
                   "Slow activity query blocked paced silence or spawned overlapping probes")
        let rebuilt = await capture.rebuildAsync(fifoPath: fixture.path, muteLocal: true,
                                                 source: .process(42), expectedSession: capture.sessionID)
        try expect(rebuilt, "Slow activity query blocked tap replacement")
        releaseFirst.signal()
        try await waitSignal(secondEntered)
        try expect(!capture.callbackExpectation.sourceIsInactive,
                   "Old tap's delayed inactive result polluted the replacement tap")
        try expect(queriedSources.withLock { $0.prefix(2).elementsEqual([.system, .process(42)]) },
                   "Replacement source was not passed to the eligibility probe")
        try expect(capture.publicationProgress.publishedBuffers == 0,
                   "Activity polling invented real callback evidence")
        capture.stop()
        releaseSecond.signal()
        try await Task.sleep(for: .milliseconds(20))
        try expect(!capture.isRunning && capture.publicationProgress.publishedBuffers == 0,
                   "Delayed activity result resurrected stopped capture")
    }

    static func activeSourceFirstCallbackStaysHealthy() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let active = Mutex<Bool?>(false)
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false,
            stallRebuildAfter: 0.2, sourceActivity: { _ in active.withLock { $0 } })
        try await capture.startAsync(fifoPath: fixture.path)
        defer { capture.stop() }
        try await Task.sleep(for: .milliseconds(450))
        active.withLock { $0 = true }
        try await eventually { !capture.callbackExpectation.sourceIsInactive }
        for _ in 0..<10 {
            factory.latest.emit(value: 0, rate: 44100)
            _ = fixture.readAvailable()
            try await Task.sleep(for: .milliseconds(40))
        }
        try expect(factory.count == 1 && capture.publicationProgress.publishedBuffers == 10,
                   "Healthy silent callbacks were rebuilt after idle source activation")
    }

    static func keepaliveUpdatesSilenceWithoutInventingCallbacks() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
        try await capture.startAsync(fifoPath: fixture.path)
        defer { capture.stop() }
        factory.latest.emit(value: 0.5, rate: 44100)
        try await eventually { capture.level > 0 }
        let before = capture.readLevels().level
        let count = capture.publicationProgress.publishedBuffers
        try await Task.sleep(for: .milliseconds(550))
        try expect(capture.digitalSilenceSeconds >= 0.2, "Keepalive zeros did not advance silence clock")
        try expect(capture.readLevels().level < before * 0.8, "Keepalive left the meter on old audio")
        try expect(capture.publicationProgress.publishedBuffers == count && capture.zeroBufferStreak == 0,
                   "Synthetic silence invented tap callbacks")
        factory.latest.emit(value: 0.5, rate: 44100)
        try expect(capture.digitalSilenceSeconds == 0, "Fresh PCM did not immediately clear keepalive silence")
        try await Task.sleep(for: .milliseconds(60))
        try expect(capture.digitalSilenceSeconds == 0, "Old timer silence overtook resumed audio")
    }

    static func failedExternalRebuildCleansUpAndCanRestart() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let starts = Mutex(0)
        factory.configure = { tap in tap.onStart = {
            let fail = starts.withLock { $0 += 1; return $0 == 2 }
            if fail { throw Failure(description: "Injected rebuild failure") }
        } }
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
        try await capture.startAsync(fifoPath: fixture.path)
        defer { capture.stop() }
        let rebuilt = await capture.rebuildAsync(fifoPath: fixture.path, muteLocal: true, source: .system,
                                                 expectedSession: capture.sessionID)
        try expect(!rebuilt && !capture.isRunning && capture.stats.pending == nil,
                   "Failed external rebuild retained its pipe/timer session")
        try await capture.startAsync(fifoPath: fixture.path)
        try await Task.sleep(for: .milliseconds(350))
        try expect(capture.readMetrics().silenceBytes > 0,
                   "Restart reused a stale timer instead of pacing new silence")
        try expect(capture.publicationProgress.publishedBuffers == 0,
                   "Restarted keepalive counted as a tap callback")
    }

    /// Prime the actual capture converter/resampler with positive samples,
    /// let its pipe switch to keepalive silence, then resume negative audio.
    /// No pre-gap positive sample may escape ahead of the new buffer's fade.
    static func gapDiscardsVarispeedHistory(returnToUnity: Bool) async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
        try await capture.startAsync(fifoPath: fixture.path)
        defer { capture.stop() }
        capture.setTargetRatio(0.995)
        for _ in 0..<20 {
            factory.latest.emit(value: 0.5, rate: 44100)
            try await eventually { capture.stats.pending == 0 }
            _ = fixture.readAvailable()
        }
        try expect(capture.readMetrics().ratio < 1,
                   "Gap regression did not prime fractional Varispeed history")
        if returnToUnity { capture.setTargetRatio(1) }
        try await Task.sleep(for: .milliseconds(200))
        try expect(capture.readMetrics().silenceBytes > 0, "Gap fixture never entered keepalive silence")
        // Drain only the already-queued gap silence before the resumed buffer.
        for _ in 0..<20 {
            _ = fixture.readAvailable()
            if capture.stats.pending == 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        _ = fixture.readAvailable()
        factory.latest.emit(value: -0.5, rate: 44100, frames: returnToUnity ? 4096 : 1024)
        let ratio = capture.readMetrics().ratio
        try expect(returnToUnity ? ratio == 1 : ratio < 1,
                   "Gap regression did not exercise its intended resampler branch")
        var resumed = [UInt8]()
        for _ in 0..<100 {
            resumed.append(contentsOf: fixture.readAvailable())
            if capture.stats.pending == 0 && !resumed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let samples = stride(from: 0, to: resumed.count - 1, by: 2).map {
            Int(Int16(bitPattern: UInt16(resumed[$0]) | UInt16(resumed[$0 + 1]) << 8))
        }
        try expect(samples.contains { $0 < -1000 }, "Gap regression did not observe resumed PCM")
        try expect((samples.max() ?? 0) <= 4,
                   "Pre-gap positive PCM leaked into \(returnToUnity ? "unity tail" : "interpolated") resume: peak \(samples.max() ?? 0)")
    }

    static func recoveryEvidenceRequiresFreshPublishedBuffers() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
        try await capture.startAsync(fifoPath: fixture.path)
        defer { capture.stop() }
        let initial = capture.publicationProgress
        try expect(!initial.isRecent(within: 1), "Synthetic tap-start clock counted as a real callback")
        factory.latest.emit(value: 0, rate: 44100)
        let delivered = capture.publicationProgress
        try expect(delivered.publishedBuffers > 0 && delivered.isRecent(within: 1),
                   "Legitimate silent PCM did not prove callback recovery")
        _ = capture.readMetrics()
        try expect(capture.publicationProgress.publishedBuffers == delivered.publishedBuffers,
                   "Flight metrics consumed recovery evidence")
        let old = factory.latest
        let rebuilt = await capture.rebuildAsync(fifoPath: fixture.path, muteLocal: true, source: .system,
                                                 expectedSession: capture.sessionID)
        try expect(rebuilt, "Recovery-evidence fixture could not rebuild")
        try expect(capture.publicationProgress.generation != delivered.generation &&
                   !capture.publicationProgress.isRecent(within: 2),
                   "Rebuild reused the old tap's recovery evidence")
        old.emit(value: 0, rate: 44100)
        try expect(!capture.publicationProgress.isRecent(within: 2), "Retired callback restored recovery budget")
        factory.latest.emit(value: 0, rate: 44100)
        try expect(capture.publicationProgress.isRecent(within: 2), "New tap's silent callback was ignored")
        capture.stop()
        try await capture.startAsync(fifoPath: fixture.path)
        try expect(!capture.publicationProgress.isRecent(within: 1), "New session reused prior capture evidence")
    }

    /// The stall clock used to be seeded before the HAL work and read straight
    /// after it, so a tap that took longer than the limit to START was rebuilt
    /// the instant it returned (the field showed exactly "no tap callbacks for
    /// 4s" with the first bytes). It must count from when the tap went live, and
    /// a tap that then really stays silent must still be rebuilt.
    /// A fake call while the room plays: the mic opens mid-session, the room
    /// drops to the duck level without a rebuild, and full level returns a few
    /// seconds after hang-up. A session started mid-call is ducked from its
    /// first buffer.
    static func fakeCallDucksRoomAndRestoresAfterHangUp() async throws {
        // Outgoing PCM level after all gain (master x call duck), in dBFS. The
        // snapshot resets per read, so each reading covers only these buffers.
        func level(_ capture: CaptureController, _ fixture: PipeFixture, _ tap: FakeTap) async throws -> Double {
            _ = capture.readMetrics(); _ = fixture.readAvailable()
            let before = capture.totalWritten
            for _ in 0..<4 { tap.emit() }
            try await eventually { capture.totalWritten > before }
            return capture.readMetrics().outputRMSDBFS
        }
        let mic = Mutex(false)
        let fixture = try PipeFixture(), factory = TapFactory()
        let events = Mutex<[String]>([])
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false,
                                        stallRebuildAfter: 60, // idle fake tap is not a stall here
                                        micInUse: { mic.withLock { $0 } }, callPollInterval: 0.02)
        capture.onEvent = { message in events.withLock { $0.append(message) } }
        try await capture.startAsync(fifoPath: fixture.path)
        let full = try await level(capture, fixture, factory.latest)
        try expect(full > -10 && !capture.isCallDucked, "Room was not at full level before the call")
        mic.withLock { $0 = true }
        try await eventually { capture.isCallDucked }
        _ = try await level(capture, fixture, factory.latest)   // spans the 15 ms ramp
        let ducked = try await level(capture, fixture, factory.latest)
        try expect(ducked > -60 && ducked < full - 15, "Room was not lowered during the call (\(ducked) vs \(full) dBFS)")
        try expect(factory.count == 1, "Ducking rebuilt the tap")
        mic.withLock { $0 = false }
        try await Task.sleep(for: .milliseconds(1000))
        try expect(capture.isCallDucked, "Room came back during the hang-up hold")
        for _ in 0..<300 where capture.isCallDucked { try await Task.sleep(for: .milliseconds(20)) }
        try expect(!capture.isCallDucked, "Room never came back after the call")
        _ = try await level(capture, fixture, factory.latest)   // spans the ramp back up
        let restored = try await level(capture, fixture, factory.latest)
        try expect(restored > full - 1, "Room did not return to full level after the call (\(restored) vs \(full) dBFS)")
        try expect(events.withLock { $0.contains { $0.hasPrefix("call_duck:") } && $0.contains { $0.hasPrefix("call_duck_released") } },
                   "Duck and restore were not logged")
        capture.stop()
        try expect(!capture.isCallDucked, "Stop left the next session ducked")

        mic.withLock { $0 = true }
        let midCall = try PipeFixture()
        try await capture.startAsync(fifoPath: midCall.path)
        try expect(capture.isCallDucked, "Session started mid-call was not ducked before audio")
        let first = try await level(capture, midCall, factory.latest)
        try expect(first < full - 15, "Session started mid-call played a full-level moment (\(first) dBFS)")
        capture.stop()
    }

    static func slowTapStartIsNotMistakenForAStall() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        factory.configure = { tap in tap.onStart = { Thread.sleep(forTimeInterval: 0.6) } }
        let events = Mutex<[String]>([])
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false,
                                        stallRebuildAfter: 0.4, sourceActivity: { _ in nil })
        capture.onEvent = { message in events.withLock { $0.append(message) } }
        try await capture.startAsync(fifoPath: fixture.path)
        try await Task.sleep(for: .milliseconds(150))
        try expect(!events.withLock { $0.contains { $0.hasPrefix("capture_recovery") } },
                   "A slow tap start was rebuilt as if its callbacks had stalled")
        try expect(capture.secondsSinceLastBuffer < 0.4,
                   "Start time counted as time without callbacks: \(capture.secondsSinceLastBuffer)")
        try expect(factory.count == 1, "Slow start produced a second tap")
        // Positive control: this tap never calls back, so it is rebuilt once the
        // limit has passed since it went live.
        try await eventually { events.withLock { $0.contains { $0.hasPrefix("capture_recovery") } } }
        try await eventually { factory.count == 2 }
        capture.stop()
    }

    static func stopWhileStarting() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        factory.configure = { tap in tap.onStart = { entered.signal(); release.wait() } }
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
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
        }, sourceActivity: { _ in nil })
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
                                        beforePublish: { usleep(300_000) }, sourceActivity: { _ in nil })
        try await capture.startAsync(fifoPath: fixture.path)
        factory.latest.emit()
        let flight = capture.readMetrics()
        try expect(flight.outBytes == 0 && flight.tapOverruns == 1, "Late conversion refreshed old PCM instead of discarding it")
        try expect(!capture.publicationProgress.isRecent(within: 1), "Discarded stale conversion proved callback recovery")
        // The timer can deliver fresh paced zeros while conversion is stalled.
        try expect(fixture.readAvailable().allSatisfy { $0 == 0 }, "Stale converted audio reached FIFO")
        capture.stop()
    }

    static func muteAfterAttachBeforeFirstBuffer() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        factory.configure = { tap in tap.onStart = { entered.signal(); release.wait() } }
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
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
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
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
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
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

    static func signalSnapshotsDistinguishMuteSilenceAndMissingMeasurements() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
        capture.setMasterGain(0)
        try await capture.startAsync(fifoPath: fixture.path)
        factory.latest.emit(rate: 44100)
        let muted = capture.readMetrics()
        try expect(muted.signalSamples > 0, "Muted source has no signal measurement")
        try expect(abs(muted.sourceRMSDBFS + 6.0206) < 0.01, "Source level includes master attenuation")
        try expect(muted.outputRMSDBFS == -120, "Muted outgoing PCM is not measured as silent")
        let empty = capture.readMetrics()
        try expect(empty.signalSamples == 0, "Snapshot reused the previous source signal")
        factory.latest.emit(value: 0, rate: 44100)
        let silent = capture.readMetrics()
        try expect(silent.signalSamples > 0 && silent.sourceRMSDBFS == -120 && silent.outputRMSDBFS == -120,
                   "Measured source silence is not distinct from missing callbacks")
        capture.stop()
        try expect(capture.readMetrics().signalSamples == 0, "Stopped capture retained a stale signal measurement")
    }

    static func failedStartCanRetryAndSilenceIsPaced() async throws {
        let fixture = try PipeFixture(), factory = TapFactory()
        let failOnce = Mutex(true)
        factory.configure = { tap in
            tap.onStart = {
                if failOnce.withLock({ let value = $0; $0 = false; return value }) { throw Failure(description: "Injected tap creation failure") }
            }
        }
        let capture = CaptureController(makeTap: { factory.make() }, observeWake: false, sourceActivity: { _ in nil })
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
