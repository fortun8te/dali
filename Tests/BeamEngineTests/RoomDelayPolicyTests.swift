import XCTest
@testable import BeamEngine

final class RoomDelayPolicyTests: XCTestCase {
    func testBundledEngineSchedulingAndReceiverLatencyAreCountedOnce() {
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: 700, trimMs: 0), 0.9, accuracy: 0.0001)
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: 500, trimMs: 0), 0.7, accuracy: 0.0001)
    }

    func testSavedListeningCorrectionIsAppliedToTheSharedDelay() {
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: 700, trimMs: -175), 0.725, accuracy: 0.0001)
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: 700, trimMs: 125), 1.025, accuracy: 0.0001)
    }

    func testLongSupportedBuffersAreNotTruncatedToTwoAndAHalfSeconds() {
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: 3000, trimMs: 400), 3.6, accuracy: 0.0001)
    }

    func testMalformedValuesStayInsideSupportedDelayRange() {
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: Int.min, trimMs: -.infinity), 0.7, accuracy: 0.0001)
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: Int.max, trimMs: .nan), 3.2, accuracy: 0.0001)
        XCTAssertEqual(RoomDelayPolicy.seconds(startBufferMs: 700, trimMs: 9000), 1.3, accuracy: 0.0001)
    }
}
