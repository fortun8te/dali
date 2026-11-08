import XCTest
import AVFoundation
@testable import BeamCapture

final class BeamCaptureTests: XCTestCase {

    func testSilenceDetectorAccumulatesAndResets() {
        var d = SilenceDetector(thresholdDB: -60)
        XCTAssertEqual(d.feed(rmsDB: -80, duration: 1.5), 1.5)
        XCTAssertEqual(d.feed(rmsDB: -90, duration: 0.5), 2.0)
        XCTAssertEqual(d.feed(rmsDB: -20, duration: 0.5), 0)   // audio resets
        XCTAssertEqual(d.feed(rmsDB: -61, duration: 3.0), 3.0)
    }

    func testRMSOfSilenceAndFullScale() {
        let silent = [Int16](repeating: 0, count: 1024)
        XCTAssertLessThan(SilenceDetector.rmsDB(int16Samples: silent, count: silent.count), -100)
        let loud = [Int16](repeating: 32767, count: 1024)
        XCTAssertEqual(SilenceDetector.rmsDB(int16Samples: loud, count: loud.count), 0, accuracy: 0.01)
    }

    func testConverterProducesPipeFormatBytes() throws {
        // 48 kHz stereo Float32 sine in -> expect ~44.1/48 ratio of frames out, 4 bytes per frame.
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let frames: AVAudioFrameCount = 4800
        let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = sinf(Float(i) * 0.05) * 0.5 }
        }
        let conv = try XCTUnwrap(FormatConverter(from: inFormat))
        // Streaming: the resampler holds back priming frames on early calls,
        // so assert the cumulative count over several buffers.
        var data = Data()
        for _ in 0..<5 { data.append(try XCTUnwrap(conv.convert(buf))) }
        let outFrames = data.count / 4   // 2ch * 2 bytes
        let expected = Int(5 * Double(frames) * 44100.0 / 48000.0)
        XCTAssertEqual(Double(outFrames), Double(expected), accuracy: 512)
        // Non-silent output
        let rms = data.withUnsafeBytes { raw in
            SilenceDetector.rmsDB(int16Samples: raw.bindMemory(to: Int16.self).baseAddress!, count: outFrames * 2)
        }
        XCTAssertGreaterThan(rms, -20)
    }

    func testFIFOWriterHoldsPipeOpenAndDeliversInOrder() throws {
        let dir = NSTemporaryDirectory() + "beamtest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/test.pipe"
        XCTAssertEqual(mkfifo(path, 0o644), 0)

        // The writer opens O_RDWR, so it is its own reader+writer: the pipe can
        // never reach zero writers (the EOF that dropped both speakers). Writes
        // succeed into the kernel buffer immediately, even before OwnTone reads.
        let writer = FIFOWriter(path: path)
        writer.write(Data(repeating: 1, count: 1024))
        writer.write(Data(repeating: 2, count: 2048))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(writer.writtenBytes, 3072)
        XCTAssertEqual(writer.droppedBytes, 0)

        // A consumer opening the same FIFO reads the bytes in order.
        let readFD = open(path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(readFD, 0)
        var readBuf = [UInt8](repeating: 0, count: 4096)
        let n = read(readFD, &readBuf, readBuf.count)
        XCTAssertEqual(n, 3072)
        XCTAssertEqual(readBuf[0], 1)
        XCTAssertEqual(readBuf[1500], 2)
        close(readFD)
        writer.closePipe()
    }

    func testFIFORetryReportsDrainedBacklogAfterSourcePauses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("audio.pipe").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let writer = FIFOWriter(path: path)
        defer { writer.closePipe() }
        let payload = Data(repeating: 42, count: 262_144)
        writer.write(payload)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertGreaterThan(writer.pendingBytes, 0)
        let reader = open(path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }
        var bytes = [UInt8](repeating: 0, count: 8192)
        var received = 0
        let deadline = Date().addingTimeInterval(2)
        while received < payload.count && Date() < deadline {
            let count = read(reader, &bytes, bytes.count)
            if count > 0 { received += count }
            else { Thread.sleep(forTimeInterval: 0.001) }
        }
        XCTAssertEqual(received, payload.count)
        Thread.sleep(forTimeInterval: 0.01)
        XCTAssertEqual(writer.pendingBytes, 0, "A drained pipe must not report a stalled backlog while the source is paused")
    }

    func testFIFORejectsLateWritesAfterPermanentClose() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("audio.pipe").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let writer = FIFOWriter(path: path)
        writer.closePipe()
        writer.write(Data(repeating: 7, count: 1024))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(writer.writtenBytes, 0, "A stopped writer must never reopen")
        XCTAssertEqual(writer.pendingBytes, 0)
    }

    func testFIFOProducerAppliesBackpressureBeforeReturning() {
        let writer = FIFOWriter(path: "/missing/dali-\(UUID().uuidString).pipe")
        defer { writer.closePipe() }
        writer.write(Data(repeating: 7, count: 1_764_000))
        XCTAssertLessThanOrEqual(writer.pendingBytes, 441_000)
        XCTAssertGreaterThan(writer.droppedBytes, 0,
                             "Admission must bound retained audio synchronously, before dispatch")
    }

    private func ramp(frames: Int) -> Data {
        var a = [Int16](); a.reserveCapacity(frames * 2)
        for i in 0..<frames { let v = Int16(truncatingIfNeeded: i); a.append(v); a.append(v) }
        return a.withUnsafeBytes { Data($0) }
    }

    func testVarispeedFrameCounts() {
        var vs = Varispeed()
        let inFrames = 4410
        let unity = vs.process(ramp(frames: inFrames), ratio: 1.0).count / 4
        XCTAssertEqual(Double(unity), Double(inFrames), accuracy: 3)   // ~unchanged

        vs.reset()
        let faster = vs.process(ramp(frames: inFrames), ratio: 1.02).count / 4
        XCTAssertEqual(Double(faster), Double(inFrames) / 1.02, accuracy: 4)  // ~2% fewer

        vs.reset()
        let slower = vs.process(ramp(frames: inFrames), ratio: 0.98).count / 4
        XCTAssertEqual(Double(slower), Double(inFrames) / 0.98, accuracy: 4)  // ~2% more
    }

    func testVarispeedContinuityNoCrash() {
        var vs = Varispeed()
        var total = 0
        for _ in 0..<50 { total += vs.process(ramp(frames: 940), ratio: 1.01).count / 4 }
        // 50 buffers of 940 frames at ratio 1.01 -> ~ (50*940)/1.01 frames, no crash
        XCTAssertEqual(Double(total), Double(50 * 940) / 1.01, accuracy: 60)
    }

    func testQuantizeSilenceClipRoundAndDither() {
        var rng: UInt32 = 1
        var dst = [Int16](repeating: 7, count: 4)
        let zeros: [Float] = [0, 0, 0, 0]
        zeros.withUnsafeBufferPointer { s in dst.withUnsafeMutableBufferPointer {
            FormatConverter.quantize(s, into: $0, rng: &rng) } }
        XCTAssertEqual(dst, [0, 0, 0, 0])

        let loud: [Float] = [2.0, -2.0, .nan, 0.5]
        loud.withUnsafeBufferPointer { s in dst.withUnsafeMutableBufferPointer {
            FormatConverter.quantize(s, into: $0, rng: &rng) } }
        XCTAssertEqual(dst[0], 32767); XCTAssertEqual(dst[1], -32768); XCTAssertEqual(dst[2], 0)
        XCTAssertEqual(Double(dst[3]), 16384, accuracy: 1)

        // Constant sub-LSB signal: dither must average back to it (truncation would give 0).
        var big = [Int16](repeating: 0, count: 20000)
        let sig = [Float](repeating: 0.25 / 32768, count: 20000)
        sig.withUnsafeBufferPointer { s in big.withUnsafeMutableBufferPointer {
            FormatConverter.quantize(s, into: $0, rng: &rng) } }
        let mean = Double(big.reduce(0) { $0 + Int($1) }) / 20000
        XCTAssertEqual(mean, 0.25, accuracy: 0.05)
    }

    func testVarispeedUnityIsBitExact() {
        var vs = Varispeed()
        let inp = ramp(frames: 1000)
        XCTAssertEqual(vs.process(inp, ratio: 1.0), inp)
    }

    // MARK: RefillController

    /// Closed-loop harness: plant fill' = +eps, measurement = the same 20 s EMA the
    /// flight loop uses, controller fed once per second.
    private func runRefill(_ rc: inout RefillController, seconds: Int, realFill: inout Double,
                           slow: inout Double, respond: Bool = true,
                           drop: (Int) -> Double = { _ in 0 },
                           hold: (Int) -> String = { _ in "" }) -> (maxEps: Double, maxSlew: Double, events: [RefillController.Event]) {
        var maxEps = 0.0, maxSlew = 0.0, prev = rc.eps
        var events: [RefillController.Event] = []
        for t in 0..<seconds {
            realFill += drop(t)
            slow += (1 - exp(-1.0 / 20.0)) * (realFill - slow)
            let h = hold(t)
            if let e = rc.update(dt: 1, target: 0.5, fillSlow: slow, holdReason: h, hard: false) { events.append(e) }
            if respond { realFill += rc.eps }
            maxEps = max(maxEps, rc.eps); maxSlew = max(maxSlew, abs(rc.eps - prev)); prev = rc.eps
        }
        return (maxEps, maxSlew, events)
    }

    func testRefillIdleIsExactlyZeroAtTargetOrAbove() {
        var rc = RefillController()
        var real = 0.5, slow = 0.5
        var r = runRefill(&rc, seconds: 600, realFill: &real, slow: &slow)
        XCTAssertEqual(rc.eps, 0); XCTAssertEqual(r.maxEps, 0); XCTAssertTrue(r.events.isEmpty)
        // A buffer that is too FULL is never touched (one-sided).
        real = 1.6; slow = 1.6
        r = runRefill(&rc, seconds: 600, realFill: &real, slow: &slow)
        XCTAssertEqual(r.maxEps, 0); XCTAssertEqual(rc.mode, .idle)
        // Inside the dead band: still nothing.
        real = 0.42; slow = 0.42
        r = runRefill(&rc, seconds: 600, realFill: &real, slow: &slow)
        XCTAssertEqual(r.maxEps, 0)
    }

    func testRefillHealsStepDropSlowlyAndReturnsToExactUnity() {
        var rc = RefillController()
        var real = 0.5, slow = 0.5
        // A 0.25 s step drop at t = 60 s, then 20 minutes to recover.
        let r = runRefill(&rc, seconds: 1200, realFill: &real, slow: &slow,
                          drop: { $0 == 60 ? -0.25 : 0 })
        XCTAssertLessThanOrEqual(r.maxEps, 0.0025 + 1e-12)          // 0.25 % authority cap
        XCTAssertGreaterThan(r.maxEps, 0.0020)                        // and it does use it
        XCTAssertLessThanOrEqual(r.maxSlew, 0.0025 / 8 + 1e-9)        // >= 8 s ramp, no steps
        XCTAssertEqual(rc.eps, 0)                                     // exactly 1.0 again
        XCTAssertEqual(rc.mode, .idle)
        XCTAssertEqual(real, 0.5, accuracy: 0.06)                     // healed, little overshoot
        XCTAssertLessThan(rc.sessionAdded, 0.4)
        var started = 0, ended = 0
        for e in r.events { if case .started = e { started += 1 }; if case .finished = e { ended += 1 } }
        XCTAssertEqual(started, 1); XCTAssertEqual(ended, 1)          // no chatter
    }

    func testRefillNoEffectStopsAndBacksOff() {
        var rc = RefillController()
        var real = 0.3, slow = 0.3
        // The plant ignores us (or the measurement lies): give up after ~60 s of
        // stretching, stay at 1.0 for the whole back-off.
        let r = runRefill(&rc, seconds: 500, realFill: &real, slow: &slow, respond: false)
        var noEffect = false
        for e in r.events { if case .finished(let reason, let backoff, _) = e, reason == "noeffect", backoff >= 600 { noEffect = true } }
        XCTAssertTrue(noEffect)
        XCTAssertEqual(rc.eps, 0)
        XCTAssertEqual(rc.label, "backoff")
        XCTAssertLessThan(rc.sessionAdded, 0.30)
    }

    func testRefillBudgetBoundsAddedAudioWhateverTheMeasurementSays() {
        var rc = RefillController()
        // Worst case: the measurement is pinned far below target forever (and the
        // "plant" is assumed to respond), for 10 hours. Added audio stays bounded.
        for _ in 0..<36_000 {
            rc.update(dt: 1, target: 0.5, fillSlow: 0.0, holdReason: "", hard: false)
        }
        XCTAssertLessThanOrEqual(rc.sessionAdded, rc.cfg.sessionCapSec + 0.01)
        XCTAssertEqual(rc.mode, .idle)
        XCTAssertEqual(rc.eps, 0)
    }

    func testRefillHoldsOnSoftInvalidAndEasesOnHardWithoutSteps() {
        var rc = RefillController()
        var real = 0.3, slow = 0.3
        _ = runRefill(&rc, seconds: 80, realFill: &real, slow: &slow)
        XCTAssertEqual(rc.mode, .stretching)
        let e0 = rc.eps
        XCTAssertGreaterThan(e0, 0.001)
        // Soft invalid reading: eps is held, not dropped and not raised.
        rc.update(dt: 1, target: 0.5, fillSlow: 0.3, holdReason: "apislow", hard: false)
        XCTAssertEqual(rc.eps, e0, accuracy: 1e-12)
        // Hard discontinuity: eases out at the slew rate, never a step.
        rc.update(dt: 1, target: 0.5, fillSlow: nil, holdReason: "taprebuild", hard: true)
        XCTAssertEqual(rc.mode, .easing)
        XCTAssertGreaterThanOrEqual(rc.eps, e0 - 0.0025 / 8 - 1e-12)
        for _ in 0..<12 { rc.update(dt: 1, target: 0.5, fillSlow: nil, holdReason: "noanchor", hard: true) }
        XCTAssertEqual(rc.eps, 0); XCTAssertEqual(rc.mode, .idle)
    }

    func testRefillDoesNotArmInsideSettleWindow() {
        var rc = RefillController()
        // Volume hold right up to second 20: no stretch may start before 15 valid s.
        for t in 0..<34 {
            rc.update(dt: 1, target: 0.5, fillSlow: 0.2, holdReason: t < 20 ? "volume" : "", hard: false)
            XCTAssertEqual(rc.eps, 0, "t=\(t)")
        }
    }
}
