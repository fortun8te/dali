import XCTest
@testable import BeamEngine

final class RoomVolumePolicyTests: XCTestCase {
    private let room = [RoomVolumeSpeaker(id: "front", slider: 50),
                        RoomVolumeSpeaker(id: "back", slider: 40)]

    func testBothSpeakersAt100RemainQuietAtLowestMasterSettings() {
        let speakers = [RoomVolumeSpeaker(id: "front", slider: 100),
                        RoomVolumeSpeaker(id: "back", slider: 100)]
        for ceiling in [20.0, 40, 100] {
            for (master, expectedGain) in [(0.01, 0.0001), (1.0 / 16, 0.00390625)] {
                let plan = RoomVolumePolicy.plan(speakers: speakers, ceiling: ceiling,
                                                 systemMaster: master)
                XCTAssertEqual(plan.pcmGain, expectedGain, accuracy: 1e-12)
                XCTAssertEqual(plan.hardware, ["front": Int(ceiling), "back": Int(ceiling)])
            }
        }
    }

    func testFrontSliderAndGainCannotChangeCommonMasterOrBackSpeaker() {
        for ceiling in [20.0, 40, 100] {
            for master in [0.01, 1.0 / 16, 0.5, 1] {
                let baseline = RoomVolumePolicy.plan(speakers: room, ceiling: ceiling,
                                                     systemMaster: master)
                for slider in [0.0, 10, 50, 100] {
                    for gain in [0.25, 1, 4.0] {
                        var speakers = room
                        speakers[0].slider = slider
                        speakers[0].gain = gain
                        let plan = RoomVolumePolicy.plan(speakers: speakers, ceiling: ceiling,
                                                         systemMaster: master)
                        XCTAssertEqual(plan.pcmGain, baseline.pcmGain, accuracy: 1e-12)
                        XCTAssertEqual(plan.hardware["back"], baseline.hardware["back"])
                    }
                }
            }
        }
    }

    func testMasterSweepKeepsReceiverReferencesAndCalibrationFixed() {
        let reference = RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 1)
        XCTAssertEqual(reference.hardware, ["front": 20, "back": 16])
        for step in 1...1_000 {
            let plan = RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: Double(step) / 1_000)
            XCTAssertEqual(plan.hardware, reference.hardware, "Master changes must not issue different receiver commands")
            XCTAssertEqual(plan.hardware["front"]! - plan.hardware["back"]!, 4)
            XCTAssertGreaterThan(plan.pcmGain, 0, "Ordinary low master must not silence the room")
        }
    }

    func testFront100Back80KeepsBalanceWhileMasterChangesRoomLoudness() {
        let speakers = [RoomVolumeSpeaker(id: "front", slider: 100),
                        RoomVolumeSpeaker(id: "back", slider: 80)]
        for ceiling in [20.0, 40, 100] {
            let full = RoomVolumePolicy.plan(speakers: speakers, ceiling: ceiling, systemMaster: 1)
            XCTAssertEqual(full.hardware, ["front": Int(ceiling), "back": Int(ceiling * 0.8)])
            var previousGain = 0.0
            for step in 1...1_000 {
                let plan = RoomVolumePolicy.plan(speakers: speakers, ceiling: ceiling,
                                                 systemMaster: Double(step) / 1_000)
                XCTAssertEqual(plan.hardware, full.hardware)
                XCTAssertGreaterThan(plan.pcmGain, previousGain)
                previousGain = plan.pcmGain
            }
            XCTAssertEqual(previousGain, 1, accuracy: 1e-12)
            let mute = RoomVolumePolicy.plan(speakers: speakers, ceiling: ceiling, systemMaster: 0)
            XCTAssertEqual(mute.pcmGain, 0)
            XCTAssertEqual(mute.hardware, ["front": 0, "back": 0])
        }
    }

    func testSoftwareMasterUsesCommonQuadraticAmplitudeAtEveryCeiling() {
        for ceiling in [20.0, 40, 100] {
            for (master, expectedGain) in [(0.01, 0.0001), (0.0625, 0.00390625),
                                           (0.25, 0.0625), (0.5, 0.25), (1, 1.0)] {
                let gain = RoomVolumePolicy.plan(speakers: room, ceiling: ceiling, systemMaster: master).pcmGain
                XCTAssertEqual(gain, expectedGain, accuracy: 1e-12)
            }
        }
    }

    func testMuteAndContinuousMonotonicLowEnd() {
        var previous = 0.0
        for step in 0...10_000 {
            let gain = RoomVolumePolicy.softwareGain(master: Double(step) / 10_000)
            XCTAssertGreaterThanOrEqual(gain, previous)
            XCTAssertLessThanOrEqual(gain, 1)
            previous = gain
        }
        XCTAssertEqual(RoomVolumePolicy.softwareGain(master: 0), 0)
        XCTAssertLessThan(RoomVolumePolicy.softwareGain(master: 1e-9), 1e-12)
        let left = RoomVolumePolicy.softwareGain(master: 1.0 / 16 - 1e-9)
        let right = RoomVolumePolicy.softwareGain(master: 1.0 / 16 + 1e-9)
        XCTAssertEqual(left, right, accuracy: 1e-7)
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 0).hardware,
                       ["front": 0, "back": 0])
    }

    func testDisabledHottestMemberDoesNotTurnUpPartner() {
        var speakers = room
        let full = RoomVolumePolicy.plan(speakers: speakers, ceiling: 40, systemMaster: 0.25)
        speakers[0].enabled = false
        let off = RoomVolumePolicy.plan(speakers: speakers, ceiling: 40, systemMaster: 0.25)
        XCTAssertEqual(off.pcmGain, full.pcmGain)
        XCTAssertEqual(off.hardware["back"], full.hardware["back"])
        XCTAssertEqual(off.hardware["front"], 0)
    }

    func testFixedReferencesPreserveSavedFullMasterCapsAndFractionalCeiling() {
        let loud = [RoomVolumeSpeaker(id: "front", slider: 100, gain: 2),
                    RoomVolumeSpeaker(id: "back", slider: 100, gain: 1.9)]
        let plan = RoomVolumePolicy.plan(speakers: loud, ceiling: 40.6)
        XCTAssertEqual(plan.hardware, ["front": 40, "back": 40])
        let migrated = RoomVolumePolicy.plan(speakers: [RoomVolumeSpeaker(id: "front", slider: 100, gain: 4),
                                                          RoomVolumeSpeaker(id: "back", slider: 50)],
                                               ceiling: 40, systemMaster: 1)
        XCTAssertEqual(migrated.hardware, ["front": 40, "back": 20])
        for gain in [0.25, 1, 2, 4.0] {
            let extreme = RoomVolumePolicy.plan(speakers: [RoomVolumeSpeaker(id: "a", slider: 100, gain: gain),
                                                          RoomVolumeSpeaker(id: "b", slider: 1)], ceiling: 40.6)
            XCTAssertTrue(extreme.hardware.values.allSatisfy { $0 >= 1 && $0 <= 40 })
        }
    }

    func testInvalidInputAndExplicitCutAreSafe() {
        for master in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(RoomVolumePolicy.softwareGain(master: master), 0)
            let plan = RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: master)
            XCTAssertEqual(plan.pcmGain, 0)
            XCTAssertTrue(plan.hardware.values.allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(RoomVolumePolicy.softwareGain(master: 2), 1)
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 2),
                       RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 1))
        let invalid = RoomVolumePolicy.plan(speakers: [RoomVolumeSpeaker(id: "a", slider: .nan)],
                                             ceiling: .infinity, systemMaster: .nan)
        XCTAssertEqual(invalid.hardware["a"], 0)
        XCTAssertEqual(invalid.pcmGain, 0)
        let cut = RoomVolumePolicy.plan(speakers: room, ceiling: 40, systemMaster: 0.5, muted: true)
        XCTAssertEqual(cut.pcmGain, 0)
        XCTAssertTrue(cut.hardware.values.allSatisfy { $0 == 0 })
    }
}
