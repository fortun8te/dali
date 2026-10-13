import XCTest
@testable import BeamEngine

/// Michael's physical listening targets (13 Oct 2026, low end raised the same evening): the DALI speaker ("MICHAEL D")
/// needs this much more than the other speaker ("MICHAEL S", always 100 %) at each
/// macOS volume step. They are evidence for the curve; the tests pin that the code
/// applies exactly these values.
final class SpeakerLevelCurveTests: XCTestCase {
    private let targets: [(step: Int, percent: Double)] =
        [(1, 250), (2, 205), (3, 182), (4, 156), (5, 143), (6, 136), (7, 136)]

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
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: 1.0 / 64), 2.5, accuracy: 1e-12)
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: 0), 2.5, accuracy: 1e-12)
    }

    func testCurveIsSmoothAndNeverOvershootsItsNeighbours() {
        var previous = SpeakerLevelCurve.michaelD.gain(atMaster: 0)
        var largestJump = 0.0
        for tick in 0...1_600 {
            let gain = SpeakerLevelCurve.michaelD.gain(atMaster: Double(tick) / 1_600)
            XCTAssertLessThanOrEqual(gain, previous + 1e-12, "falls monotonically, never rises again")
            XCTAssertGreaterThanOrEqual(gain, 1.36 - 1e-12)
            XCTAssertLessThanOrEqual(gain, 2.5 + 1e-12)
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
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: .nan), 2.5, accuracy: 1e-12)
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: 5), 1.36, accuracy: 1e-12)
        XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: -1), 2.5, accuracy: 1e-12)
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
                       "Step 1 250% \u{00B7} 2 205% \u{00B7} 3 182% \u{00B7} 4 156% \u{00B7} 5 143% \u{00B7} 6 136% \u{00B7} 7 136% and up")
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
            1: (36, 14), 2: (48, 23), 3: (56, 31), 4: (59, 38), 5: (63, 44), 6: (68, 50), 7: (76, 56), 8: (84, 62),
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

    // MARK: desk-check of the whole curve (no listening)

    /// Fine scan across the entire Mac volume range, including every ⌥⇧ quarter-step
    /// (master = n/64) and values between them.
    private let scan = (0...6_400).map { Double($0) / 6_400 }

    func testReceiverCommandNeverDropsAsTheMacVolumeRisesAndNeverJumps() {
        let dali = RoomVolumeSpeaker(id: "D", slider: 100, gain: 1.3436, curve: .michaelD)
        let reference = RoomVolumeSpeaker(id: "S", slider: 100)
        for ceiling in [20.0, 40, 100] {
            var previousD = 0, previousS = 0
            var largestStep = 0
            for master in scan {
                let plan = RoomVolumePolicy.plan(speakers: [dali, reference], ceiling: ceiling, systemMaster: master)
                let d = plan.hardware["D"]!, s = plan.hardware["S"]!
                XCTAssertGreaterThanOrEqual(d, previousD, "D never falls as the Mac volume rises (ceiling \(ceiling), master \(master))")
                XCTAssertGreaterThanOrEqual(s, previousS)
                XCTAssertLessThanOrEqual(d, Int(ceiling.rounded()))
                XCTAssertLessThanOrEqual(s, Int(ceiling.rounded()))
                largestStep = max(largestStep, d - previousD)
                previousD = d; previousS = s
            }
            // 1/6400 of the Mac range is a tiny move; one command step is the most it may cause.
            XCTAssertLessThanOrEqual(largestStep, 1, "no jump in the receiver command (ceiling \(ceiling))")
        }
    }

    func testUnroundedLevelledLoudnessIsMonotonicAndContinuousThroughTheCap() {
        // The pre-rounding command D(m) = min(100 * m^0.7 * curve(m), 100).
        var previous = 0.0
        var capReachedAt: Double?
        for master in scan {
            let d = min(100 * pow(master, 0.7) * SpeakerLevelCurve.michaelD.gain(atMaster: master), 100)
            XCTAssertGreaterThanOrEqual(d, previous - 1e-9, "master \(master)")
            // Below one quarter-step the V1 master^0.7 law itself is steep (not the curve); above it, smooth.
            if master >= 1.0 / 64 { XCTAssertLessThan(d - previous, 0.2, "continuous at master \(master)") }
            if d >= 100, capReachedAt == nil { capReachedAt = master }
            previous = d
        }
        // The cap is first reached between step 10 and 11 and is a flat top, not a jump.
        let reached = (capReachedAt ?? 0) * 16
        XCTAssertGreaterThan(reached, 10)
        XCTAssertLessThan(reached, 11)
    }

    func testFinalSlopeIsGentleThroughTheCurvesFlatTail() {
        for step in 6...16 {
            XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: master(step: step)), 1.36, accuracy: 1e-12)
        }
        // Between steps 6 and 16 nothing moves at all, so there is no hidden bump.
        for master in stride(from: master(step: 6), through: 1.0, by: 0.001) {
            XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: master), 1.36, accuracy: 1e-12)
        }
    }

    func testMacVolumeStepsAndQuarterStepsMapToTheRightPointOnTheCurve() {
        // macOS volume: 16 whole steps (n/16); with Option-Shift each step has four quarter-steps (n/64).
        XCTAssertEqual(SpeakerLevelCurve.stepsPerFullScale, 16)
        for quarter in 0...64 {
            let master = Double(quarter) / 64
            let step = master * 16
            XCTAssertEqual(step, Double(quarter) / 4, "quarter-step \(quarter) is exactly step \(Double(quarter) / 4)")
            let gain = SpeakerLevelCurve.michaelD.gain(atMaster: master)
            if quarter % 4 == 0, (1...7).contains(quarter / 4) {
                XCTAssertEqual(gain * 100, targets[quarter / 4 - 1].percent, accuracy: 1e-9, "whole step \(quarter / 4)")
            }
        }
        // Whole quarter-steps between 1 and 2 fall strictly between 250 and 205.
        for quarter in 5...7 {
            let gain = SpeakerLevelCurve.michaelD.gain(atMaster: Double(quarter) / 64) * 100
            XCTAssertLessThan(gain, 250); XCTAssertGreaterThan(gain, 205)
        }
        // Below step 1 (quarter-steps 1...3) the gain holds the step-1 value.
        for quarter in 1...3 {
            XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: Double(quarter) / 64), 2.5, accuracy: 1e-12)
        }
        // A HAL scalar a hair off the exact step (single-precision rounding) changes nothing audible.
        for step in 1...16 {
            let exact = SpeakerLevelCurve.michaelD.gain(atMaster: master(step: step))
            for wobble in [-1e-6, 1e-6] {
                XCTAssertEqual(SpeakerLevelCurve.michaelD.gain(atMaster: master(step: step) + wobble), exact, accuracy: 1e-4)
            }
        }
    }

    func testZeroMuteAndTinyVolumesAreHandled() {
        let dali = RoomVolumeSpeaker(id: "D", slider: 100, curve: .michaelD)
        let reference = RoomVolumeSpeaker(id: "S", slider: 100)
        let zero = RoomVolumePolicy.plan(speakers: [dali, reference], ceiling: 100, systemMaster: 0)
        XCTAssertEqual(zero.hardware, ["D": 0, "S": 0])
        XCTAssertEqual(zero.pcmGain, 0, "master 0 mutes the PCM as well")
        let muted = RoomVolumePolicy.plan(speakers: [dali, reference], ceiling: 100, systemMaster: 0.5, muted: true)
        XCTAssertEqual(muted.hardware, ["D": 0, "S": 0])
        XCTAssertEqual(muted.pcmGain, 0)
        // The smallest non-zero scalar is audible-but-tiny, not muted and not loud.
        let tiny = RoomVolumePolicy.plan(speakers: [dali, reference], ceiling: 100, systemMaster: 1.0 / 64)
        XCTAssertGreaterThanOrEqual(tiny.hardware["D"]!, tiny.hardware["S"]!)
        XCTAssertLessThanOrEqual(tiny.hardware["D"]!, 14, "one quarter-step above mute: 14 of 100")
        XCTAssertEqual(tiny.pcmGain, 1)
        // Slider at zero stays silent whatever the curve says.
        var quiet = dali; quiet.slider = 0
        XCTAssertEqual(RoomVolumePolicy.plan(speakers: [quiet], ceiling: 100, systemMaster: 1.0 / 16).hardware["D"], 0)
    }

    func testNoClippingOrOverflowForAnyCurveItIsGiven() {
        // Extreme but valid saved curves and hostile inputs: the command is always an integer in 0...ceiling.
        let curves: [[Double]] = [[400, 400, 400], [25, 400, 25, 400, 25], [25], [400], Array(repeating: 400, count: 16),
                                  [250, 205, 182, 156, 143, 136, 136, 300, 100]]
        for percent in curves {
            let curve = SpeakerLevelCurve(percentPerStep: percent)!
            let low = (percent.min() ?? 25) / 100, high = (percent.max() ?? 400) / 100
            for master in scan {
                let gain = curve.gain(atMaster: master)
                XCTAssertGreaterThanOrEqual(gain, low - 1e-9, "no undershoot below the lowest value")
                XCTAssertLessThanOrEqual(gain, high + 1e-9, "no overshoot above the highest value")
                for slider in [0.0, 50, 100] {
                    for ceiling in [1.0, 20, 100] {
                        let speaker = RoomVolumeSpeaker(id: "x", slider: slider, curve: curve)
                        let value = RoomVolumePolicy.plan(speakers: [speaker], ceiling: ceiling, systemMaster: master).hardware["x"]!
                        XCTAssertTrue((0...Int(ceiling)).contains(value))
                    }
                }
            }
        }
        for hostile in [Double.nan, .infinity, -.infinity, -3, 1e300] {
            let plan = RoomVolumePolicy.plan(speakers: [RoomVolumeSpeaker(id: "x", slider: 100, curve: .michaelD)],
                                             ceiling: 100, systemMaster: hostile)
            XCTAssertTrue((0...100).contains(plan.hardware["x"]!))
        }
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
