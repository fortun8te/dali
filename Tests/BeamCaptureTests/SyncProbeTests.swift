import XCTest
@testable import BeamCapture

final class SyncProbeTests: XCTestCase {
    /// A deterministic noise source, so a failure reproduces.
    private struct Noise {
        var seed: UInt32 = 0x1234_5678
        mutating func next() -> Float {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Float(Double(seed) / Double(UInt32.max) * 2 - 1)
        }
    }

    /// What the microphone hears: the probe `delay` after it was written, quieter,
    /// with an echo, room noise and optionally music under it.
    private func room(delay: Double, sampleRate: Double = 48_000, seconds: Double = 4.5,
                      start: Double, emitted: Double, level: Double = 0.04, noise: Float = 0.01,
                      echo: (delay: Double, gain: Double)? = (0.004, 0.6), music: Bool = false) -> [Float] {
        var noiseSource = Noise()
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            let heardAt = start + Double(i) / sampleRate
            let t = heardAt - emitted - delay
            var v = SyncProbe.value(at: t) * level / SyncProbe.amplitude
            if let echo { v += SyncProbe.value(at: t - echo.delay) * level * echo.gain / SyncProbe.amplitude }
            if music { v += 0.03 * sin(2 * Double.pi * 220 * heardAt) + 0.02 * sin(2 * Double.pi * 1_320 * heardAt) }
            return Float(v) + noiseSource.next() * noise
        }
    }

    func testFindsTheRoomDelayToWellUnderAMillisecond() throws {
        let emitted = 1_000.0, start = 999.95
        for delay in [0.712, 1.0437, 1.388] {
            let recording = room(delay: delay, start: start, emitted: emitted)
            let result = try XCTUnwrap(SyncProbe.measure(recording: recording, sampleRate: 48_000,
                                                         recordingStart: start, emittedAt: emitted,
                                                         search: 0.1...2.2))
            XCTAssertEqual(result.delaySec, delay, accuracy: 0.0005, "delay \(delay)")
            XCTAssertEqual(result.heard, 4)
            XCTAssertLessThan(result.spreadMs, 1)
        }
    }

    func testHoldsUpUnderMusicAndAtAnotherMicRate() throws {
        let emitted = 50.0, start = 50.02
        let recording = room(delay: 0.9311, sampleRate: 44_100, start: start, emitted: emitted,
                             level: 0.03, noise: 0.02, music: true)
        let result = try XCTUnwrap(SyncProbe.measure(recording: recording, sampleRate: 44_100,
                                                     recordingStart: start, emittedAt: emitted,
                                                     search: 0.1...2.0))
        XCTAssertEqual(result.delaySec, 0.9311, accuracy: 0.0005)
    }

    func testTimesTheDirectSoundNotTheEcho() throws {
        let emitted = 10.0, start = 10.0
        let recording = room(delay: 1.2, start: start, emitted: emitted, echo: (0.012, 0.8))
        let result = try XCTUnwrap(SyncProbe.measure(recording: recording, sampleRate: 48_000,
                                                     recordingStart: start, emittedAt: emitted,
                                                     search: 0.1...2.0))
        XCTAssertEqual(result.delaySec, 1.2, accuracy: 0.0005)
    }

    func testRefusesWhenTheChirpsAreNotHeard() {
        let emitted = 10.0, start = 10.0
        let silentRoom = room(delay: 1.0, start: start, emitted: emitted, level: 0, echo: nil, music: true)
        XCTAssertNil(SyncProbe.measure(recording: silentRoom, sampleRate: 48_000, recordingStart: start,
                                       emittedAt: emitted, search: 0.1...2.0))
        let buried = room(delay: 1.0, start: start, emitted: emitted, level: 0.0005, noise: 0.05, echo: nil)
        XCTAssertNil(SyncProbe.measure(recording: buried, sampleRate: 48_000, recordingStart: start,
                                       emittedAt: emitted, search: 0.1...2.0))
    }

    func testRefusesADelayOutsideTheSearch() {
        let emitted = 10.0, start = 10.0
        let recording = room(delay: 1.6, start: start, emitted: emitted)
        let result = SyncProbe.measure(recording: recording, sampleRate: 48_000, recordingStart: start,
                                       emittedAt: emitted, search: 0.1...1.0)
        XCTAssertNil(result)
    }

    func testWriterPlacesEachChirpOnItsFrameInBothChannels() {
        var writer = SyncProbe.Writer()
        var all: [Int16] = []
        // Odd-sized buffers, as the pipe delivers them.
        while !writer.finished {
            var data = Data(repeating: 0x55, count: 941 * 4)
            writer.write(into: &data)
            all += data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        let frames = all.count / 2
        for i in 0..<frames { XCTAssertEqual(all[2 * i], all[2 * i + 1]) }
        let leadFrames = Int(SyncProbe.leadSec * SyncProbe.pipeRate)
        XCTAssertTrue(all[0..<(2 * leadFrames)].allSatisfy { $0 == 0 }, "the lead is silent")
        for offset in SyncProbe.burstOffsets {
            let start = leadFrames + Int((offset * SyncProbe.pipeRate).rounded())
            let middle = start + Int(SyncProbe.chirpSec * SyncProbe.pipeRate / 2)
            let peak = (middle - 40..<middle + 40).map { abs(Int(all[2 * $0])) }.max() ?? 0
            XCTAssertGreaterThan(peak, 8_000, "chirp at \(offset) s")
            XCTAssertEqual(all[2 * (start - 2)], 0, "silent just before the chirp at \(offset) s")
        }
        var after = Data(repeating: 0x55, count: 400)
        writer.write(into: &after)
        XCTAssertTrue(after.allSatisfy { $0 == 0 }, "silence after the pattern")
    }
}
