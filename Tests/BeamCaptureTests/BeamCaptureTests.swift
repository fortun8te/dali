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
}
