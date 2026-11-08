import XCTest
@testable import BeamEngine

final class BufferPolicyTests: XCTestCase {
    func testAWiredOrUnknownLinkKeepsTheShortBuffer() {
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: nil, is24GHz: false), BufferPolicy.healthyMs)
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: 0, is24GHz: true), BufferPolicy.healthyMs)
    }

    func testAStrong5GHzLinkKeepsTheShortBuffer() {
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: -55, is24GHz: false), 500)
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: -66, is24GHz: false), 500)
    }

    func testAWeakLinkGetsTheLongerBuffer() {
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: -67, is24GHz: false), BufferPolicy.weakLinkMs)
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: -72, is24GHz: false), 800)
    }

    func testThe24GHzBandGetsTheLongerBufferEvenWhenStrong() {
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: -50, is24GHz: true), 800)
    }
}
