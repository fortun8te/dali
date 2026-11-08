import XCTest
@testable import BeamEngine

final class PacketLossTests: XCTestCase {
    private func report(requests: Int, suppressed: Int = 0, errors: Int = 0, streaming: Bool = true) -> DeliveryReport {
        DeliveryReport(device: "MICHAEL D", streaming: streaming, sent: 3_800, resendRequests: requests,
                       resendPackets: requests - suppressed, resendSuppressed: suppressed, sendErrors: errors)
    }

    func testParsesARealEngineLine() {
        let line = "[2026-10-26 17:19:02] [  LOG] [   player (3056)]  airplay: AI event=delivery_health device='MICHAEL D' sent_30s=3975 resend_req=269 resend_pkts=217 resend_supp=52 send_err=0 feedback_age_s=25 state=streaming"
        let parsed = DeliveryReport.parse(line)
        XCTAssertEqual(parsed, DeliveryReport(device: "MICHAEL D", streaming: true, sent: 3_975, resendRequests: 269,
                                              resendPackets: 217, resendSuppressed: 52, sendErrors: 0))
    }

    func testIgnoresOtherLinesAndHalfLines() {
        XCTAssertNil(DeliveryReport.parse("airplay: AI event=sync_health device='MICHAEL D' divergence_ms=19"))
        XCTAssertNil(DeliveryReport.parse("AI event=delivery_health device='MICHAEL D' sent_30s=12"))
        XCTAssertNil(DeliveryReport.parse(""))
    }

    func testReadsAConnectedNotStreamingReport() {
        let line = "AI event=delivery_health device='MICHAEL S' sent_30s=0 resend_req=0 resend_pkts=0 resend_supp=0 send_err=0 feedback_age_s=5 state=connected"
        XCTAssertEqual(DeliveryReport.parse(line)?.streaming, false)
    }

    func testNormalWindowsNeverRaiseTheBuffer() {
        var monitor = PacketLossMonitor()
        let start = Date()
        for i in 0..<40 {
            XCTAssertFalse(monitor.record(report(requests: 2 + i % 22, suppressed: i % 3), at: start.addingTimeInterval(Double(i) * 30)))
        }
    }

    func testOneBadWindowIsWeatherNotAPattern() {
        var monitor = PacketLossMonitor()
        XCTAssertFalse(monitor.record(report(requests: 110, suppressed: 9), at: Date()))
    }

    func testTwoBadWindowsWithinTenMinutesRaiseIt() {
        var monitor = PacketLossMonitor()
        let start = Date()
        XCTAssertFalse(monitor.record(report(requests: 104, suppressed: 4), at: start))
        XCTAssertTrue(monitor.record(report(requests: 95), at: start.addingTimeInterval(300)))
    }

    func testBadWindowsFarApartAreForgotten() {
        var monitor = PacketLossMonitor()
        let start = Date()
        XCTAssertFalse(monitor.record(report(requests: 104), at: start))
        XCTAssertFalse(monitor.record(report(requests: 104), at: start.addingTimeInterval(PacketLossMonitor.patternSeconds + 30)))
    }

    func testOneSevereWindowIsEnough() {
        var monitor = PacketLossMonitor()
        XCTAssertTrue(monitor.record(report(requests: 269, suppressed: 52), at: Date()))
    }

    func testAFailedSendCountsAsBad() {
        XCTAssertEqual(PacketLossMonitor.weight(of: report(requests: 3, errors: 1)), 1)
    }

    func testASpeakerThatIsNotStreamingIsNeverCounted() {
        XCTAssertEqual(PacketLossMonitor.weight(of: report(requests: 900, streaming: false)), 0)
    }

    func testResetForgetsThePattern() {
        var monitor = PacketLossMonitor()
        XCTAssertTrue(monitor.record(report(requests: 300), at: Date()))
        monitor.reset()
        XCTAssertFalse(monitor.record(report(requests: 95), at: Date()))
    }

    func testRememberedLossKeepsTheLongerBufferUntilItExpires() {
        let now = Date()
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: -40, is24GHz: false,
                                                  lossRaisedUntil: now.addingTimeInterval(3_600), now: now), 800)
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: -40, is24GHz: false,
                                                  lossRaisedUntil: now.addingTimeInterval(-1), now: now), 500)
        XCTAssertEqual(BufferPolicy.startBufferMs(rssi: nil, is24GHz: false, lossRaisedUntil: nil, now: now), 500)
    }
}
