import XCTest
@testable import BeamEngine

final class SpectrumAnalyzerTests: XCTestCase {
    private func sine(_ hz: Double, amplitude: Double = 0.5, frames: Int, rate: Double = 44_100) -> [Int16] {
        var out = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Int16(amplitude * 32767 * sin(2 * .pi * hz * Double(i) / rate))
            out[2 * i] = v; out[2 * i + 1] = v
        }
        return out
    }

    private func bands(_ analyzer: SpectrumAnalyzer, _ samples: [Int16]) -> [Float] {
        var last: [Float] = []
        let chunk = 882
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            let slice = Array(samples[i..<end])
            if let b = slice.withUnsafeBufferPointer({ analyzer.push(stereo: $0) }) { last = b }
            i = end
        }
        return last
    }

    func testASineLightsTheBandItIsIn() {
        let analyzer = SpectrumAnalyzer()
        let result = bands(analyzer, sine(1_000, frames: 8_820))
        XCTAssertEqual(result.count, SpectrumAnalyzer.bandCount)
        let top = result.indices.max { result[$0] < result[$1] }!
        XCTAssertEqual(result[top], 1, accuracy: 0.001)
        let centre = analyzer.centerFrequency(band: top)
        XCTAssertTrue(centre > 700 && centre < 1_400, "loudest band is at \(centre) Hz")
        // Bands an octave and more away stay well below it.
        XCTAssertLessThan(result[0], 0.25)
        XCTAssertLessThan(result[SpectrumAnalyzer.bandCount - 1], 0.25)
    }

    func testBassAndTrebleLandOnOppositeSides() {
        let low = bands(SpectrumAnalyzer(), sine(80, frames: 8_820))
        let high = bands(SpectrumAnalyzer(), sine(8_000, frames: 8_820))
        let lowTop = low.indices.max { low[$0] < low[$1] }!
        let highTop = high.indices.max { high[$0] < high[$1] }!
        XCTAssertLessThan(lowTop, SpectrumAnalyzer.bandCount / 4)
        XCTAssertGreaterThan(highTop, SpectrumAnalyzer.bandCount * 3 / 4)
    }

    func testSilenceStaysAtZero() {
        let result = bands(SpectrumAnalyzer(), [Int16](repeating: 0, count: 8_820 * 2))
        XCTAssertEqual(result, [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
    }

    func testNothingIsReportedUntilAFullWindowHasArrived() {
        let analyzer = SpectrumAnalyzer()
        let few = sine(1_000, frames: 500)
        XCTAssertNil(few.withUnsafeBufferPointer { analyzer.push(stereo: $0) })
    }

    func testResetForgetsTheLoudPast() {
        let analyzer = SpectrumAnalyzer()
        _ = bands(analyzer, sine(1_000, amplitude: 0.9, frames: 8_820))
        analyzer.reset()
        let quiet = bands(analyzer, sine(1_000, amplitude: 0.01, frames: 8_820))
        XCTAssertEqual(quiet.max() ?? 0, 1, accuracy: 0.001, "after a reset a quiet sine fills the display again")
    }
}
