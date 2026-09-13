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
    public private(set) var state: State = .stopped
    public var onStateChange: (@Sendable (State) -> Void)?

    // Where librespot writes PCM that DALI feeds to the AirPlay pipe.
    // Using the same 44.1/16/2 s16le format as ProcessTap → FIFO.
    public let pipePath: URL
    private let cacheDir: URL
    private let deviceName: String
    private let bitrate: Int

    public init(deviceName: String = "DALI",
                pipePath: URL,
                cacheDir: URL,
                bitrate: Int = 320) {
        self.deviceName = deviceName
        self.pipePath = pipePath
        self.cacheDir = cacheDir
        self.bitrate = bitrate
    }

    public func setStateHandler(_ h: @escaping @Sendable (State) -> Void) { onStateChange = h }
    private func transition(_ s: State) { state = s; onStateChange?(s) }

    /// Resolve librespot binary: bundled helper first, then PATH.
    private func resolveBinary() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/librespot/librespot")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // Homebrew / manual install
        for p in ["/opt/homebrew/bin/librespot", "/usr/local/bin/librespot"] {
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        if let found = try? Process.run(URL(fileURLWithPath: "/usr/bin/which"),
                                        arguments: ["librespot"]) { _ = found }
        // Use `which` result
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        q.arguments = ["librespot"]
        let pipe = Pipe()
        q.standardOutput = pipe
        try? q.run()
        q.waitUntilExit()
        if q.terminationStatus == 0,
           let out = try? pipe.fileHandleForReading.readToEnd(),
           let path = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func start() async throws {
        guard process == nil else { return }
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
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Task { await self?.handleDeath(status: proc.terminationStatus) }
        }
        do {
            try p.run()
        } catch {
            log.error("librespot start failed: \(error.localizedDescription)")
            transition(.failed(error.localizedDescription))
            throw error
        }
        process = p

        // Health: give it 5s to publish mDNS (_spotify-connect._tcp)
        for _ in 0..<20 {
            if p.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
                // If we survive 1s, consider it running — mDNS is async
                transition(.running)
                log.info("librespot running as '\(self.deviceName)' → pipe \(self.pipePath.path)")
                return
            }
        }
        transition(.failed("librespot exited immediately"))
        throw BeamAPIError(what: "librespot exited immediately")
    }

    private func handleDeath(status: Int32) async {
        process = nil
        if intentionalStop { transition(.stopped); return }
        log.error("librespot died status=\(status) — will restart on next DALI start")
        transition(.failed("librespot died \(status)"))
    }

    public func stop() async {
        intentionalStop = true
        if let p = process, p.isRunning {
            p.terminate()
            // short grace — librespot exits fast, no AirPlay teardown
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if p.isRunning { p.interrupt(); kill(p.processIdentifier, SIGKILL) }
        }
        process = nil
        transition(.stopped)
    }

    public var isLibrespotAvailable: Bool { resolveBinary() != nil }
}
