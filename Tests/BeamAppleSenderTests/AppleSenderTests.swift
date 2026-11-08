import AVFoundation
import CoreMedia
import XCTest
@testable import BeamAppleSender

final class AppleSenderTests: XCTestCase {
    private func buffer(rate: Double, interleaved: Bool, frames: Int = 480) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 2, interleaved: interleaved)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let data = buf.floatChannelData!
        for frame in 0..<frames {
            if interleaved {
                data[0][frame * 2] = 0.25
                data[0][frame * 2 + 1] = -0.5
            } else {
                data[0][frame] = 0.25
                data[1][frame] = -0.5
            }
        }
        return buf
    }

    func testBridgeKeepsChannelsAndContinuousTimestamps() throws {
        for rate in [44_100.0, 48_000.0] {
            for interleaved in [false, true] {
                let bridge = PCMBridge()
                let input = buffer(rate: rate, interleaved: interleaved)
                let first = try bridge.packet(input)
                let second = try bridge.packet(input)
                XCTAssertEqual(CMSampleBufferGetNumSamples(first), 480)
                XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first), .zero)
                XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(second),
                               CMTime(value: 480, timescale: Int32(rate)))
                var values = [Float](repeating: 0, count: 960)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(first)!, atOffset: 0,
                                               dataLength: $0.count, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, noErr)
                XCTAssertTrue(stride(from: 0, to: 960, by: 2).allSatisfy { values[$0] == 0.25 && values[$0 + 1] == -0.5 })
            }
        }
    }

    func testBridgeRejectsFormatChangeWithinOneEpoch() throws {
        let bridge = PCMBridge()
        _ = try bridge.packet(buffer(rate: 48_000, interleaved: true))
        XCTAssertThrowsError(try bridge.packet(buffer(rate: 44_100, interleaved: true))) {
            XCTAssertEqual($0 as? PCMBridge.Failure, .changedFormat)
        }
    }

    func testBridgeReplacesNonFiniteSamplesWithSilence() throws {
        let input = buffer(rate: 48_000, interleaved: true, frames: 4)
        input.floatChannelData![0][0] = .nan
        input.floatChannelData![0][1] = .infinity
        let packet = try PCMBridge().packet(input)
        var values = [Float](repeating: 9, count: 8)
        _ = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(packet)!, atOffset: 0,
                                       dataLength: $0.count, destination: $0.baseAddress!)
        }
        XCTAssertEqual(values[0], 0)
        XCTAssertEqual(values[1], 0)
    }

    func testMissingRoutingAPIIsReportedNotAssumed() {
        let missing = AppleRouteAPI.missing(has: { _ in false })
        XCTAssertEqual(missing, AppleRouteAPI.requirements)
        XCTAssertTrue(AppleRouteAPI.missing(has: { _ in true }).isEmpty)
    }

    func testSenderRefusesToEnqueueBeforeStart() {
        let sender = AppleRouteSender()
        XCTAssertFalse(sender.isStarted)
        XCTAssertThrowsError(try sender.enqueue(buffer(rate: 48_000, interleaved: true))) {
            XCTAssertEqual($0 as? AppleRouteSender.Failure, .notStarted)
        }
    }

    func testUnknownContextFailsClosedWithoutStarting() {
        let sender = AppleRouteSender()
        XCTAssertThrowsError(try sender.start(contextID: "dali.test.nonexistent")) { error in
            switch error as? AppleRouteSender.Failure {
            case .contextUnavailable?, .noSpeakersInContext?, .unsupported?: break
            default: XCTFail("unexpected \(error)")
            }
        }
        XCTAssertFalse(sender.isStarted)
    }

    func testSelectionIsNotFinishedWithAnEmptyRoute() {
        XCTAssertFalse(SpeakerSelectionPolicy.isFinished(remembered: ["A"], current: [], stableFor: 60))
    }

    func testSelectionFinishesAtOnceWhenEveryRememberedSpeakerIsBack() {
        XCTAssertTrue(SpeakerSelectionPolicy.isFinished(remembered: ["A", "B"], current: ["B", "A", "C"], stableFor: 0))
    }

    func testSelectionWaitsForTheRouteToSettleWhenSpeakersDiffer() {
        XCTAssertFalse(SpeakerSelectionPolicy.isFinished(remembered: ["A", "B"], current: ["A"], stableFor: 1))
        XCTAssertTrue(SpeakerSelectionPolicy.isFinished(remembered: ["A", "B"], current: ["A"],
                                                        stableFor: SpeakerSelectionPolicy.settleSeconds))
        XCTAssertTrue(SpeakerSelectionPolicy.isFinished(remembered: [], current: ["A"],
                                                        stableFor: SpeakerSelectionPolicy.settleSeconds))
    }

    func testPeakAndScaleWorkForInterleavedAndSplitBuffers() {
        for interleaved in [true, false] {
            let input = buffer(rate: 48_000, interleaved: interleaved, frames: 8)
            XCTAssertEqual(PCMLevel.peak(of: input), 0.5)
            PCMLevel.scale(input, by: 0.5)
            XCTAssertEqual(PCMLevel.peak(of: input), 0.25)
            PCMLevel.scale(input, by: 1)
            XCTAssertEqual(PCMLevel.peak(of: input), 0.25)
        }
    }

    func testTimelineRestartsOnlyAfterAGapLongerThanTheThreshold() {
        XCTAssertFalse(TimelinePolicy.needsRestart(gapSeconds: 0.02))
        XCTAssertFalse(TimelinePolicy.needsRestart(gapSeconds: TimelinePolicy.restartGapSeconds))
        XCTAssertTrue(TimelinePolicy.needsRestart(gapSeconds: 2))
    }
}
