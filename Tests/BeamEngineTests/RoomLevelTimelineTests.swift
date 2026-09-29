import Foundation
import XCTest
@testable import BeamEngine

final class RoomLevelTimelineTests: XCTestCase {
    func testPresentationUsesCaptureTimeRatherThanPollTime() {
        let captured = Date(timeIntervalSinceReferenceDate: 1_000)
        var line = RoomLevelTimeline()
        line.append(RoomLevelSample(at: captured, level: 0.8, bass: 0.9,
                                    treble: 0.4, beats: 1, beatAt: captured))

        // The UI did not poll until 200 ms after capture. The beat should still
        // become due at capture + roomDelay, with no extra poll-time hold.
        XCTAssertNil(line.latestDue(at: captured.addingTimeInterval(0.899), delay: 0.9))
        let due = line.latestDue(at: captured.addingTimeInterval(0.9), delay: 0.9)
        XCTAssertEqual(due?.at, captured)
        XCTAssertEqual(due?.beatAt?.addingTimeInterval(0.9),
                       captured.addingTimeInterval(0.9))
    }

    func testNonFiniteDelayCannotTrapAndUndrainedLineIsBounded() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        var line = RoomLevelTimeline()
        for tick in 0..<5_000 {
            line.append(RoomLevelSample(at: start.addingTimeInterval(Double(tick) / 30), level: Double(tick),
                                        bass: 0, treble: 0, beats: 0, beatAt: nil))
        }
        // Nobody drained the line above; it must have stayed bounded (oldest dropped).
        XCTAssertNotNil(line.latestDue(at: start.addingTimeInterval(1_000), delay: 0))
        for delay in [Double.nan, .infinity, -.infinity, -5, 1e300] {
            _ = line.latestDue(at: start, delay: delay)   // must not crash
        }
    }

    func testMaximumSupportedDelayRetainsEarliestSample() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        let delay = RoomDelayPolicy.seconds(startBufferMs: 3000, trimMs: 400)
        XCTAssertEqual(delay, 3.6, accuracy: 0.0001)
        var line = RoomLevelTimeline()
        for tick in 0...108 {
            let now = start.addingTimeInterval(Double(tick) / 30)
            line.append(RoomLevelSample(at: now, level: Double(tick), bass: 0,
                                        treble: 0, beats: tick, beatAt: nil))
            let due = line.latestDue(at: now, delay: delay)
            if tick < 108 { XCTAssertNil(due) }
            else { XCTAssertEqual(due?.level, 0) }
        }
    }
}
