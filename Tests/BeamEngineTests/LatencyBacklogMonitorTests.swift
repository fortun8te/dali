import XCTest
@testable import BeamEngine

final class LatencyBacklogMonitorTests: XCTestCase {
    // 2026-10-11 flight log: a steady 1.17 s queue after a network drop.
    private let stuck = 206_000
    private let idle = 1_880

    private func feed(_ m: inout LatencyBacklogMonitor, seconds: Int, pending: Int,
                      playing: Bool? = true) -> [Int] {
        (0..<seconds).compactMap { i in
            m.update(dt: 1, pendingBytes: pending, playing: playing) ? i : nil
        }
    }

    func testHealthyQueueNeverReplays() {
        var m = LatencyBacklogMonitor()
        XCTAssertEqual(feed(&m, seconds: 600, pending: idle), [])
    }

    func testSustainedBacklogWhilePlayingReplaysOnce() {
        var m = LatencyBacklogMonitor()
        XCTAssertEqual(feed(&m, seconds: 30, pending: stuck), [4])
    }

    func testShortBurstsAndPausedPlayerDoNotReplay() {
        var m = LatencyBacklogMonitor()
        for _ in 0..<20 {
            XCTAssertEqual(feed(&m, seconds: 3, pending: stuck), [])
            XCTAssertEqual(feed(&m, seconds: 1, pending: idle), [])
        }
        // OwnTone deliberately stops reading while its player is not playing.
        XCTAssertEqual(feed(&m, seconds: 30, pending: stuck, playing: false), [])
    }

    func testUnknownPlayerStateHoldsProgressInsteadOfClearingIt() {
        var m = LatencyBacklogMonitor()
        XCTAssertEqual(feed(&m, seconds: 3, pending: stuck), [])
        XCTAssertEqual(feed(&m, seconds: 10, pending: stuck, playing: nil), [])
        XCTAssertEqual(feed(&m, seconds: 2, pending: stuck), [1])
    }

    func testRepeatedBacklogBacksOffInsteadOfDippingEveryMinute() {
        var m = LatencyBacklogMonitor()
        let replays = feed(&m, seconds: 3_600, pending: stuck)
        XCTAssertEqual(replays.first, 4)
        let gaps = zip(replays.dropFirst(), replays).map { $0 - $1 }
        XCTAssertEqual(gaps, [60, 120, 240, 480, 960, 1_800].prefix(gaps.count).map { $0 })
        XCTAssertLessThanOrEqual(replays.count, 6)
    }

    func testANewIncidentLongAfterRecoveryUsesTheShortCooldownAgain() {
        var m = LatencyBacklogMonitor()
        XCTAssertEqual(feed(&m, seconds: 10, pending: stuck), [4])
        XCTAssertEqual(feed(&m, seconds: 1_000, pending: idle), [])
        XCTAssertEqual(feed(&m, seconds: 10, pending: stuck), [4])
        XCTAssertEqual(m.requiredCooldownSec, 60)
    }

    func testMalformedIntervalsStayBounded() {
        var m = LatencyBacklogMonitor()
        XCTAssertFalse(m.update(dt: .infinity, pendingBytes: stuck, playing: true))
        XCTAssertFalse(m.update(dt: .nan, pendingBytes: stuck, playing: true))
        XCTAssertFalse(m.update(dt: -5, pendingBytes: -1, playing: true))
    }
}
