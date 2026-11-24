import Foundation
import XCTest
@testable import BeamEngine

final class BeamAPIErrorTests: XCTestCase {
    func testStreamErrorKeepsItsReasonThroughFoundationBridge() {
        let reason = "Speaker silence was not accepted by the engine"
        let error: any Error = BeamAPIError(what: reason)
        XCTAssertEqual(error.localizedDescription, reason)
        XCTAssertEqual((error as NSError).localizedDescription, reason)
    }
}
