import Foundation

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
        let baselineWrites = await transport.snapshot()
        let hardware = store.roomVolumePlan.hardware
        try expect(hardware["front"] == 16 && hardware["back"] == 8, "saved sliders retain their reference interpretation")
        let originalGain = store.captureMasterGain
        store.systemVolume = 0.125
        try expect(store.captureMasterGain < originalGain && store.captureMasterGain > 0,
               "Mac volume attenuates common PCM gain")
        for master in [0.01, 0.125, 0.5, 1.0] {
            store.systemVolume = master
            try expect(store.roomVolumePlan.hardware == hardware, "audible master changes keep fixed receiver balance")
        }
        try await Task.sleep(for: .milliseconds(250))
        let masterWrites = await transport.snapshot()
        try expect(masterWrites == baselineWrites, "master-only changes issue no receiver volume requests")
        try expect(store.captureMasterGain == 1, "full Mac volume has unity PCM gain")

        let beforeMute = await transport.snapshot().count
        store.systemVolume = 0
        try await waitUntil({ await transport.snapshot().count == beforeMute + 2 }, "zero Mac volume explicitly mutes both receivers")
        let muteWrites = await transport.snapshot()
        try expect(muteWrites.suffix(2).allSatisfy { $0.value == 0 } && store.captureMasterGain == 0,
               "zero master mutes receiver commands and captured PCM")
        store.systemVolume = 0.5
        try await waitUntil({ await transport.snapshot().count == beforeMute + 4 }, "unmute restores both fixed receiver references")
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
        try await waitUntil({ await transport.snapshot().last == RecordedVolumes.Write(id: "front", value: 16) },
                            "re-enabled front restores its fixed reference")

        let sliderIntentAt = ContinuousClock.now
        store.setRelVolume(65, for: store.back!)
        try await waitUntil({ await transport.snapshot().last == RecordedVolumes.Write(id: "back", value: 13) },
                            "speaker slider routes through the real volume coordinator")
        let sliderReceivedAt = await transport.times().last!
        try expect(defaults.double(forKey: "dali.vol.Back fixture") == 65, "speaker slider persists into the injected suite")
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
        try await waitUntil({ await transport.snapshot().last(where: { $0.id == "front" })?.value == 16 },
                            "system source immediately submits its receiver reference plan")
        try expect(store.captureMasterGain < 1, "system source restores common PCM attenuation")
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
        try expect(store.captureMasterGain < 1 && defaults.string(forKey: "dali.sourceApp") == "",
               "system source restores Mac-master attenuation before capture starts")
        store.delayTrimMs = 900
        try expect(store.delayTrimMs == 400 && defaults.double(forKey: "dali.delayTrimMs") == 400,
               "timing trim bounds and injected storage agree")
        try expect(defaults.string(forKey: "unrelated.preference") == "keep", "controller preserves unrelated preferences")

        // Let the preceding edits settle before testing a reply from a stopped
        // session. The fixture delays only I/O, not the production control path.
        try await Task.sleep(for: .milliseconds(400))
        await transport.pauseNextReply()
        let countBeforeStop = await transport.snapshot().count
        store.setRelVolume(79, for: store.front!)
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
