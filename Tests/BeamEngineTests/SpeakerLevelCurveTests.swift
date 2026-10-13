import XCTest
@testable import BeamEngine

/// Michael's physical listening targets (13 Oct 2026): the DALI speaker ("MICHAEL D")
/// needs this much more than the other speaker ("MICHAEL S", always 100 %) at each
/// macOS volume step. They are evidence for the curve; the tests pin that the code
/// applies exactly these values.
final class SpeakerLevelCurveTests: XCTestCase {
    private let targets: [(step: Int, percent: Double)] =
        [(1, 220), (2, 186), (3, 171), (4, 149), (5, 140), (6, 136), (7, 136)]

    private func master(step: Int) -> Double { Double(step) / 16 }

    func testEachMacVolumeStepGetsExactlyTheListeningTarget() {
        for (step, percent) in targets {
            XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: master(step: step)) * 100, percent,
                           accuracy: 1e-9, "step \(step)")
        }
    }

    func testHigherStepsStayAt136PercentAndLowerThanStepOneHoldsStepOne() {
        for step in 8...16 {
            XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: master(step: step)), 1.36, accuracy: 1e-12, "step \(step)")
        }
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: 1.0 / 64), 2.2, accuracy: 1e-12)
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: 0), 2.2, accuracy: 1e-12)
    }

    func testCurveIsSmoothAndNeverOvershootsItsNeighbours() {
        var previous = SpeakerLevelCurve.michaelD.gain(atMaster: 0)
        var largestJump = 0.0
        for tick in 0...1_600 {
            let gain = SpeakerLevelCurve.michaelD.gain(atMaster: Double(tick) / 1_600)
            XCTAssertLessThanOrEqual(gain, previous + 1e-12, "falls monotonically, never rises again")
            XCTAssertGreaterThanOrEqual(gain, 1.36 - 1e-12)
            XCTAssertLessThanOrEqual(gain, 2.2 + 1e-12)
            largestJump = max(largestJump, previous - gain)
            previous = gain
        }
        // One hundredth of a Mac volume step moves the gain by well under a percent.
        XCTAssertLessThan(largestJump, 0.01)
        // Midway between steps sits between the two targets (no hard jump at a step).
        for (a, b) in zip(targets, targets.dropFirst()) {
            let mid = SpeakerLevelCurve.michaelD.gain(atMaster: (master(step: a.step) + master(step: b.step)) / 2) * 100
            XCTAssertLessThanOrEqual(mid, a.percent + 1e-9)
            XCTAssertGreaterThanOrEqual(mid, b.percent - 1e-9)
        }
    }

    func testBadInputFallsBackSafely() {
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: .nan), 2.2, accuracy: 1e-12)
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: 5), 1.36, accuracy: 1e-12)
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: -1), 2.2, accuracy: 1e-12)
        XCTAssertNil(SpeakerLevelCurve(percentPerStep: []))
        XCTAssertNil(SpeakerLevelCurve(percentPerStep: [100, .nan]))
        XCTAssertNil(SpeakerLevelCurve(percentPerStep: [5]), "below the 0.25x safety floor")
        XCTAssertNil(SpeakerLevelCurve(percentPerStep: [900]))
    }

    func testBuiltInCurveBelongsToTheDaliSpeakerOnly() {
        XCTAssertEqual(SpeakerLevelCurve.builtIn(forSpeakerNamed: "MICHAEL D"), .michaelD)
        XCTAssertEqual(SpeakerLevelCurve.builtIn(forSpeakerNamed: "michael d"), .michaelD)
        XCTAssertNil(SpeakerLevelCurve.builtIn(forSpeakerNamed: "MICHAEL S"))
        XCTAssertNil(SpeakerLevelCurve.builtIn(forSpeakerNamed: "HomePod Keuken"))
    }

    func testStepSummaryShowsTheCurve() {
        XCTAssertEqual(SpeakerLevelCurve.michaelD.stepSummary,
                       "Step 1 220% \u{00B7} 2 186% \u{00B7} 3 171% \u{00B7} 4 149% \u{00B7} 5 140% \u{00B7} 6 136% \u{00B7} 7 136% and up")
    }

    // MARK: effective gain through the production policy

    func testPolicyAppliesTheTargetGainRelativeToTheReferenceSpeakerAtEveryStep() {
        let dali = RoomVolumeSpeaker(id: "D", slider: 100, gain: 1.3436, curve: .michaelD)
        let reference = RoomVolumeSpeaker(id: "S", slider: 100)
        for (step, percent) in targets {
            let m = master(step: step)
            XCTAssertEqual(RoomVolumePolicy.effectiveGain(for: dali, systemMaster: m) * 100, percent,
                           accuracy: 1e-9, "effective gain, step \(step)")
            XCTAssertEqual(RoomVolumePolicy.effectiveGain(for: reference, systemMaster: m), 1, "reference stays 100%")

            // Receiver commands: ceiling 100, both sliders 100. Command rounding is
            // one receiver step, so the ratio is checked against the unrounded V1 value.
            let plan = RoomVolumePolicy.plan(speakers: [dali, reference], ceiling: 100, systemMaster: m)
            let v1Reference = 100 * pow(m, 0.7)
            XCTAssertEqual(plan.hardware["S"], Int(v1Reference.rounded()), "V1 response kept for the reference speaker")
            XCTAssertEqual(plan.hardware["D"], Int(min(v1Reference * percent / 100, 100).rounded()), "step \(step)")
            XCTAssertEqual(plan.pcmGain, 1)
        }
    }

    func testCommandsAtEveryStepForTheRealRoom() {
        // Slider 100/100, volume limit 100 (the saved settings), by Mac volume step 1...16.
        // These S values match what the engine reported live on 13 Oct (14, 23, 31, 38, 44, 50, 56).
        let dali = RoomVolumeSpeaker(id: "D", slider: 100, gain: 1.3436, curve: .michaelD)
        let reference = RoomVolumeSpeaker(id: "S", slider: 100)
        // Independently computed: round(min(100 * (step/16)^0.7 * curve, 100)). From step 11
        // up the DALI speaker is at the receiver's 100 % ceiling, so the gap narrows by necessity.
        let expected: [Int: (d: Int, s: Int)] = [
            1: (32, 14), 2: (43, 23), 3: (53, 31), 4: (56, 38), 5: (62, 44), 6: (68, 50), 7: (76, 56), 8: (84, 62),
            9: (91, 67), 10: (98, 72), 11: (100, 77), 12: (100, 82), 13: (100, 86), 14: (100, 91), 15: (100, 96), 16: (100, 100)
        ]
        XCTAssertEqual(expected.count, 16)
        for (step, want) in expected {
            let plan = RoomVolumePolicy.plan(speakers: [dali, reference], ceiling: 100, systemMaster: master(step: step))
            XCTAssertEqual(plan.hardware["D"], want.d, "D at step \(step)")
            XCTAssertEqual(plan.hardware["S"], want.s, "S at step \(step)")
        }
    }

    func testCurveReplacesTheSavedFixedGainOnlyWhileTheMacVolumeDrivesTheRoom() {
        let dali = RoomVolumeSpeaker(id: "D", slider: 100, gain: 1.3436, curve: .michaelD)
        XCTAssertEqual(RoomVolumePolicy.effectiveGain(for: dali, systemMaster: nil), 1.3436, accuracy: 1e-12,
                       "app/Spotify/player modes have no Mac master: the saved fixed gain applies as before")
        var withoutCurve = dali
        withoutCurve.curve = nil
        XCTAssertEqual(RoomVolumePolicy.effectiveGain(for: withoutCurve, systemMaster: 1.0 / 16), 1.3436, accuracy: 1e-12,
                       "curve switched off: the fixed gain applies at every volume")
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: [withoutCurve], ceiling: 100, systemMaster: 0.5).hardware["D"],
                       Int(min(100 * pow(0.5, 0.7) * 1.3436, 100).rounded()))
    }

    func testMuteDisableAndCeilingStillWinOverTheCurve() {
        let dali = RoomVolumeSpeaker(id: "D", slider: 100, curve: .michaelD)
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: [dali], ceiling: 100, systemMaster: 0).hardware["D"], 0)
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: [dali], ceiling: 100, systemMaster: 0.25, muted: true).hardware["D"], 0)
        var off = dali; off.enabled = false
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: [off], ceiling: 100, systemMaster: 0.25).hardware["D"], 0)
        XCTAssertLessThanOrEqual(RoomVolumePolicy.plan(speakers: [dali], ceiling: 20, systemMaster: 1.0 / 16).hardware["D"] ?? 99, 20)
    }

    // MARK: saved preferences are read, never rewritten

    private func withDefaults(_ test: (UserDefaults) -> Void) {
        let suite = "DALI.tests.speakers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        test(defaults)
    }

    func testReadingTheCurveKeepsSavedGainsAndVolumesUntouched() {
        withDefaults { defaults in
            let saved: [String: Any] = [
                "dali.gain.MICHAEL D": 1.343581627155172, "dali.gain.MICHAEL S": 1.0,
                "dali.vol.MICHAEL D": 100.0, "dali.vol.MICHAEL S": 100.0, "dali.volumeLimit": 100.0
            ]
            for (key, value) in saved { defaults.set(value, forKey: key) }
            let before = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("dali.") }.mapValues { "\($0)" }
            let preferences = SpeakerPreferences(defaults: defaults)
            XCTAssertEqual(preferences.levelCurve(name: "MICHAEL D"), .michaelD)
            XCTAssertTrue(preferences.levelCurveActive(name: "MICHAEL D"))
            XCTAssertNil(preferences.levelCurve(name: "MICHAEL S"))
            XCTAssertEqual(preferences.gain(name: "MICHAEL D"), 1.343581627155172, "fixed gain still readable for the switch-off path")
            let after = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("dali.") }.mapValues { "\($0)" }
            XCTAssertEqual(before, after, "reading never writes, resets or erases a dali.* setting")
        }
    }

    func testCurveCanBeSwitchedOffAndOverriddenWithoutLosingTheFixedGain() {
        withDefaults { defaults in
            defaults.set(1.5, forKey: "dali.gain.Desk")
            defaults.set(false, forKey: "dali.curveOn.Desk")
            defaults.set([200.0, 150.0, 120.0], forKey: "dali.curve.Desk")
            let preferences = SpeakerPreferences(defaults: defaults)
            XCTAssertFalse(preferences.levelCurveActive(name: "Desk"))
            let curve = preferences.levelCurve(name: "Desk")
            XCTAssertEqual(curve?.gain(atMaster: 2.0 / 16) ?? 0, 1.5, accuracy: 1e-12)
            XCTAssertEqual(curve?.gain(atMaster: 1) ?? 0, 1.2, accuracy: 1e-12, "held after the last saved step")
            XCTAssertEqual(preferences.gain(name: "Desk"), 1.5)
            defaults.set([5.0], forKey: "dali.curve.Desk")
            XCTAssertNil(SpeakerPreferences(defaults: defaults).levelCurve(name: "Desk"), "invalid override ignored")
        }
    }
}
