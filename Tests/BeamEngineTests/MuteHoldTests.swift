import XCTest
@testable import BeamEngine

final class MuteHoldTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let audible = ["d": 29, "s": 14]
    private let silent = ["d": 0, "s": 0]
    private let quiet = 0.0625   // first Mac step
    private let loud = 0.5

    func testAudibleTargetsPassThroughUnchanged() {
        var hold = MuteHold()
        let result = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        XCTAssertEqual(result.targets, audible)
        XCTAssertNil(result.recheckAfter)
    }

    func testAQuietEndZeroIsHeldAtTheLastVolumeAndRechecked() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        let result = hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(result.targets, audible)
        XCTAssertEqual(result.recheckAfter!, MuteHold.holdSeconds + 0.02, accuracy: 0.001)
    }

    func testTheHeldZeroIsAppliedOnceTheHoldHasRunOut() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        _ = hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0.addingTimeInterval(0.1))
        let later = hold.resolve(targets: silent, master: 0, mutedByOther: false,
                                 now: t0.addingTimeInterval(0.1 + MuteHold.holdSeconds + 0.05))
        XCTAssertEqual(later.targets, silent)
        XCTAssertNil(later.recheckAfter)
    }

    func testABriefBrushThroughZeroNeverReachesTheSpeakers() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        let down = hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0.addingTimeInterval(0.05))
        let up = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0.addingTimeInterval(0.4))
        XCTAssertEqual(down.targets, audible)
        XCTAssertEqual(up.targets, audible)
    }

    func testAMuteFromALouderLevelIsAppliedAtOnce() {
        var hold = MuteHold()
        _ = hold.resolve(targets: ["d": 60, "s": 50], master: loud, mutedByOther: false, now: t0)
        let result = hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(result.targets, silent)
        XCTAssertNil(result.recheckAfter)
    }

    func testAZeroThatIsNotTheMacVolumeIsNeverHeld() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        let cut = hold.resolve(targets: silent, master: quiet, mutedByOther: true, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(cut.targets, silent)
        XCTAssertNil(cut.recheckAfter)
    }

    func testStartingMutedHasNothingToHold() {
        var hold = MuteHold()
        let result = hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0)
        XCTAssertEqual(result.targets, silent)
        XCTAssertNil(result.recheckAfter)
    }

    func testAMuteAfterSlidersWereAtZeroDoesNotRaiseTheSpeakers() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        // Sliders pulled to zero with the Mac volume still up: that is what the room last sent.
        _ = hold.resolve(targets: silent, master: quiet, mutedByOther: false, now: t0.addingTimeInterval(1))
        let mute = hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0.addingTimeInterval(2))
        XCTAssertEqual(mute.targets, silent)
        XCTAssertNil(mute.recheckAfter)
    }

    func testABrowserCutReleasedWhileTheMacIsMutedDoesNotRaiseTheSpeakers() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        _ = hold.resolve(targets: silent, master: 0, mutedByOther: true, now: t0.addingTimeInterval(1))   // cut
        let released = hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0.addingTimeInterval(2))
        XCTAssertEqual(released.targets, silent)
    }

    func testResetForgetsTheLastAudibleVolume() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        hold.reset()
        XCTAssertEqual(hold.resolve(targets: silent, master: 0, mutedByOther: false, now: t0).targets, silent)
    }

    func testANewSpeakerWithNoHistoryIsHeldAtZero() {
        var hold = MuteHold()
        _ = hold.resolve(targets: audible, master: quiet, mutedByOther: false, now: t0)
        let result = hold.resolve(targets: ["d": 0, "s": 0, "x": 0], master: 0, mutedByOther: false,
                                  now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(result.targets, ["d": 29, "s": 14, "x": 0])
    }
}
