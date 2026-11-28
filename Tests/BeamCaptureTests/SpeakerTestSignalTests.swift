import XCTest
@testable import BeamCapture

final class SpeakerTestSignalTests: XCTestCase {
    private func run(_ output: SpeakerTestSignal.Output, frames: Int = 44_100,
                     signal: inout SpeakerTestSignal) -> [Int16] {
        var data = Data(repeating: 0x7F, count: frames * 4)
        let before = data.count
        signal.write(output, into: &data)
        XCTAssertEqual(data.count, before, "the pipe's pacing depends on the length staying the same")
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func rms(_ samples: [Int16], channel: Int) -> Double {
        let values = stride(from: channel, to: samples.count, by: 2).map { Double(samples[$0]) / 32768 }
        return (values.map { $0 * $0 }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    func testLeftPlaysOnlyLeftAndRightOnlyRight() {
        var signal = SpeakerTestSignal()
        let left = run(.left, signal: &signal)
        XCTAssertEqual(rms(left, channel: 1), 0, "not a single sample may leak into the other channel")
        XCTAssertGreaterThan(rms(left, channel: 0), 0.03)
        XCTAssertLessThan(rms(left, channel: 0), 0.3)
        _ = run(.silence, frames: 1_000, signal: &signal)
        let right = run(.right, signal: &signal)
        XCTAssertEqual(rms(right, channel: 0), 0)
        XCTAssertGreaterThan(rms(right, channel: 1), 0.03)
    }

    func testItStartsAndStopsWithoutAClick() {
        var signal = SpeakerTestSignal()
        let start = run(.left, frames: 40, signal: &signal)
        XCTAssertLessThan(abs(Int(start[0])), 200, "the first sample starts from nothing")
        _ = run(.left, frames: 4_000, signal: &signal)
        let stop = run(.silence, frames: 1_000, signal: &signal)
        XCTAssertEqual(stop[stop.count - 2], 0, "a ramp ends in true silence")
    }

    /// Once round the room: the sound starts ahead, in phase, and is opposite in phase
    /// halfway round, which is what tells the decoder it is behind the listener.
    func testTheCircleSteersFromAheadToBehind() {
        var signal = SpeakerTestSignal()
        func relation(_ samples: [Int16]) -> Double {
            var cross = 0.0, power = 0.0
            for f in stride(from: 0, to: samples.count - 1, by: 2) {
                let l = Double(samples[f]), r = Double(samples[f + 1])
                cross += l * r; power += l * l + r * r
            }
            return 2 * cross / power
        }
        let ahead = run(.circle, frames: 2_205, signal: &signal)
        XCTAssertGreaterThan(relation(ahead), 0.8)
        _ = run(.circle, frames: 105_840, signal: &signal)   // to just before halfway round
        let behind = run(.circle, frames: 4_410, signal: &signal)
        XCTAssertLessThan(relation(behind), -0.8)
        XCTAssertLessThan(abs(rms(behind, channel: 0) - rms(behind, channel: 1)), 0.03)
    }

    func testSilenceReplacesTheCapturedAudio() {
        var signal = SpeakerTestSignal()
        XCTAssertTrue(run(.silence, frames: 500, signal: &signal).allSatisfy { $0 == 0 })
    }
}
