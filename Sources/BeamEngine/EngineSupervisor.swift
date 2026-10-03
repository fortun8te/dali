// Spawns and supervises the bundled owntone helper.
// Restarts on crash with backoff; gives up after 3 deaths in 60s.

import Foundation
import Darwin
import SQLite3
import os

public actor EngineSupervisor {
    public enum State: Equatable, Sendable {
        case stopped, starting, running, failed(String)
    }

    private let binary: URL
    private var config: OwnToneConfig
    private let api: BeamAPI
    private let lifecycle = EngineLifecycleGate()
    private let runtime: Runtime
    private let log = Logger(subsystem: "beam.engine", category: "supervisor")

    /// Startup fails while PTP ports are held, preserving shared speaker timing.
    public private(set) var ptpAvailable = true

    /// Swap in a freshly-built config (e.g. after the low-latency toggle). Takes
    /// effect on the next start; pair with restart().
    public func updateConfig(_ c: OwnToneConfig) { config = c }
    private var process: Process?
    private var deathTimes: [Date] = []
    private var forcedRespawnTimes: [Date] = []   // wedge-respawn circuit breaker
    private var intentionalStop = false

    /// Why WE killed a generation. A death we asked for is not a crash: it must
    /// not burn the crash budget, and (for `.stop`) must not schedule a respawn.
    /// Keyed by generation so a late terminationHandler for a superseded engine
    /// cannot be mistaken for the current one's.
    private enum KillKind { case stop, respawn }
    private var requestedKills: [Int: KillKind] = [:]

    /// Bumped by every stop(). A start() that began before a stop() must notice
    /// (it would otherwise spawn an engine AFTER the stop, or on a stale config)
    /// and abandon itself; see performStart.
    private var stopEpoch = 0

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

    // Database self-repair. OwnTone exits at startup on a malformed sqlite file,
    // and the supervisor would then crash-loop into `.failed` on every launch
    // for ever (a restart reuses the same file). `databaseNeedsCheck` triggers a
    // cheap integrity probe before the next spawn (first start of the app, and
    // after any abnormal death); `quickDeaths` catches what the probe cannot see.
    private var databaseNeedsCheck = true
    private var spawnedAt: Date?
    private var quickDeaths = 0
    private var logTask: Task<Void, Never>?

    public private(set) var state: State = .stopped
    public var onStateChange: (@Sendable (State) -> Void)?
    /// When true, a crash-restart re-plays the pipe track automatically.
    public var resumePlaybackOnRestart = false

    public func setResumePlayback(_ on: Bool) { resumePlaybackOnRestart = on }

    /// Injectable platform checks let tests exercise the supervisor with a
    /// disposable child and mock HTTP, without probing or unlinking live PTP.
    struct Runtime: Sendable {
        var tcpAccepts: @Sendable (Int) -> Bool = { EngineSupervisor.tcpAccepts(port: $0) }
        var ptpPortsAreFree: @Sendable () -> Bool = { EngineSupervisor.ptpPortsAreFree() }
        var reap: @Sendable (String, TimeInterval) -> [Int32] = {
            EngineSupervisor.reapEngines(matchingConfig: $0, graceSeconds: $1)
        }
        var clearClock: @Sendable () -> Void = { _ = shm_unlink("/airptp_shm") }
        var ptpTimeout: TimeInterval = 12
        var terminateGrace: TimeInterval = 11
    }

    public init(binary: URL, config: OwnToneConfig) {
        self.binary = binary
        self.config = config
        self.api = BeamAPI(port: config.port)
        self.runtime = Runtime()
    }

    init(binary: URL, config: OwnToneConfig, api: BeamAPI, runtime: Runtime) {
        self.binary = binary
        self.config = config
        self.api = api
        self.runtime = runtime
    }

    deinit {
        // A supervisor that goes away (CLI exit, tests) must not leave its child
        // behind holding UDP 319/320 and a speaker session.
        logTask?.cancel()
        if let p = process, p.isRunning { p.terminate() }
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

    /// The start-time rotation above never fires for an engine that simply stays
    /// up for weeks, and OwnTone holds the file open, so it cannot be renamed
    /// out from under it. Copy the tail generation aside and truncate in place:
    /// OwnTone appends, so its next write lands at the new end of file.
    private func startLogWatch() {
        logTask?.cancel()
        logTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 600_000_000_000) } catch { return }
                await self?.trimLiveLog()
            }
        }
    }

    private func trimLiveLog(maxBytes: UInt64 = 96 * 1024 * 1024) {
        guard process != nil else { return }
        let fm = FileManager.default
        let url = config.logFile
        let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        guard size >= maxBytes else { return }
        let previous = URL(fileURLWithPath: url.path + ".1")
        try? fm.removeItem(at: previous)
        do { try fm.copyItem(at: url, to: previous) }
        catch { log.error("could not archive live OwnTone log: \(error.localizedDescription)"); return }
        if truncate(url.path, 0) == 0 {
            log.info("truncated live OwnTone log at \(size) bytes")
        }
    }

    // MARK: database self-repair

    /// False only when the file is provably not a usable sqlite database.
    /// Anything ambiguous (locked, unreadable, unexpected error) is "fine": the
    /// caller deletes a user's library on a False, so it must never guess.
    private nonisolated static func databaseIsHealthy(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        let size = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if size == 0 { return true }   // OwnTone lays the schema into an empty file
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return true }
        let head = (try? fh.read(upToCount: 16)) ?? Data()
        try? fh.close()
        guard head == Data("SQLite format 3\0".utf8) else { return false }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let openRC = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openRC == SQLITE_OK else { return openRC != SQLITE_CORRUPT && openRC != SQLITE_NOTADB }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let prepRC = sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &stmt, nil)
        guard prepRC == SQLITE_OK else { return prepRC != SQLITE_CORRUPT && prepRC != SQLITE_NOTADB }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(stmt, 0) else { return true }
            return String(cString: text) == "ok"
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return false
        default:
            return true
        }
    }

    /// Quarantine (one copy, for post-mortem) rather than delete: OwnTone rebuilds
    /// the library on the next start, and the next materialize() then also turns
    /// the initial scan back on because the file is gone.
    private func discardDatabase(reason: String) {
        let fm = FileManager.default
        let dir = config.varDir
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix("songs3.db.corrupt") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        let aside = dir.appendingPathComponent("songs3.db.corrupt-\(Int(Date().timeIntervalSince1970))")
        try? fm.moveItem(at: config.dbFile, to: aside)
        for suffix in ["-wal", "-shm", "-journal"] {
            try? fm.removeItem(atPath: config.dbFile.path + suffix)
        }
        log.error("discarded OwnTone database (\(reason)); it will be rebuilt")
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

    /// Poll until both PTP ports are bindable within the startup budget.
    /// Returns false if they never freed up.
    private func waitForPTPPorts(stepMs: Int = 250) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(runtime.ptpTimeout))
        while true {
            try Task.checkCancellation()
            if runtime.ptpPortsAreFree() { return true }
            if clock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(stepMs))
        }
    }

    /// Does anything accept TCP connections on 127.0.0.1:`port`? A bare connect
    /// with no HTTP request: probing "is the engine listening yet / is the old
    /// one gone" must never put a request on a dying or half-initialised
    /// OwnTone HTTP thread (the crash surface, see BeamAPI).
    nonisolated static func tcpAccepts(port: Int, timeoutMs: Int32 = 300) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let rc = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
        return err == 0
    }

    public func start() async throws {
        // Adopt an in-flight start rather than racing it. See `startTask`: the
        // body below suspends many times before it assigns `process`, so without
        // this two callers spawn two engines onto one pipe.
        let epoch = stopEpoch
        while true {
            let task: Task<Void, Error>
            if let inFlight = startTask {
                task = inFlight
            } else {
                task = Task {
                    await self.lifecycle.acquire()
                    do {
                        try Task.checkCancellation()
                        try await self.performStart()
                        await self.lifecycle.release()
                    } catch {
                        await self.lifecycle.release()
                        throw error
                    }
                }
                startTask = task
            }
            do {
                try await task.value
                if startTask == task { startTask = nil }
                return
            } catch is CancellationError {
                if startTask == task { startTask = nil }
                // The attempt was abandoned because a stop() ran while it was in
                // flight. If that stop came AFTER we asked, we were stopped too.
                // If it came BEFORE (restart() = stop(); start() adopting the
                // dying attempt), we still owe the caller an engine: go again.
                if epoch != stopEpoch { throw CancellationError() }
            } catch {
                if startTask == task { startTask = nil }
                throw error
            }
        }
    }

    // THE ORPHANED ENGINE (2026-09-23 13:16). Quitting DALI sends the engine one
    // SIGTERM and exits. OwnTone then sometimes never finishes shutting down: it
    // logs "Player deinit" and blocks forever in ptpd_deinit -> pthread_join on
    // the PTP daemon thread. Its HTTP port is already closed, so the next launch's
    // "is the port dead?" check passes, but the orphan still holds UDP 319/320
    // and a live AirPlay session to a speaker. A second SIGTERM does nothing (it
    // is already inside its shutdown path). The next engine then waits 12 s for
    // PTP, starts NTP-only, and competes with a zombie for the receivers.
    // Observed: pid 78548, parent 1, still holding *:319, *:320 and an
    // ESTABLISHED session to a speaker minutes after DALI quit.
    //
    // So an OwnTone running on OUR config gets SIGTERM, a short grace, then
    // SIGKILL. The kernel releases UDP sockets the instant a process dies.
    /// Returns the pids that had to be SIGKILLed.
    @discardableResult
    public nonisolated static func reapEngines(matchingConfig confPath: String,
                                               graceSeconds: TimeInterval) -> [Int32] {
        let pids = enginePids(matching: confPath)
        guard !pids.isEmpty else { return [] }
        for pid in pids where isMatchingEngine(pid, confPath: confPath) {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(graceSeconds)
        var alive = pids
        while !alive.isEmpty && Date() < deadline {
            usleep(50_000)
            alive = alive.filter { isMatchingEngine($0, confPath: confPath) }
        }
        // A PID can be reused during the grace period. Check the command again
        // immediately before escalation, rather than signaling a new process.
        alive = alive.filter { isMatchingEngine($0, confPath: confPath) }
        for pid in alive { kill(pid, SIGKILL) }
        // Give the kernel a moment to tear the sockets down before anyone binds.
        let killDeadline = Date().addingTimeInterval(1.0)
        while alive.contains(where: { isMatchingEngine($0, confPath: confPath) }) && Date() < killDeadline {
            usleep(20_000)
        }
        return alive
    }

    /// PIDs whose process name is exactly `name` (pgrep -x), excluding ourselves.
    nonisolated static func pids(named name: String) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = getpid()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != me }
    }

    private nonisolated static func enginePids(matching confPath: String) -> [Int32] {
        pids(named: "owntone").filter { isMatchingEngine($0, confPath: confPath) }
    }

    /// KERN_PROCARGS2 supplies the executable path and the individual argv
    /// strings, so a shell, log viewer, or diagnostic that mentions the config
    /// cannot be mistaken for our engine.
    nonisolated static func processArguments(of pid: Int32) -> (executable: String, argv: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        bytes = Array(bytes.prefix(size))

        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc <= 4096 else { return nil }
        var offset = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard offset < bytes.count,
                  let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(bytes: bytes[offset..<end], encoding: .utf8)
        }
        guard let executable = readString() else { return nil }
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var argv: [String] = []
        for _ in 0..<Int(argc) {
            guard let arg = readString() else { return nil }
            argv.append(arg)
        }
        return (executable, argv)
    }

    private nonisolated static func isMatchingEngine(_ pid: Int32, confPath: String) -> Bool {
        guard let info = processArguments(of: pid) else { return false }
        return matchesOwnTone(executablePath: info.executable, arguments: Array(info.argv.dropFirst()),
                              configPath: confPath)
    }

    static func matchesOwnTone(executablePath: String, arguments: [String],
                               configPath: String) -> Bool {
        let binary = URL(fileURLWithPath: executablePath)
        let original = ["-f", "-c", configPath]
        let sqliteOnly = original + ["-s", OwnToneConfig.sqliteExtension(for: binary).path]
        let bundled = sqliteOnly + ["-w", OwnToneConfig.webRoot(for: binary).path]
        // Keep exact matching for the prior installed generation during upgrades.
        return binary.lastPathComponent == "owntone"
            && (arguments == original || arguments == sqliteOnly || arguments == bundled)
    }

    /// How long a freshly spawned engine gets to start answering HTTP. Measured
    /// on wall-clock: the old counter was 40 iterations of (probe + 250ms), and a
    /// probe that hung for its own timeout stretched "10 s" into minutes.
    private static let startupTimeoutSeconds: TimeInterval = 12

    private func performStart() async throws {
        let epoch = stopEpoch
        // An orphan from a previous run of THIS app (see reapEngines) ignores
        // SIGTERM, so it must be escalated before anything else looks at ports.
        if process == nil {
            let killed = runtime.reap(config.confFile.path, 2.5)
            if !killed.isEmpty {
                log.error("reaped \(killed.count) orphaned engine(s) that ignored SIGTERM: \(killed.map(String.init).joined(separator: ","))")
            }
        }
        if let process, process.isRunning { return }
        process = nil
        // The port must be DEAD before we spawn: if anything still answers on it,
        // our child will run headless ("HTTPd thread failed to start") while
        // sharing the DB and pipe with the impostor — the two-engine glitch.
        // A bare TCP connect answers that without sending the impostor a request.
        for attempt in 0..<10 {
            if !runtime.tcpAccepts(config.port) { break }
            _ = runtime.reap(config.confFile.path, 0.4)
            try await Task.sleep(nanoseconds: 400_000_000)
            if attempt == 9 {
                transition(.failed("another audio engine is holding the port and refuses to quit"))
                throw BeamAPIError(what: "port \(config.port) occupied by a foreign engine")
            }
        }
        // A stop() during any wait above/below wins. Checked BEFORE the state
        // writes so a stale start cannot flip `.stopped` back to `.starting`.
        if stopEpoch != epoch { throw CancellationError() }
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
            ptpAvailable = try await waitForPTPPorts()
            guard ptpAvailable else {
                throw BeamAPIError(what: "PTP ports are still held; refusing to overlap audio engines")
            }
            if stopEpoch != epoch { throw CancellationError() }

            // Stale-PTP-shm guard (review HIGH-2): OwnTone's shared PTP daemon
            // publishes /airptp_shm. If a previous engine died by SIGKILL, the
            // segment survives looking fresh for up to 15s, and a fast relaunch
            // would "find" the DEAD grandmaster and silently run the whole
            // session on a clock nobody serves. We are about to spawn the only
            // engine on this box, so any existing segment is by definition
            // stale: remove it. (ENOENT is the normal case; ignored.)
            runtime.clearClock()

            // A previous process has exited, but its HTTP transport may still
            // be draining. Never let an old committed request hit the new child.
            api.suspendSession()
            await api.waitForDrain()
            try Task.checkCancellation()
            if stopEpoch != epoch { throw CancellationError() }

            rotateEngineLogIfNeeded()
            if databaseNeedsCheck {
                databaseNeedsCheck = false
                if !Self.databaseIsHealthy(at: config.dbFile) {
                    discardDatabase(reason: "failed integrity check")
                }
            }
            try config.materialize()

            let p = Process()
            p.executableURL = binary
            p.arguments = config.engineArguments(for: binary)
            // No pipes on purpose: OwnTone logs to its own logfile, and a pipe
            // nobody drains eventually blocks the child on write.
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Stamp this child with a generation so its death handler can prove
            // it is reporting the CURRENT engine's exit and not a superseded one.
            engineGeneration += 1
            let generation = engineGeneration
            p.terminationHandler = { [weak self] proc in
                let status = proc.terminationStatus
                let signaled = proc.terminationReason == .uncaughtSignal
                Task { await self?.handleDeath(generation: generation, status: status, signaled: signaled) }
            }
            try p.run()
            process = p
            spawnedAt = Date()

            // Health poll: the API must answer within the startup window. TCP
            // first (free), then ONE HTTP request at a time through the lane.
            // Keep all callers fenced until the child's listener exists. The
            // bundled engine initializes its worker/player and HTTP modules
            // before listening, so readiness need not pay a fixed one-second
            // delay after every spawn.
            var listenerReady = false
            let deadline = Date().addingTimeInterval(Self.startupTimeoutSeconds)
            while true {
                if stopEpoch != epoch { throw CancellationError() }
                guard p.isRunning, process === p else {
                    // Died during startup: fail now instead of polling a corpse
                    // for the rest of the window. handleDeath owns the retry.
                    transition(.failed("engine exited during startup"))
                    throw BeamAPIError(what: "engine exited during startup")
                }
                if runtime.tcpAccepts(config.port) {
                    if !listenerReady {
                        api.resumeSession()
                        listenerReady = true
                    }
                    if await api.isUp(deadline: 3) {
                        if stopEpoch != epoch { throw CancellationError() }
                        guard p.isRunning, process === p else { continue }
                        transition(.running)
                        startLogWatch()
                        return
                    }
                }
                if Date() >= deadline { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            transition(.failed("engine did not answer within \(Int(Self.startupTimeoutSeconds))s"))
            // Kill the unresponsive child WITHOUT letting its death handler
            // treat this as a crash and auto-respawn a competitor at the next
            // start.
            intentionalStop = true
            api.suspendSession()
            await stopProcess(kind: .stop)
            throw BeamAPIError(what: "engine start timeout")
        } catch {
            // An abandoned start (stop() ran) has nothing to report: stop()
            // already owns the state.
            if error is CancellationError { throw error }
            // The paths above already transitioned to `.failed` (with a
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

    private func handleDeath(generation: Int, status: Int32, signaled: Bool) async {
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
        //
        // The kill record is consumed BEFORE the generation guard so a
        // superseded engine's entry cannot leak.
        let kind = requestedKills.removeValue(forKey: generation)
        guard generation == engineGeneration else {
            log.info("ignoring death of superseded engine (generation \(generation), exit \(status))")
            return
        }
        process = nil
        api.suspendSession()
        logTask?.cancel(); logTask = nil
        // A death WE asked for (stop/restart) is not a crash. Without this, a
        // restart's own SIGTERM landed here after start() had already cleared
        // `intentionalStop`, counted toward the 3-crashes budget, and scheduled
        // a pointless respawn on top of the restart.
        if kind == .stop || (kind == nil && intentionalStop) {
            if intentionalStop && !isFailed(state) { transition(.stopped) }
            return
        }

        // A forced wedge respawn is a recovery, not a crash: it must NOT count
        // toward the "3 deaths in a minute, give up" budget. Otherwise a recurring
        // wedge exhausts the budget and the engine goes .failed, which is exactly
        // the "I have to restart the engine by hand" failure we are killing.
        let wasForced = kind == .respawn
        let epoch = stopEpoch
        var backoff: UInt64 = 300_000_000   // forced respawns recover fast
        if !wasForced {
            if signaled || status != 0 { databaseNeedsCheck = true }
            // Dying within seconds of every spawn is a startup failure. Two
            // such deaths in a row get an integrity probe (above); a third means
            // the library file itself is the likely culprit, and a crash loop on
            // a bad file never heals on its own, so start it over empty.
            let lived = spawnedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            quickDeaths = lived < 20 ? quickDeaths + 1 : 0
            if quickDeaths >= 3 {
                discardDatabase(reason: "engine died at startup \(quickDeaths) times in a row (last exit \(status))")
                quickDeaths = 0
            }
        }
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
        // The backoff is a suspension point: a stop()/restart() during it owns
        // the engine now, and resurrecting one here would undo the user's stop
        // (or race the restart's own start).
        guard !intentionalStop, epoch == stopEpoch, generation == engineGeneration,
              process == nil else { return }
        try? await start()
        // A forced respawn is followed by the caller's own full session rebuild
        // (DALIStore.resumePlaybackOnce: outputs + play). Replaying the pipe here
        // as well queued a second clear+play against the same engine seconds
        // after its first, i.e. a second audible restart of the same recovery.
        guard state == .running, resumePlaybackOnRestart, !wasForced else { return }
        // Output selection survives in the engine DB; just re-play the pipe.
        // The pipe track can lag a fresh engine's library by a moment.
        for attempt in 0..<3 {
            guard state == .running, epoch == stopEpoch else { return }
            if let uri = (try? await api.pipeTrackURI(named: "beam.pipe")) ?? nil {
                try? await api.playPipe(uri: uri)
                return
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
    }

    /// OwnTone's graceful shutdown is genuinely slow: SIGTERM to "Exiting." is
    /// measured at up to ~10s, spent inside Player deinit tearing down the RTSP
    /// sessions. The old 2s grace SIGKILLed it mid-teardown, which is very
    /// likely why UDP 319/320 were left lingering for the next start to trip
    /// over. 11s lets it finish and release its sockets properly.
    /// SIGKILL stays as the backstop for a truly wedged process.

    /// A WEDGED engine gets a much shorter grace. killForRespawn() exists for a
    /// process that is alive but frozen — it may never service SIGTERM at all, so
    /// waiting the full 11s just extends the dropout the respawn is meant to end.
    /// We trade clean socket release (which a wedged process probably wasn't
    /// going to manage anyway) for a fast recovery; the PTP port probe in start()
    /// then absorbs any socket that does linger.
    private static let wedgeGraceSeconds: TimeInterval = 2

    private func stopProcess(kind: KillKind, graceSeconds: TimeInterval? = nil) async {
        logTask?.cancel(); logTask = nil
        guard let child = process else { return }
        requestedKills[engineGeneration] = kind
        let exited = await ManagedChildTermination.stop(child,
            graceSeconds: graceSeconds ?? runtime.terminateGrace)
        // The lifecycle gate blocks start, and identity also protects against a
        // delayed handler. A still-running child remains owned and blocks spawn.
        if exited {
            if child.terminationReason == .uncaughtSignal, child.terminationStatus == SIGKILL {
                log.error("engine required SIGKILL after graceful shutdown deadline")
            }
            if process === child { process = nil }
        } else {
            transition(.failed("engine did not exit after shutdown"))
        }
    }

    public func stop() async {
        stopEpoch += 1
        let epoch = stopEpoch
        intentionalStop = true
        api.suspendSession()
        startTask?.cancel()
        await lifecycle.acquire()
        // SIGTERM performs OwnTone's graceful speaker/RTSP teardown. An HTTP
        // courtesy pause could itself be stuck, so teardown owns this path.
        await stopProcess(kind: .stop)
        await api.waitForDrain()
        if epoch == stopEpoch, process == nil { transition(.stopped) }
        await lifecycle.release()
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
        let epoch = stopEpoch + 1
        await stop()
        guard epoch == stopEpoch else { throw CancellationError() }
        if resettingBudgets {
            deathTimes = []
            forcedRespawnTimes = []
            quickDeaths = 0
        }
        try await start()
    }

    /// Force a WEDGED engine (process alive but HTTP API frozen) to recover.
    /// Kills the child WITHOUT setting intentionalStop, so the termination
    /// handler runs handleDeath() — the same path as a crash — which auto-restarts
    /// the engine. This is what
    /// rescues the "weird noises then everything dies, must restart the engine by
    /// hand" failure: the supervisor's normal watchdog only fires when the process
    /// actually exits, and a wedged process never does.
    public func killForRespawn() async {
        guard !intentionalStop, process != nil else { return }
        // Short grace: a wedged process is unlikely to honour SIGTERM, and every
        // second here is audible silence. -> terminationHandler -> handleDeath
        // -> restart.
        api.suspendSession()
        await lifecycle.acquire()
        if !intentionalStop {
            await stopProcess(kind: .respawn, graceSeconds: Self.wedgeGraceSeconds)
            await api.waitForDrain()
        }
        await lifecycle.release()
    }
}
