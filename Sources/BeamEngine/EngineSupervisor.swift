// Spawns and supervises the bundled owntone helper.
// Restarts on crash with backoff; gives up after 3 deaths in 60s.

import Foundation
import Darwin
import os

public actor EngineSupervisor {
    public enum State: Equatable, Sendable {
        case stopped, starting, running, failed(String)
    }

    private let binary: URL
    private var config: OwnToneConfig
    private let api: BeamAPI
    private let log = Logger(subsystem: "beam.engine", category: "supervisor")

    /// False when the engine had to be started while UDP 319/320 were still held
    /// by a dying instance. OwnTone's embedded PTP service binds those two ports
    /// at startup and silently degrades to NTP-only timing if it cannot — and an
    /// NTP-only engine skips the AirPlay SETPEERS request, so multiple speakers
    /// never share a clock. Nonzero consequence, zero error message: surface it.
    public private(set) var ptpAvailable = true

    /// Swap in a freshly-built config (e.g. after the low-latency toggle). Takes
    /// effect on the next start; pair with restart().
    public func updateConfig(_ c: OwnToneConfig) { config = c }
    private var process: Process?
    private var deathTimes: [Date] = []
    private var forcedRespawnTimes: [Date] = []   // wedge-respawn circuit breaker
    private var intentionalStop = false
    private var forcedRespawn = false   // this death was a wedge respawn, not a crash

    // MARK: - single-engine ownership
    //
    // THE TWO-ENGINE BUG, and why these two fields exist.
    //
    // `start()` guarded on `process == nil` and then SUSPENDED repeatedly — the
    // API sweep, up to 12s of PTP port waiting, the config write — before finally
    // assigning `process` at the spawn, ~24s later in the worst case. Every one
    // of those suspension points is a window in which a second caller passes the
    // same stale guard. Two engines then spawn, both `open()` the one FIFO, and
    // each receives a SHARE of the audio bytes. That is the "weird noises".
    //
    // It is not hypothetical and it is not rare. In the engine log it appears as
    // two `taking off` lines a second apart followed by `Address already in use`
    // and `HTTPd thread failed to start` — 15 occurrences, most recently
    // 2026-08-29 17:43:32, well after the current code shipped. Reaching it takes
    // no unusual behaviour at all: DALIStore boots the engine from `init` while
    // the big button can independently call startStream(), and restartEngine() is
    // wired straight to a SwiftUI Picker's setter, so two quick clicks race.

    /// Serialises concurrent `start()` calls onto one attempt.
    ///
    /// Deliberately NOT a bare "already starting, return early" latch: the second
    /// caller would carry on and select AirPlay outputs against an engine that is
    /// not up yet. Adopting the in-flight task instead gives every caller the same
    /// outcome — the same success, or the same thrown error — which is what they
    /// already assume `try await start()` means.
    private var startTask: Task<Void, Error>?

    /// Identity of the engine we currently manage. Bumped on every spawn.
    ///
    /// `Process.terminationHandler` is delivered asynchronously, so a child we
    /// have already replaced can report its death AFTER its successor is running.
    /// `handleDeath` therefore has to know WHICH engine died; see the guard there.
    private var engineGeneration = 0

    public private(set) var state: State = .stopped
    public var onStateChange: (@Sendable (State) -> Void)?
    /// When true, a crash-restart re-plays the pipe track automatically.
    public var resumePlaybackOnRestart = false

    public func setResumePlayback(_ on: Bool) { resumePlaybackOnRestart = on }

    public init(binary: URL, config: OwnToneConfig) {
        self.binary = binary
        self.config = config
        self.api = BeamAPI(port: config.port)
    }

    public func setStateHandler(_ handler: @escaping @Sendable (State) -> Void) {
        onStateChange = handler
    }

    private func transition(_ new: State) {
        state = new
        onStateChange?(new)
    }

    /// OwnTone itself does not rotate its logfile. Keep the current incident and
    /// one previous generation; otherwise a long-running room produces hundreds
    /// of megabytes and the useful failure window gets buried in healthy clock
    /// lines. Called only while no managed engine is running, so rename is safe.
    private func rotateEngineLogIfNeeded(maxBytes: UInt64 = 24 * 1024 * 1024) {
        let fm = FileManager.default
        let url = config.logFile
        let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        guard size >= maxBytes else { return }
        let previous = URL(fileURLWithPath: url.path + ".1")
        do {
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: url, to: previous)
            log.info("rotated OwnTone log at \(size) bytes")
        } catch {
            log.error("could not rotate OwnTone log: \(error.localizedDescription)")
        }
    }

    // MARK: PTP port arbitration
    //
    // OwnTone's embedded PTP service grabs UDP 319 (event) and 320 (general) as
    // it comes up. If either is busy it does not retry and does not fail — it
    // quietly falls back to NTP-only timing, which makes it skip the AirPlay
    // SETPEERS request, and multi-speaker playback loses its shared clock.
    //
    // The race is real because OwnTone's graceful shutdown is SLOW: SIGTERM to
    // "Exiting." is up to ~10s (Player deinit tears down every RTSP session).
    // The old code slept 800ms and then polled api.isUp(), which only probes the
    // HTTP port (3689) — that frees long before the PTP sockets do, so we kept
    // spawning the new engine on top of the old one's UDP 319.
    private static let ptpPorts: [UInt16] = [319, 320]

    /// True if `port` can be bound for UDP right now, i.e. nobody else holds it.
    /// Deliberately does NOT set SO_REUSEADDR: we want this to genuinely fail
    /// while the dying OwnTone still owns the socket. The socket is closed
    /// immediately, so this never competes with the child we are about to spawn.
    private static func udpPortIsBindable(_ port: UInt16) -> Bool {
        // Probe BOTH families: owntone binds v4 and v6 wildcards separately, so
        // a lingering v6-only holder (another PTP daemon, an AirPlay Receiver
        // session) must fail this probe too, or ptpAvailable becomes a lie
        // (review finding L3).
        return udpPortIsBindable(port, family: AF_INET)
            && udpPortIsBindable(port, family: AF_INET6)
    }

    private static func udpPortIsBindable(_ port: UInt16, family: Int32) -> Bool {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let rc: Int32
        if family == AF_INET6 {
            // V6ONLY mirrors owntone's own bind_one(), so we test the same
            // socket shape it will ask for.
            var yes: Int32 = 1
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_any
            rc = withUnsafePointer(to: &addr) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian                  // network order
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)     // 0.0.0.0, endian-neutral
            rc = withUnsafePointer(to: &addr) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if rc == 0 { return true }
        // EACCES would mean the OS refuses us privileged ports at all (not the
        // case on macOS for UDP, but be safe): that is not "someone holds it",
        // and waiting 12s for it to clear would be pointless. Treat as free.
        return errno == EACCES || errno == EPERM
    }

    private static func ptpPortsAreFree() -> Bool {
        ptpPorts.allSatisfy { udpPortIsBindable($0) }
    }

    /// Poll until both PTP ports are bindable, up to `timeoutMs`.
    /// Returns false if they never freed up.
    private func waitForPTPPorts(timeoutMs: Int = 12_000, stepMs: Int = 250) async -> Bool {
        if Self.ptpPortsAreFree() { return true }
        var waited = 0
        while waited < timeoutMs {
            try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
            waited += stepMs
            if Self.ptpPortsAreFree() {
                log.info("PTP ports 319/320 freed after \(waited)ms")
                return true
            }
        }
        return false
    }

    public func start() async throws {
        // Adopt an in-flight start rather than racing it. See `startTask`: the
        // body below suspends many times before it assigns `process`, so without
        // this two callers spawn two engines onto one pipe.
        if let inFlight = startTask {
            return try await inFlight.value
        }
        let task = Task { try await self.performStart() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func performStart() async throws {
        // A stray engine (old build, CLI test, crashed instance) holding the
        // port makes every start fail with "address in use" and the user sees
        // endless Restart Engine. Clear any owntone we did not spawn first.
        if process == nil {
            let sweep = Process()
            sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            sweep.arguments = ["-f", "owntone -f -c"]
            try? sweep.run()
            sweep.waitUntilExit()
            if sweep.terminationStatus == 0 {   // something was killed; let the port free up
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        guard process == nil else { return }
        // The port must be DEAD before we spawn: if anything still answers on it,
        // our child will run headless ("HTTPd thread failed to start") while
        // sharing the DB and pipe with the impostor — the two-engine glitch.
        for attempt in 0..<10 {
            if await !api.isUp() { break }
            let sweep = Process()
            sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            sweep.arguments = [attempt < 5 ? "-f" : "-9", attempt < 5 ? "owntone -f -c" : "owntone"]
            try? sweep.run()
            sweep.waitUntilExit()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if attempt == 9 {
                transition(.failed("another audio engine is holding the port and refuses to quit"))
                throw BeamAPIError(what: "port \(config.port) occupied by a foreign engine")
            }
        }
        intentionalStop = false
        transition(.starting)

        // THE STUCK-.starting TRAP.
        //
        // Everything from here on can throw (config.materialize(), p.run()) or
        // simply take a while (the PTP wait). Until this fix, only the two
        // failure paths already inside this function — the port-occupied loop
        // above and the health-poll timeout below — ever transitioned to
        // `.failed` on their own way out. Any OTHER throw (a bad confFile write,
        // the binary being unexecutable, a spawn failure) left `state` parked at
        // `.starting` forever: no process, no death to trigger handleDeath's
        // retry, and no `.failed` for forceRespawn's own recovery loop
        // (`if case .failed = s { restart() }`) to catch. `killForRespawn()`
        // also silently no-ops on a nil `process`. The net effect was total and
        // PERMANENT silence with nothing anywhere ever trying again — worse than
        // the ordinary crash path, because a crash at least produces a `.failed`
        // or a retry.
        //
        // Wrap the whole remainder in do/catch so every exit either reaches
        // `.running` or leaves a `.failed` behind — never a bare `.starting`.
        do {
            // HTTP being free is NOT enough — the PTP sockets outlive it by
            // seconds. Wait for UDP 319+320 before spawning, or the new engine
            // comes up NTP-only and multi-speaker sync is silently broken.
            if await waitForPTPPorts() {
                ptpAvailable = true
            } else {
                // Do NOT abort: an NTP-only engine still plays. Just never let
                // this be invisible — it is the root cause of "speakers drift
                // apart".
                ptpAvailable = false
                log.error("UDP 319/320 still held after 12s — starting anyway; PTP unavailable, AirPlay multi-speaker sync will be degraded (NTP-only, no SETPEERS)")
            }

            // Stale-PTP-shm guard (review HIGH-2): OwnTone's shared PTP daemon
            // publishes /airptp_shm. If a previous engine died by SIGKILL, the
            // segment survives looking fresh for up to 15s, and a fast relaunch
            // would "find" the DEAD grandmaster and silently run the whole
            // session on a clock nobody serves. We are about to spawn the only
            // engine on this box, so any existing segment is by definition
            // stale: remove it. (ENOENT is the normal case; ignored.)
            _ = shm_unlink("/airptp_shm")

            rotateEngineLogIfNeeded()
            try config.materialize()

            let p = Process()
            p.executableURL = binary
            p.arguments = ["-f", "-c", config.confFile.path]   // foreground, our config
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Stamp this child with a generation so its death handler can prove
            // it is reporting the CURRENT engine's exit and not a superseded one.
            engineGeneration += 1
            let generation = engineGeneration
            p.terminationHandler = { [weak self] proc in
                let status = proc.terminationStatus
                Task { await self?.handleDeath(generation: generation, status: status) }
            }
            try p.run()
            process = p

            // Health poll: up to 10s for the API to answer.
            for _ in 0..<40 {
                if await api.isUp() {
                    transition(.running)
                    return
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            transition(.failed("engine did not answer within 10s"))
            // Kill the unresponsive child WITHOUT letting its death handler
            // treat this as a crash and auto-respawn a competitor at the next
            // start.
            intentionalStop = true
            stopProcess()
            throw BeamAPIError(what: "engine start timeout")
        } catch {
            // The two paths above already transitioned to `.failed` (with a
            // specific message) before throwing; this only fires for something
            // NEW — materialize() or p.run() failing — which is the exact gap
            // this fix closes. Don't stomp a message that path already set.
            if !isFailed(state) {
                transition(.failed("engine could not start: \(error)"))
            }
            throw error
        }
    }

    /// `State.failed(String)`'s associated value makes `==` compare messages,
    /// which is never what's wanted here — the catch above only needs to know
    /// "is this already SOME .failed", not which one.
    private func isFailed(_ s: State) -> Bool {
        if case .failed = s { return true }
        return false
    }

    private func handleDeath(generation: Int, status: Int32) async {
        // WHOSE DEATH IS THIS? Foundation delivers terminationHandler
        // asynchronously, and stopProcess() returns as soon as the child is no
        // longer running (immediately, on the SIGKILL path). So in restart() the
        // old engine's handler routinely lands AFTER the new engine is already
        // spawned. The old code acted on whichever child died and unconditionally
        // cleared `process` — erasing the LIVE engine's handle. The supervisor
        // then believed it had no engine, and the next start()'s sweep ran
        // `pkill -f "owntone -f -c"`, a pattern that matches the healthy engine's
        // own argv. It executed the engine it had just started. That is the
        // restart storm in the log: three spawn/die cycles inside three seconds
        // (2026-08-19 17:38:30-32).
        //
        // Generation rather than `proc === process`: stopProcess() nils `process`
        // before this handler runs, so an identity compare against `process`
        // would also swallow the killForRespawn() death — and that death is
        // precisely the one that MUST restart the engine.
        guard generation == engineGeneration else {
            log.info("ignoring death of superseded engine (generation \(generation), exit \(status))")
            return
        }
        process = nil
        if intentionalStop { transition(.stopped); return }

        // A forced wedge respawn is a recovery, not a crash: it must NOT count
        // toward the "3 deaths in a minute, give up" budget. Otherwise a recurring
        // wedge exhausts the budget and the engine goes .failed, which is exactly
        // the "I have to restart the engine by hand" failure we are killing.
        let wasForced = forcedRespawn
        forcedRespawn = false
        var backoff: UInt64 = 300_000_000   // forced respawns recover fast
        if wasForced {
            // Circuit breaker (review finding M3): forced respawns are exempt
            // from the crash budget by design, but a PERSISTENTLY wedging engine
            // (corrupt db, port conflict) would otherwise loop kill->respawn->
            // wedge forever — an audible dropout every ~30s with no escalation
            // and nothing surfaced to the user. A separate, longer budget parks
            // it in .failed where the UI can say so.
            forcedRespawnTimes.append(Date())
            forcedRespawnTimes = forcedRespawnTimes.filter { $0 > Date().addingTimeInterval(-600) }
            if forcedRespawnTimes.count > 4 {
                transition(.failed("engine wedged \(forcedRespawnTimes.count) times in 10 minutes — something is persistently wrong (check the log)"))
                return
            }
        }
        if !wasForced {
            deathTimes.append(Date())
            deathTimes = deathTimes.filter { $0 > Date().addingTimeInterval(-60) }
            if deathTimes.count > 3 {
                transition(.failed("engine crashed \(deathTimes.count) times in a minute (last exit \(status))"))
                return
            }
            backoff = [500_000_000, 2_000_000_000, 5_000_000_000][min(deathTimes.count - 1, 2)]
        }
        try? await Task.sleep(nanoseconds: backoff)
        try? await start()
        if state == .running, resumePlaybackOnRestart {
            // Output selection survives in the engine DB; just re-play the pipe.
            if let uri = (try? await api.pipeTrackURI(named: "beam.pipe")) ?? nil {
                try? await api.playPipe(uri: uri)
            }
        }
    }

    /// OwnTone's graceful shutdown is genuinely slow: SIGTERM to "Exiting." is
    /// measured at up to ~10s, spent inside Player deinit tearing down the RTSP
    /// sessions. The old 2s grace SIGKILLed it mid-teardown, which is very
    /// likely why UDP 319/320 were left lingering for the next start to trip
    /// over. 11s lets it finish and release its sockets properly.
    /// SIGKILL stays as the backstop for a truly wedged process.
    private static let terminateGraceSeconds: TimeInterval = 11

    /// A WEDGED engine gets a much shorter grace. killForRespawn() exists for a
    /// process that is alive but frozen — it may never service SIGTERM at all, so
    /// waiting the full 11s just extends the dropout the respawn is meant to end.
    /// We trade clean socket release (which a wedged process probably wasn't
    /// going to manage anyway) for a fast recovery; the PTP port probe in start()
    /// then absorbs any socket that does linger.
    private static let wedgeGraceSeconds: TimeInterval = 2

    /// Synchronous on purpose. Making this async would let the actor reenter —
    /// the terminationHandler's handleDeath() could spawn a replacement while we
    /// are still waiting, and our `process = nil` would then clobber it.
    private func stopProcess(graceSeconds: TimeInterval = EngineSupervisor.terminateGraceSeconds) {
        guard let p = process, p.isRunning else { process = nil; return }
        p.terminate()                       // SIGTERM
        let deadline = Date().addingTimeInterval(graceSeconds)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            log.error("engine ignored SIGTERM for \(graceSeconds)s — SIGKILL (sockets may linger)")
            kill(p.processIdentifier, SIGKILL)
        }
        process = nil
    }

    public func stop() async {
        intentionalStop = true
        try? await api.pause()
        stopProcess()
        transition(.stopped)
    }

    /// `resettingBudgets`: true (the default) for a HUMAN-initiated restart —
    /// Settings > Restart engine, or after changing the buffer size. A
    /// deliberate fresh start earns a clean slate.
    ///
    /// Pass false for the one other caller: DALIStore.forceRespawn()'s own
    /// fallback, which calls this when it finds the supervisor already
    /// `.failed`, to give a wedged engine one more chance to come up cleanly (a
    /// transient port/PTP clash can resolve itself). Resetting the budgets
    /// there defeated them completely: forceRespawn() -> killForRespawn() ->
    /// (breaker trips, `.failed`) -> restart() -> budgets wiped -> engine wedges
    /// again -> repeat, forever, with a "fresh" 10-minute window every single
    /// cycle. Observed in the field: four kill/respawn cycles in twelve minutes
    /// (dali-ai.jsonl.1, 2026-08-08 02:13-02:25), each one more disruptive than
    /// the slowness that triggered it.
    ///
    /// Leaving the budgets alone here costs nothing once the engine is
    /// genuinely healthy again — both already decay on their own rolling
    /// windows (60s / 600s) — it only bites an engine that is STILL wedging,
    /// which is exactly the case the breaker exists for.
    public func restart(resettingBudgets: Bool = true) async throws {
        await stop()
        if resettingBudgets {
            deathTimes = []
            forcedRespawnTimes = []
        }
        try await start()
    }

    /// Force a WEDGED engine (process alive but HTTP API frozen) to recover.
    /// Kills the child WITHOUT setting intentionalStop, so the termination
    /// handler runs handleDeath() — the same path as a crash — which auto-restarts
    /// the engine and (resumePlaybackOnRestart) replays the pipe. This is what
    /// rescues the "weird noises then everything dies, must restart the engine by
    /// hand" failure: the supervisor's normal watchdog only fires when the process
    /// actually exits, and a wedged process never does.
    public func killForRespawn() {
        guard !intentionalStop, process != nil else { return }
        forcedRespawn = true
        // Short grace: a wedged process is unlikely to honour SIGTERM, and every
        // second here is audible silence. -> terminationHandler -> handleDeath
        // -> restart + resume.
        stopProcess(graceSeconds: Self.wedgeGraceSeconds)
    }
}
