import XCTest
@testable import BeamEngine

final class RoomVolumePolicyTests: XCTestCase {
    private let room = [RoomVolumeSpeaker(id: "front", slider: 100, gain: 1.5),
                        RoomVolumeSpeaker(id: "back", slider: 84)]

    // Independent baseline copied from preserved V1 effectiveVolume arithmetic.
    private func v1Volume(_ speaker: RoomVolumeSpeaker, master: Double?, ceiling: Double) -> Int {
        guard speaker.enabled else { return 0 }
        let base = master.map { speaker.slider * pow($0, 0.7) * (ceiling / 100) } ?? speaker.slider
        return Int(max(min(min(base * speaker.gain, 100), ceiling), 0).rounded())
    }

    func testMatchesPreservedV1ReceiverCommandsAcrossMasterAndCalibration() {
        for ceiling in [20.0, 40, 40.6, 100] {
            for slider in [0.0, 1, 50, 84, 100] {
                for gain in [0.25, 1, 1.5, 4.0] {
                    let speaker = RoomVolumeSpeaker(id: "speaker", slider: slider, gain: gain)
                    for master in [0.001, 0.01, 1.0 / 16, 0.18, 0.31, 0.5, 0.68, 0.99, 1] {
                        let plan = RoomVolumePolicy.plan(speakers: [speaker], ceiling: ceiling, systemMaster: master)
                        XCTAssertEqual(plan.hardware["speaker"], v1Volume(speaker, master: master, ceiling: ceiling))
                        XCTAssertEqual(plan.pcmGain, 1, "V1 controls receiver volume, with no software attenuation")
                    }
                }
            }
        }
    }

    func testLowestVolumeKeyUsesV1ReceiverLevelInsteadOfFullReference() {
        let speakers = [RoomVolumeSpeaker(id: "front", slider: 100), RoomVolumeSpeaker(id: "back", slider: 100)]
        let plan = RoomVolumePolicy.plan(speakers: speakers, ceiling: 100, systemMaster: 1.0 / 16)
        XCTAssertEqual(plan.hardware, ["front": 14, "back": 14])
        XCTAssertEqual(plan.pcmGain, 1)
    }

    func testHardwareCommandsRiseMonotonicallyAndRespectV1Caps() {
        for ceiling in [20.0, 40, 100] {
            var previous = ["front": 0, "back": 0]
            for step in 0...1_000 {
                let plan = RoomVolumePolicy.plan(speakers: room, ceiling: ceiling, systemMaster: Double(step) / 1_000)
                for speaker in room {
                    let volume = plan.hardware[speaker.id]!
                    XCTAssertGreaterThanOrEqual(volume, previous[speaker.id]!)
                    XCTAssertLessThanOrEqual(volume, Int(ceiling.rounded()))
                    previous[speaker.id] = volume
                }
            }
        }
    }

    func testPartnerAndMasterAreUnaffectedByOneSpeakerAdjustmentOrMute() {
        let baseline = RoomVolumePolicy.plan(speakers: room, ceiling: 100, systemMaster: 0.25)
        var changed = room
        changed[0].slider = 25
        changed[0].gain = 4
        changed[0].enabled = false
        let off = RoomVolumePolicy.plan(speakers: changed, ceiling: 100, systemMaster: 0.25)
        XCTAssertEqual(off.hardware["front"], 0)
        XCTAssertEqual(off.hardware["back"], baseline.hardware["back"])
        XCTAssertEqual(off.pcmGain, baseline.pcmGain)
    }

    func testAppSpotifyAndPlayerKeepV1AbsoluteSliderSemantics() {
        for ceiling in [20.0, 40, 40.6, 100] {
            let plan = RoomVolumePolicy.plan(speakers: room, ceiling: ceiling)
            XCTAssertEqual(plan.pcmGain, 1)
            for speaker in room {
                XCTAssertEqual(plan.hardware[speaker.id], v1Volume(speaker, master: nil, ceiling: ceiling))
            }
        }
    }

    func testInvalidMasterZeroAndCutSilencePCMAndReceivers() {
        for master in [Double.nan, .infinity, -.infinity, -1, 0] {
            let plan = RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: master)
            XCTAssertEqual(plan.pcmGain, 0)
            XCTAssertTrue(plan.hardware.values.allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 2),
                       RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 1))
        let cut = RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 0.5, muted: true)
        XCTAssertEqual(cut.pcmGain, 0)
        XCTAssertTrue(cut.hardware.values.allSatisfy { $0 == 0 })
        let invalid = RoomVolumePolicy.plan(speakers: [RoomVolumeSpeaker(id: "bad", slider: .nan)], ceiling: .infinity, systemMaster: .nan)
        XCTAssertEqual(invalid.hardware["bad"], 0)
        XCTAssertEqual(invalid.pcmGain, 0)
    }
}
