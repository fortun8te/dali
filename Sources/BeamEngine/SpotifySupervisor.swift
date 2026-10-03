// DALI — Spotify Connect receiver via librespot.
// Makes DALI appear as a native Spotify device, so Premium users can
// Connect from any Spotify app and have audio flow through DALI's
// AirPlay-pipe (front/back in sync via PTP). Falls back to tapping the
// Spotify desktop app if librespot is not bundled.

import Foundation
import os

public actor SpotifySupervisor {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private let log = Logger(subsystem: "dali.spotify", category: "supervisor")
    private var process: Process?
    private var intentionalStop = false
    private let lifecycle = EngineLifecycleGate()
    private var startTask: Task<Void, Error>?
    private var stopEpoch = 0
    var shutdownEpoch: Int { stopEpoch }
    public private(set) var state: State = .stopped
    public var onStateChange: (@Sendable (State) -> Void)?

    // Where librespot writes PCM that DALI feeds to the AirPlay pipe.
    // Using the same 44.1/16/2 s16le format as ProcessTap → FIFO.
    public let pipePath: URL
    private let cacheDir: URL
    private let deviceName: String
    private let bitrate: Int
    private let binaryOverride: URL?
    private let reap: @Sendable (String) -> Bool

    public init(deviceName: String = "DALI",
                pipePath: URL,
                cacheDir: URL,
                bitrate: Int = 320) {
        self.deviceName = deviceName
        self.pipePath = pipePath
        self.cacheDir = cacheDir
        self.bitrate = bitrate
        self.binaryOverride = nil
        self.reap = Self.reapStale
    }

    /// Tests own a disposable receiver and never sweep real Spotify processes.
    init(binary: URL, pipePath: URL, cacheDir: URL) {
        self.deviceName = "DALI test"
        self.pipePath = pipePath
        self.cacheDir = cacheDir
        self.bitrate = 320
        self.binaryOverride = binary
        self.reap = { _ in true }
    }

    public func setStateHandler(_ h: @escaping @Sendable (State) -> Void) { onStateChange = h }
    private func transition(_ s: State) { state = s; onStateChange?(s) }

    /// Resolve librespot binary: bundled helper first, then PATH. The answer is
    /// cached (isLibrespotAvailable is read from UI paths, and every miss used to
    /// spawn `which` — twice); a miss is re-checked after a minute so installing
    /// librespot while DALI runs is still noticed.
    private var resolvedBinary: URL?
    private var lastResolveMissAt: Date?

    private func resolveBinary() -> URL? {
        if let binaryOverride { return binaryOverride }
        if let resolvedBinary, FileManager.default.isExecutableFile(atPath: resolvedBinary.path) {
            return resolvedBinary
        }
        if let miss = lastResolveMissAt, Date().timeIntervalSince(miss) < 60 { return nil }
        if let found = locateBinary() {
            resolvedBinary = found
            lastResolveMissAt = nil
            return found
        }
        resolvedBinary = nil
        lastResolveMissAt = Date()
        return nil
    }

    private func locateBinary() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/librespot/librespot")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // Homebrew / manual install
        for p in ["/opt/homebrew/bin/librespot", "/usr/local/bin/librespot"] {
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        // Use `which` result
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        q.arguments = ["librespot"]
        let pipe = Pipe()
        q.standardOutput = pipe
        q.standardError = FileHandle.nullDevice
        guard (try? q.run()) != nil else { return nil }
        // Drain BEFORE waiting: waiting first can deadlock on a full pipe.
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        q.waitUntilExit()
        if q.terminationStatus == 0,
           let path = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// A librespot left behind by a DALI that crashed keeps the "DALI" Connect
    /// device name and keeps writing into the same FIFO, so the next librespot
    /// doubles every Spotify sample. Only processes writing to OUR pipe are touched.
    private nonisolated static func reapStale(pipePath: String) -> Bool {
        func ours(_ pid: Int32) -> Bool {
            guard let info = EngineSupervisor.processArguments(of: pid),
                  URL(fileURLWithPath: info.executable).lastPathComponent == "librespot",
                  let i = info.argv.firstIndex(of: "--device"), i + 1 < info.argv.count
            else { return false }
            return info.argv[i + 1] == pipePath
        }
        var stale = EngineSupervisor.pids(named: "librespot").filter(ours)
        guard !stale.isEmpty else { return true }
        for pid in stale { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(1.5)
        while !stale.isEmpty && Date() < deadline {
            usleep(50_000)
            stale = stale.filter(ours)
        }
        for pid in stale where ours(pid) { kill(pid, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(1)
        while stale.contains(where: ours) && Date() < killDeadline { usleep(20_000) }
        return !stale.contains(where: ours)
    }

    /// Identity of the librespot we manage; bumped on every spawn. A superseded
    /// child's terminationHandler lands asynchronously and must not clear the
    /// live child's handle (that leaked a second librespot on the next start()).
    private var generation = 0

    public func start() async throws {
        let epoch = stopEpoch
        while true {
            let task: Task<Void, Error>
            if let pending = startTask { task = pending }
            else {
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
                if epoch != stopEpoch { throw CancellationError() }
            } catch {
                if startTask == task { startTask = nil }
                throw error
            }
        }
    }

    private func performStart() async throws {
        if let process, process.isRunning { return }
        if process == nil, state == .running { return } // app-tap fallback
        process = nil
        intentionalStop = false
        transition(.starting)

        // Ensure cache + pipe parent exists
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)

        guard let bin = resolveBinary() else {
            // No librespot — this is NOT a failure, we fall back to app-tap mode.
            // DALIStore will tap the Spotify desktop app instead, so the
            // SpotifyConnect device still *appears* via the app's own Connect.
            log.info("librespot not found — using Spotify app tap fallback")
            transition(.running) // virtual running
            return
        }
        guard reap(pipePath.path) else {
            transition(.failed("previous Spotify receiver did not exit"))
            throw BeamAPIError(what: "previous Spotify receiver did not exit")
        }

        let p = Process()
        p.executableURL = bin
        // librespot 0.4+ args: --name, --bitrate, --cache, --backend pipe, --device-type speaker, --pipe
        // We use backend=pipe so librespot writes s16le 44.1/2 to the FIFO DALI already owns.
        // Quiet by default — DALI's own limit is 20, don't blast the room on first Connect.
        p.arguments = [
            "--name", deviceName,
            "--device-type", "speaker",
            "--bitrate", "\(bitrate)",
            "--cache", cacheDir.path,
            "--backend", "pipe",
            "--device", pipePath.path,
            "--initial-volume", "18",
            "--volume-ctrl", "linear",
            "--autoplay", // start playing when Connect hands us a track
            "--dither", "none"
        ]
        // librespot credentials are cached in --cache after first OAuth/zeroconf.
        // First Connect requires Spotify Premium auth via discovery — that flow is
        // handled entirely by librespot's zeroconf + Spotify app.
        // Never a Pipe: nothing drains it, and a full pipe blocks the child.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        generation += 1
        let gen = generation
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.handleDeath(generation: gen, status: status) }
        }
        do {
            try p.run()
        } catch {
            log.error("librespot start failed: \(error.localizedDescription)")
            transition(.failed(error.localizedDescription))
            throw error
        }
        process = p

        // Health: it must survive 1s; mDNS (_spotify-connect._tcp) publishes
        // asynchronously after that.
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 250_000_000)
            // A stop() (or a newer start) during the wait owns the state now.
            guard gen == generation, !intentionalStop else { throw CancellationError() }
            if !p.isRunning { break }
        }
        guard gen == generation, !intentionalStop else { throw CancellationError() }
        if p.isRunning {
            transition(.running)
            log.info("librespot running as '\(self.deviceName)' → pipe \(self.pipePath.path)")
            return
        }
        transition(.failed("librespot exited immediately"))
        throw BeamAPIError(what: "librespot exited immediately")
    }

    private func handleDeath(generation gen: Int, status: Int32) async {
        guard gen == generation else { return }
        process = nil
        if intentionalStop { transition(.stopped); return }
        log.error("librespot died status=\(status) — will restart on next DALI start")
        transition(.failed("librespot died \(status)"))
    }

    public func stop() async {
        stopEpoch += 1
        let epoch = stopEpoch
        intentionalStop = true
        startTask?.cancel()
        await lifecycle.acquire()
        if let child = process {
            let exited = await ManagedChildTermination.stop(child, graceSeconds: 2)
            if exited {
                if process === child { process = nil }
            } else {
                transition(.failed("librespot did not exit after shutdown"))
            }
        }
        if epoch == stopEpoch, process == nil { transition(.stopped) }
        await lifecycle.release()
    }

    public var isLibrespotAvailable: Bool { resolveBinary() != nil }
}
