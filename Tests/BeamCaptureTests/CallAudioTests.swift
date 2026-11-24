import XCTest
@testable import BeamCapture

final class CallAudioTests: XCTestCase {
    func testCallAppsAndTheirHelpersAreRecognised() {
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "us.zoom.xos"))
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "com.apple.FaceTime"))
        for id in ["com.apple.mobilephone", "ru.keepcoder.Telegram", "org.telegram.desktop",
                   "org.whispersystems.signal-desktop.helper.Renderer"] {
            XCTAssertTrue(CallAudio.isCallApp(bundleID: id), id)
        }
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "com.apple.avconferenced"))
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "com.tinyspeck.slackmacgap.helper.Renderer"))
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "COM.MICROSOFT.TEAMS2"))
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "com.openai.chat"))
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "com.openai.codex"))
        XCTAssertTrue(CallAudio.isCallApp(bundleID: "com.openai.codex.helper.Renderer"))
    }

    func testMusicVideoAndBrowsersStayInTheRoom() {
        for id in ["com.spotify.client", "com.google.Chrome", "com.apple.Safari", "com.apple.Music",
                   "us.zoom.xosfake", "com.apple.FaceTimeExtra", "com.openai.codexfake", "", nil] as [String?] {
            XCTAssertFalse(CallAudio.isCallApp(bundleID: id), String(describing: id))
        }
    }

    func testOnlyCallAppsAreExcluded() {
        let list = [
            CallAudio.Process(object: 10, pid: 100, bundleID: "com.spotify.client", isRunningInput: false),
            CallAudio.Process(object: 11, pid: 101, bundleID: "us.zoom.xos", isRunningInput: true),
            CallAudio.Process(object: 12, pid: 102, bundleID: "com.google.Chrome", isRunningInput: false),
            CallAudio.Process(object: 13, pid: 103, bundleID: "com.apple.avconferenced", isRunningInput: false),
        ]
        XCTAssertEqual(CallAudio.callProcessObjects(in: list), [11, 13])
    }

    func testOnlyAnExcludedCallCanDuckTheSystemMix() {
        let own = CallAudio.Process(object: 1, pid: 42, bundleID: "com.dali.app", isRunningInput: true)
        let meet = CallAudio.Process(object: 2, pid: 77, bundleID: "com.google.Chrome", isRunningInput: true)
        XCTAssertFalse(CallAudio.micInUse(in: [own], ownPID: 42))
        XCTAssertFalse(CallAudio.micInUse(in: [own, meet], ownPID: 42),
                       "Browser voice is still in the room mix; ducking it would turn down the reply itself")
        let assistant = CallAudio.Process(object: 3, pid: 78, bundleID: "com.openai.codex", isRunningInput: true)
        XCTAssertTrue(CallAudio.micInUse(in: [own, assistant], ownPID: 42))
        XCTAssertEqual(CallAudio.callProcessObjects(in: [own, meet, assistant]), [3])
    }

    func testExplicitCallCaptureIsNeverDuckedByItsOwnMicrophone() {
        let assistant = CallAudio.Process(object: 3, pid: 78, bundleID: "com.openai.codex", isRunningInput: true)
        let music = CallAudio.Process(object: 4, pid: 79, bundleID: "com.spotify.client", isRunningInput: false)
        XCTAssertFalse(CallAudio.micInUse(in: [assistant, music], ownPID: 42, source: .process(78)))
        XCTAssertTrue(CallAudio.micInUse(in: [assistant, music], ownPID: 42, source: .process(79)))
        let recorder = CallAudio.Process(object: 5, pid: 80, bundleID: "com.example.recorder", isRunningInput: true)
        XCTAssertFalse(CallAudio.micInUse(in: [recorder, music], ownPID: 42))
    }

    func testChatGPTBackgroundAudioMeterIsNotAMicrophoneCall() {
        let meter = CallAudio.Process(object: 10, pid: 70,
            bundleID: "com.openai.codex.system-audio-spectrum", isRunningInput: true)
        XCTAssertFalse(CallAudio.micInUse(in: [meter], ownPID: 42))
        let voice = CallAudio.Process(object: 11, pid: 71,
            bundleID: "com.openai.codex", isRunningInput: true)
        XCTAssertTrue(CallAudio.micInUse(in: [meter, voice], ownPID: 42))
    }

    /// A fake call: mic opens, blips closed briefly (mute toggle), then hangs up.
    func testFakeCallDucksAtOnceAndRestoresAfterHold() {
        var duck = CallDuck()
        XCTAssertEqual(duck.gain, 1)
        XCTAssertFalse(duck.update(micInUse: false, now: 0))
        XCTAssertTrue(duck.update(micInUse: true, now: 1))          // call starts
        XCTAssertEqual(duck.gain, CallDuck.duckedGain)
        XCTAssertFalse(duck.update(micInUse: false, now: 2))        // 1 s blip: still ducked
        XCTAssertFalse(duck.update(micInUse: true, now: 3))
        XCTAssertFalse(duck.update(micInUse: true, now: 9.5))       // still talking
        XCTAssertFalse(duck.update(micInUse: false, now: 10))       // hang up
        XCTAssertFalse(duck.update(micInUse: false, now: 12.4))
        XCTAssertTrue(duck.update(micInUse: false, now: 12.6))      // 3 s after last mic: restored
        XCTAssertEqual(duck.gain, 1)
        XCTAssertFalse(duck.update(micInUse: false, now: 20))
    }

    func testCallsPlayInTheRoomAndNeverDuckIt() {
        // Owner decision 2026-10-19: calls go through the room speakers, not the Mac.
        XCTAssertFalse(CallAudio.keepCallsOnMac)
        XCTAssertFalse(CallAudio.micInUseByOtherApps())
        XCTAssertFalse(CallAudio.isCallProcess(0))
    }
}
