import XCTest
@testable import BeamEngine

final class FloorSyncTests: XCTestCase {
    func testAChangeInTheDigitalGainHoldsTheSpeakerVolume() {
        XCTAssertTrue(FloorSync.shouldHold(previousGain: 1.0, newGain: 0.5))
        XCTAssertTrue(FloorSync.shouldHold(previousGain: 0.5, newGain: 1.0))
    }

    func testNoChangeInTheDigitalGainNeverHolds() {
        XCTAssertFalse(FloorSync.shouldHold(previousGain: 1.0, newGain: 1.0))
        XCTAssertFalse(FloorSync.shouldHold(previousGain: 0.5, newGain: 0.502))
    }

    func testAMuteOnEitherSideIsNeverHeld() {
        XCTAssertFalse(FloorSync.shouldHold(previousGain: 0.5, newGain: 0))
        XCTAssertFalse(FloorSync.shouldHold(previousGain: 0, newGain: 0.5))
    }

    func testTheHoldIsTheRoomDelayLessTheTimeAWriteTakes() {
        XCTAssertEqual(FloorSync.holdSeconds(roomDelaySeconds: 1.0), 0.75, accuracy: 0.0001)
        XCTAssertEqual(FloorSync.holdSeconds(roomDelaySeconds: 0.1), 0, accuracy: 0.0001)
        XCTAssertEqual(FloorSync.holdSeconds(roomDelaySeconds: 9), 2, accuracy: 0.0001)
    }
}
