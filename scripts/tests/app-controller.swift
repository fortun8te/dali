import Foundation
import AVFoundation
import Synchronization

private final class RecoveryFixtureTap: CaptureTap, @unchecked Sendable {
    var clockAnchored = true
    var overrunCount = 0
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onInvalidated: ((String) -> Void)?
    func start(muteLocal: Bool, source: ProcessTap.Source) throws {}
    func stop() {}
    func emitSilence() { emit(0) }
    func emit(_ sample: Float) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
                                   channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
        buffer.frameLength = 441
        for channel in 0..<2 { for frame in 0..<441 { buffer.floatChannelData![channel][frame] = sample } }
        onBuffer?(buffer)
    }
}

// Only the hardware boundary is a fixture. DALIStore, RoomVolumePolicy, and
// RoomVolumeCoordinator below are the same production sources built by the app.
private actor RecordedVolumes {
    struct Write: Equatable, Sendable {
        let id: String
        let value: Int
    }
    private var writes: [Write] = []
    private var heldReply: CheckedContinuation<RoomVolumeWriteResult, Never>?
    private var holdNext = false
    private var receivedAt: [ContinuousClock.Instant] = []

    func send(id: String, value: Int) async -> RoomVolumeWriteResult {
        writes.append(Write(id: id, value: value))
        receivedAt.append(ContinuousClock.now)
        if holdNext {
            holdNext = false
            return await withCheckedContinuation { heldReply = $0 }
        }
        return .applied
    }
    func snapshot() -> [Write] { writes }
    func times() -> [ContinuousClock.Instant] { receivedAt }
    func pauseNextReply() { holdNext = true }
    func releaseReply() {
        heldReply?.resume(returning: .applied)
        heldReply = nil
    }
}

@main
struct AppControllerRegression {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ reason: String) throws {
            checks += 1
            guard value() else {
                throw NSError(domain: "DALI.AppControllerRegression", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "FAIL: \(reason)"])
            }
        }
        func waitUntil(_ condition: @escaping () async -> Bool, _ reason: String) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await condition()), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let passed = await condition()
            try expect(passed, reason)
        }
        let suite = "DALI.AppControllerTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for version in ["v2", "v3", "v4", "v5", "v8", "v9", "v10", "volumeLimit20"] {
            defaults.set(true, forKey: "dali.migrated.\(version)")
        }
        defaults.set("Front fixture", forKey: "dali.frontName")
        defaults.set("Back fixture", forKey: "dali.backName")
        defaults.set(20.0, forKey: "dali.volumeLimit")
        defaults.set(80.0, forKey: "dali.vol.Front fixture")
        defaults.set(40.0, forKey: "dali.vol.Back fixture")
        defaults.set(1.0, forKey: "dali.gain.Front fixture")
        defaults.set(75.0, forKey: "dali.delayTrimMs")
        defaults.set("mirror", forKey: "dali.mode")
        defaults.set("keep", forKey: "unrelated.preference")

        // Exercise the production controller's restart budget with the real
        // CaptureController and fake hardware, including rebuild clock resets.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dali-recovery-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pipe = directory.appendingPathComponent("capture.pipe").path
            try expect(mkfifo(pipe, 0o600) == 0, "recovery fixture creates isolated FIFO")
            let reader = open(pipe, O_RDONLY | O_NONBLOCK)
            try expect(reader >= 0, "recovery fixture opens isolated FIFO")
            defer { close(reader) }
            let taps = Mutex<[RecoveryFixtureTap]>([])
            let sourceActivity = Mutex<Bool?>(nil)
            let capture = CaptureController(makeTap: {
                let tap = RecoveryFixtureTap(); taps.withLock { $0.append(tap) }; return tap
            }, observeWake: false, sourceActivity: { _ in sourceActivity.withLock { $0 } })
            let recoveryStore = DALIStore(defaults: defaults, backendEnabled: false, capture: capture)
            try await capture.startAsync(fifoPath: pipe)
            defer { capture.stop() }
            try expect(recoveryStore.claimCaptureRecoveryRestart(), "first capture outage can restart once")
            for _ in 0..<2 {
                try expect(!recoveryStore.acknowledgeCaptureRecovery(within: 1),
                           "seeded tap-start clocks cannot acknowledge recovery")
                try expect(!recoveryStore.claimCaptureRecoveryRestart(), "missing callbacks cannot restore restart budget")
                let rebuilt = await capture.rebuildAsync(fifoPath: pipe, muteLocal: true, source: .system,
                                                         expectedSession: capture.sessionID)
                try expect(rebuilt, "silent fixture tap rebuild succeeds")
            }
            taps.withLock { $0.first! }.emitSilence()
            try expect(!recoveryStore.acknowledgeCaptureRecovery(within: 2), "retired callback cannot restore budget")
            taps.withLock { $0.last! }.emitSilence()
            _ = capture.readMetrics()
            try expect(recoveryStore.acknowledgeCaptureRecovery(within: 2), "fresh silent PCM acknowledges recovery after metrics read")
            try expect(recoveryStore.claimCaptureRecoveryRestart(), "real recovery restores one restart for a later outage")
            try expect(!recoveryStore.claimCaptureRecoveryRestart(), "later outage still has only one restart")
            capture.stop()
            sourceActivity.withLock { $0 = false }
            try await capture.startAsync(fifoPath: pipe)
            try await Task.sleep(for: .milliseconds(600))
            try expect(capture.callbackExpectation.sourceIsInactive &&
                       capture.callbackExpectation.secondsMissingExpectedBuffer == 0,
                       "idle-source callback expectation cannot trigger room recovery")
            try expect(!recoveryStore.acknowledgeCaptureRecovery(within: 2) &&
                       !recoveryStore.claimCaptureRecoveryRestart(),
                       "idle keepalive neither proves recovery nor restores room restart budget")
            sourceActivity.withLock { $0 = nil }
            // A cut once confirmed by real silence must release when a
            // different source starts, without a browser resume request.
            recoveryStore.phase = .streaming
            recoveryStore.systemVolume = 0.5
            for _ in 0..<24 {
                taps.withLock { $0.last! }.emitSilence()
                try await Task.sleep(for: .milliseconds(10))
            }
            recoveryStore.setExtensionCut(true)
            recoveryStore.reviewCutCredibility()
            try expect(recoveryStore.roomVolumePlan.pcmGain == 0, "real silence confirms browser cut")
            try await Task.sleep(for: .milliseconds(450))
            taps.withLock { $0.last! }.emit(0.5)
            try await Task.sleep(for: .milliseconds(30))
            recoveryStore.reviewCutCredibility()
            try expect(recoveryStore.roomVolumePlan.pcmGain == 1, "new Mac sound releases an already believed cut")
            recoveryStore.setExtensionCut(false)
            recoveryStore.phase = .idle
        }

        // A ready snapshot must not rejoin a receiver still wearing its old
        // trouble badge while the second confirmation poll is pending.
        try expect(!DALIStore.shouldRejoinOutput(troubleReadings: 0, readyNow: true), "ready output cannot rejoin")
        try expect(!DALIStore.shouldRejoinOutput(troubleReadings: 1, readyNow: false), "one miss cannot rejoin")
        try expect(DALIStore.shouldRejoinOutput(troubleReadings: 2, readyNow: false), "two misses can rejoin")
        try expect(!DALIStore.shouldRejoinOutput(troubleReadings: 5, readyNow: true), "new ready reading beats old trouble")
        do {
            let wakeStore = DALIStore(defaults: defaults, backendEnabled: false)
            wakeStore.phase = .streaming
            wakeStore.handleSystemSleep()
            try expect(wakeStore.phase == .idle && wakeStore.hasPendingWake, "sleep remembers a stopped mirror session")
            wakeStore.handleSystemWake()
            wakeStore.stopStream()
            try expect(!wakeStore.hasPendingWake, "Stop synchronously cancels pending wake")
            try await Task.sleep(for: .milliseconds(1100))
            try expect(wakeStore.phase == .idle && !wakeStore.hasPendingWake, "cancelled wake cannot start the room later")
        }

        let transport = RecordedVolumes()
        let store = DALIStore(defaults: defaults, backendEnabled: false,
                              volumeWrite: { id, value in await transport.send(id: id, value: value) })
        try expect(store.phase == .idle, "isolated controller starts idle")
        try expect(store.frontName == "Front fixture" && store.backName == "Back fixture",
               "controller reads injected speaker preferences")
        try expect(defaults.double(forKey: "dali.vol.Front fixture") == 80 &&
               defaults.double(forKey: "dali.gain.Front fixture") == 1,
               "V2 initialization preserves saved receiver reference values")
        try expect(store.delayTrimMs == 75, "controller reads injected timing trim")
        store.speakers = [
            RoomSpeaker(id: "front", name: "Front fixture", type: "AirPlay 2", kind: .front,
                        enabled: true, relVolume: 80, health: .live),
            RoomSpeaker(id: "back", name: "Back fixture", type: "AirPlay 2", kind: .back,
                        enabled: true, relVolume: 40, health: .live),
        ]
        let readyOutputs = try JSONDecoder().decode([Output].self, from: Data(#"[{"id":"front","name":"Front fixture","type":"AirPlay 2","selected":true,"connected":true,"streaming":true,"volume":16},{"id":"back","name":"Back fixture","type":"AirPlay 2","selected":true,"connected":true,"streaming":true,"volume":8}]"#.utf8))
        // Use production discovery/readiness application. A manually live UI
        // speaker alone is not proof of the private receiver readiness cache.
        store.applyDiscoveredSpeakers(readyOutputs)
        store.phase = .streaming
        let initialIntentAt = ContinuousClock.now
        store.systemVolume = 0.5
        try await waitUntil({ await transport.snapshot().count == 2 }, "initial receiver references are applied")
        try await Task.sleep(for: .milliseconds(150))
        let hardware = store.roomVolumePlan.hardware
        try expect(hardware["front"] == 10 && hardware["back"] == 5,
                   "half Mac master restores V1 receiver commands")
        // Independent expected values from V1 effectiveVolume, not the V2 policy.
        for (master, front, back, pcm) in [(0.01, 1, 0, 0.018176), (0.0625, 2, 1, 0.5),
                                         (0.125, 4, 2, 1.0), (0.5, 10, 5, 1.0), (1.0, 16, 8, 1.0)] {
            store.systemVolume = master
            try expect(store.roomVolumePlan.hardware == ["front": front, "back": back],
                       "Mac master changes receiver commands as V1 did")
            try expect(abs(store.captureMasterGain - pcm) < 1e-12,
                       "shared low-volume attenuation reaches capture while normal levels stay unity")
            try await waitUntil({
                let writes = await transport.snapshot()
                return writes.last(where: { $0.id == "front" })?.value == front &&
                    writes.last(where: { $0.id == "back" })?.value == back
            }, "Mac volume reaches both receivers through the production coordinator")
        }
        try expect(store.captureMasterGain == 1, "full Mac volume has unity PCM gain")

        store.systemVolume = 1.0 / 16
        try await waitUntil({
            let writes = await transport.snapshot()
            return writes.last(where: { $0.id == "front" })?.value == 2 &&
                writes.last(where: { $0.id == "back" })?.value == 1
        }, "first step preserves both calibrated receiver commands")
        try expect(store.captureMasterGain == 0.5, "first step lowers the whole captured room by half amplitude")

        let beforeMute = await transport.snapshot().count
        store.systemVolume = 0
        try await waitUntil({ await transport.snapshot().count == beforeMute + 2 }, "zero Mac volume explicitly mutes both receivers")
        let muteWrites = await transport.snapshot()
        try expect(muteWrites.suffix(2).allSatisfy { $0.value == 0 } && store.captureMasterGain == 0,
               "zero master mutes receiver commands and captured PCM")
        try expect(store.statusText == "Muted" && store.roomChrome.menuLabel == "Room muted",
                   "zero master must not tell the user the room is playing")
        store.systemVolume = 1.0 / 16
        try await waitUntil({ await transport.snapshot().count == beforeMute + 4 }, "unmute restores V1 receiver commands for the current master")
        try expect(store.captureMasterGain == 0.5, "unmute restores the quieter first step")
        store.systemVolume = 0.5
        try await waitUntil({
            let writes = await transport.snapshot()
            return writes.last(where: { $0.id == "front" })?.value == 10 &&
                writes.last(where: { $0.id == "back" })?.value == 5
        }, "normal volume restores unity and the original receiver response")
        let gainBeforeDisable = store.captureMasterGain
        let backBeforeDisable = store.effectiveVolume(store.back!)
        store.toggle(store.front!)
        try await waitUntil({ await transport.snapshot().last == RecordedVolumes.Write(id: "front", value: 0) },
                            "disabled front receives an explicit mute")
        try expect(store.effectiveVolume(store.back!) == backBeforeDisable &&
               store.captureMasterGain <= gainBeforeDisable + 1e-12,
               "disabling front cannot turn up the remaining back speaker")
        try expect(defaults.bool(forKey: "dali.on.Front fixture") == false, "speaker toggle uses injected preferences")
        store.toggle(store.front!)
        try await waitUntil({ await transport.snapshot().last == RecordedVolumes.Write(id: "front", value: 10) },
                            "re-enabled front restores its current master volume")

        let sliderIntentAt = ContinuousClock.now
        store.setRelVolume(65, for: store.back!)
        try await waitUntil({ await transport.snapshot().last == RecordedVolumes.Write(id: "back", value: 8) },
                            "speaker slider routes through the real volume coordinator")
        let sliderReceivedAt = await transport.times().last!
        try expect(defaults.double(forKey: "dali.vol.Back fixture") == 65, "speaker slider persists into the injected suite")
        let frontBeforeAdjustmentReset = store.effectiveVolume(store.front!)
        let masterBeforeAdjustmentReset = store.systemVolume
        store.setGain(0.84, for: store.back!)
        try await waitUntil({ await transport.snapshot().last(where: { $0.id == "back" })?.value == 7 },
                            "saved back attenuation reaches its actual receiver command")
        store.setGain(1, for: store.back!)
        try await waitUntil({ await transport.snapshot().last(where: { $0.id == "back" })?.value == 8 },
                            "reset back adjustment restores its unattenuated receiver command")
        try expect(store.back!.relVolume == 65 && store.back!.gain == 1 &&
                   defaults.double(forKey: "dali.gain.Back fixture") == 1,
                   "reset persists calibration without changing the speaker slider")
        try expect(store.effectiveVolume(store.front!) == frontBeforeAdjustmentReset &&
                   store.systemVolume == masterBeforeAdjustmentReset && store.captureMasterGain == 1,
                   "reset back adjustment leaves front, master and PCM unchanged")
        try expect(SpeakerPreferences(defaults: defaults).gain(name: "Back fixture") == 1,
                   "reset adjustment is retained when preferences are reloaded")
        store.setGain(1.5, for: store.back!)
        try expect(defaults.double(forKey: "dali.gain.Back fixture") == 1.5, "calibration persists into the injected suite")
        store.setRelVolume(.nan, for: store.back!)
        store.setGain(.infinity, for: store.back!)
        try expect(store.back!.relVolume == 65 && store.back!.gain == 1.5, "nonfinite input does not poison controller state")
        store.source = .app(pid: 1234, name: "Player fixture")
        try await waitUntil({
            let writes = await transport.snapshot()
            return writes.last(where: { $0.id == "front" })?.value == 20 &&
                writes.last(where: { $0.id == "back" })?.value == 20
        }, "selected-app source immediately submits its receiver reference plan")
        try expect(store.captureMasterGain == 1, "selected-app source switches the shared PCM gain to unity")
        store.source = .system
        try await waitUntil({ await transport.snapshot().last(where: { $0.id == "front" })?.value == 10 },
                            "system source immediately submits its receiver reference plan")
        try expect(store.captureMasterGain == 1, "system source restores hardware master control without double attenuation")
        store.volumeLimit = 150
        try expect(store.volumeLimit == 100 && defaults.double(forKey: "dali.volumeLimit") == 100,
               "ceiling bounds and storage agree")
        store.volumeLimit = .nan
        try expect(store.volumeLimit == 100, "nonfinite ceiling preserves the last valid bound")

        store.source = .app(pid: 1234, name: "Player fixture")
        try expect(store.captureMasterGain == 1 && defaults.string(forKey: "dali.sourceApp") == "Player fixture",
               "selected-app source retains unity PCM and persists only the fixture name")
        store.source = .spotify
        try expect(store.captureMasterGain == 1 && defaults.string(forKey: "dali.sourceApp") == "Spotify",
               "Spotify source does not inherit system-master attenuation")
        store.source = .system
        try expect(store.captureMasterGain == 1 && defaults.string(forKey: "dali.sourceApp") == "",
               "system source restores V1 master control before capture starts")
        store.delayTrimMs = 900
        try expect(store.delayTrimMs == 400 && defaults.double(forKey: "dali.delayTrimMs") == 400,
               "timing trim bounds and injected storage agree")
        try expect(defaults.string(forKey: "unrelated.preference") == "keep", "controller preserves unrelated preferences")

        // Let the preceding edits settle before testing a reply from a stopped
        // session. The fixture delays only I/O, not the production control path.
        try await Task.sleep(for: .milliseconds(400))
        await transport.pauseNextReply()
        let countBeforeStop = await transport.snapshot().count
        // Choose a step that changes the integer receiver command at half master.
        store.setRelVolume(70, for: store.front!)
        try await waitUntil({ await transport.snapshot().count > countBeforeStop }, "delayed receiver command was sent")
        store.stopStream()
        try expect(store.phase == .idle, "actual store stop wins synchronously")
        await transport.releaseReply()
        try await Task.sleep(for: .milliseconds(250))
        let stoppedCount = await transport.snapshot().count
        store.systemVolume = 0.9
        try await Task.sleep(for: .milliseconds(150))
        let finalCount = await transport.snapshot().count
        try expect(store.phase == .idle && finalCount == stoppedCount,
               "late replies and further slider intent cannot restart stopped volume work")

        func sample(tick: Int) -> RoomTimingController.Sample {
            RoomTimingController.Sample(dt: 1, written: tick * 175_000, pending: 0,
                produced: 176_400, silence: 0, dropped: 0, discontinuity: false,
                converterChanged: false, maximumGapMs: 10, player: "play",
                progressMs: tick * 1_000, queryMs: 10, controlBusy: false)
        }
        for reason in ["unknown_progress", "slow_query", "backpressure", "capture_gap", "control_settle"] {
            var timing = RoomTimingController()
            for tick in 0..<120 {
                var input = sample(tick: tick)
                switch reason {
                case "unknown_progress": input.player = nil; input.progressMs = nil
                case "slow_query": input.queryMs = 500
                case "backpressure": input.pending = 88_200
                case "capture_gap": input.maximumGapMs = 150
                case "control_settle": input.controlBusy = true
                default: fatalError("unknown timing test")
                }
                let result = timing.update(input, target: 0.7)
                try expect(result.ratio == 1, "\(reason) cannot start refill from invalid observations")
            }
        }
        var timing = RoomTimingController()
        var tick = 0
        var ratio = 1.0
        while ratio == 1 && tick < 300 {
            ratio = timing.update(sample(tick: tick), target: 0.7).ratio
            tick += 1
        }
        try expect(ratio < 1, "sustained trusted deficit can arm bounded one-sided refill")
        for _ in 0..<8 {
            ratio = timing.update(sample(tick: tick), target: 0.7).ratio
            tick += 1
            try expect(ratio >= 1 - timing.refill.cfg.capEps && ratio <= 1,
                   "trusted refill never exceeds its one-sided authority")
        }
        let ratioBeforeInvalid = ratio
        var invalid = sample(tick: tick)
        invalid.player = nil; invalid.progressMs = nil
        let unknown = timing.update(invalid, target: 0.7)
        try expect(unknown.ratio >= ratioBeforeInvalid && unknown.hold == "unknown_progress",
               "unknown progress cannot increase active refill")
        var discontinuity = sample(tick: tick + 1)
        discontinuity.discontinuity = true
        let hard = timing.update(discontinuity, target: 0.7)
        try expect(hard.hold == "capture_reset" && hard.ratio > unknown.ratio && hard.ratio <= 1,
               "hard discontinuity clears the anchor and eases existing correction toward unity")
        for offset in 2..<14 {
            var input = sample(tick: tick + offset)
            input.progressMs = nil
            ratio = timing.update(input, target: 0.7).ratio
        }
        try expect(ratio == 1, "invalid post-reset observations finish easing to unity")
        let addedBeforeReset = timing.refill.sessionAdded
        try expect(addedBeforeReset > 0 && timing.refill.bucketUsed <= timing.refill.cfg.bucketSec,
               "hard measurement reset preserves correction accounting")
        timing.reset()
        let reset = timing.update(sample(tick: 0), target: 0.7)
        try expect(reset.ratio == 1 && timing.refill.sessionAdded == 0,
               "explicit new-session reset clears timing state at unity")

        // Per-master-step leveling of the DALI speaker, through the production store:
        // discovery attaches the curve, the plan uses it, saved settings stay untouched.
        do {
            let curveSuite = "DALI.AppControllerTest.curve.\(UUID().uuidString)"
            let curveDefaults = UserDefaults(suiteName: curveSuite)!
            defer { curveDefaults.removePersistentDomain(forName: curveSuite) }
            for version in ["v2", "v3", "v4", "v5", "v8", "v9", "v10", "volumeLimit20"] {
                curveDefaults.set(true, forKey: "dali.migrated.\(version)")
            }
            let saved: [String: Any] = [
                "dali.frontName": "MICHAEL D", "dali.backName": "MICHAEL S",
                "dali.vol.MICHAEL D": 100.0, "dali.vol.MICHAEL S": 100.0,
                "dali.gain.MICHAEL D": 1.343581627155172, "dali.gain.MICHAEL S": 1.0,
                "dali.volumeLimit": 100.0,
                "dali.curveOn.MICHAEL D": false,   // retired switch: must be ignored, never deleted
            ]
            for (key, value) in saved { curveDefaults.set(value, forKey: key) }
            let curveStore = DALIStore(defaults: curveDefaults, backendEnabled: false,
                                       volumeWrite: { _, _ in .applied })
            let outputs = try JSONDecoder().decode([Output].self, from: Data(#"[{"id":"d","name":"MICHAEL D","type":"AirPlay 2","selected":true,"connected":true,"streaming":true,"volume":10},{"id":"s","name":"MICHAEL S","type":"AirPlay 2","selected":true,"connected":true,"streaming":true,"volume":10}]"#.utf8))
            curveStore.applyDiscoveredSpeakers(outputs)
            curveStore.phase = .streaming
            let dali = curveStore.speakers.first { $0.name == "MICHAEL D" }!
            let other = curveStore.speakers.first { $0.name == "MICHAEL S" }!
            try expect(dali.levelCurve != nil && dali.balanceTrim == 0 && other.levelCurve == nil,
                       "discovery attaches the leveling curve (trim 0) to the DALI speaker only, whatever the retired switch says")
            let targets: [(step: Int, percent: Double, d: Int, s: Int)] = [
                (1, 250, 36, 14), (2, 205, 48, 23), (3, 182, 56, 31), (4, 156, 59, 38),
                (5, 143, 63, 44), (6, 136, 68, 50), (7, 136, 76, 56), (8, 136, 84, 62), (16, 136, 100, 100),
            ]
            for target in targets {
                curveStore.systemVolume = Double(target.step) / 16
                let plan = curveStore.roomVolumePlan.hardware
                try expect(plan["d"] == target.d && plan["s"] == target.s,
                           "Mac volume step \(target.step) sends the leveled receiver commands")
                try expect(abs(curveStore.effectiveGain(dali) * 100 - target.percent) < 1e-6 &&
                           curveStore.effectiveGain(other) == 1,
                           "effective adjustment shown for step \(target.step) is \(target.percent)%")
            }
            curveStore.systemVolume = 3.0 / 16
            let neutral = curveStore.roomVolumePlan.hardware
            curveStore.setBalanceTrim(10, for: dali)
            let boosted = curveStore.roomVolumePlan.hardware
            try expect(neutral["d"] == 56 && boosted["d"] == 62 && boosted["s"] == neutral["s"],
                       "Balance +10% raises only the DALI speaker, by 10% of its curve value (56 to 62)")
            try expect(abs(curveStore.effectiveGain(curveStore.speakers.first { $0.name == "MICHAEL D" }!) - 1.82 * 1.1) < 1e-9,
                       "effective adjustment includes the trim")
            curveStore.setBalanceTrim(500, for: dali)
            try expect(curveStore.speakers.first { $0.name == "MICHAEL D" }!.balanceTrim == 30 &&
                       curveDefaults.double(forKey: "dali.balance.MICHAEL D") == 30, "trim is limited to +30")
            curveStore.setBalanceTrim(0, for: dali)
            try expect(curveStore.roomVolumePlan.hardware == neutral, "Reset (trim 0) restores the measured curve")
            for (key, value) in saved {
                try expect((curveDefaults.object(forKey: key) as? NSObject) == (value as? NSObject), "saved \(key) is untouched")
            }
            try expect(curveDefaults.object(forKey: "dali.balance.MICHAEL D") as? Double == 0,
                       "the balance trim is the only setting this feature writes")
        }

        func milliseconds(_ elapsed: Duration) -> Double {
            let value = elapsed.components
            return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
        }
        let initialReceivedAt = await transport.times().first!
        print(String(format: "Measured fixture submission: first receiver %.3f ms; slider receiver %.3f ms",
                     milliseconds(initialIntentAt.duration(to: initialReceivedAt)),
                     milliseconds(sliderIntentAt.duration(to: sliderReceivedAt))))
        print("Physical speaker command-to-sound latency was not measured")
        print("PASS: \(checks) actual app-controller regression checks with isolated preferences and I/O")
    }
}
