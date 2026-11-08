import Foundation
import XCTest
@testable import BeamEngine

final class StartupTimingTests: XCTestCase {
    func testOwnProcessStartIsRecentAndInThePast() throws {
        let start = try XCTUnwrap(StartupTiming.processStart())
        let age = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(age, 0)
        XCTAssertLessThan(age, 24 * 3600, "a test process has not been running for a day")
    }

    func testUnknownProcessHasNoStart() {
        XCTAssertNil(StartupTiming.processStart(pid: 0x7fff_fff0))
    }

    func testMillisecondsAreClampedAndRounded() {
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(StartupTiming.milliseconds(from: t, to: t.addingTimeInterval(1.2344)), 1234)
        XCTAssertEqual(StartupTiming.milliseconds(from: t, to: t.addingTimeInterval(-5)), 0)
        XCTAssertEqual(StartupTiming.milliseconds(from: t, to: .distantFuture) > 0, true)
    }

    func testLabelsStayReadable() {
        XCTAssertEqual(StartupTiming.label(milliseconds: 850), "850 ms")
        XCTAssertEqual(StartupTiming.label(milliseconds: 3400), "3.4 s")
    }
}
