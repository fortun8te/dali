// Renders the owntone.conf Beam uses. Regenerated on every engine start so
// stale config can never wedge an upgrade.

import Foundation

public struct OwnToneConfig: Sendable {
    public let rootDir: URL      // .../Application Support/Beam/engine
    public let port: Int
    public let websocketPort: Int
    /// AirPlay start buffer. 700ms is the default: above OwnTone's >250ms hard
    /// floor with jitter headroom for slow receivers, low enough that video is
    /// watchable. The drift controller holds the fill AT this buffer, so a deep
    /// buffer is no longer needed for stability — it was only ever latency.
    public let startBufferMs: Int

    public init(rootDir: URL, port: Int = 3689, websocketPort: Int = 3688,
                startBufferMs: Int = 700) {
        self.rootDir = rootDir
        self.port = port
        self.websocketPort = websocketPort
        self.startBufferMs = startBufferMs
    }

    public var etcDir: URL   { rootDir.appendingPathComponent("etc") }
    public var varDir: URL   { rootDir.appendingPathComponent("var") }
    public var logFile: URL  { varDir.appendingPathComponent("owntone.log") }
    public var dbFile: URL   { varDir.appendingPathComponent("songs3.db") }
    public var mediaDir: URL { rootDir.appendingPathComponent("media") }
    public var pipePath: URL { mediaDir.appendingPathComponent("beam.pipe") }
    /// The user's Music folder, indexed so the player model can play their tracks
    /// directly (no capture). Falls back to ~/Music if the API lookup is nil.
    public var musicDir: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSString(string: "~/Music").expandingTildeInPath)
    }
    public var confFile: URL { etcDir.appendingPathComponent("owntone.conf") }

    public var rendered: String {
        // The database and media directory are persistent. Re-scanning the
        // user's whole Music folder on every app launch used to contend with
        // startup playback and fill the log with probes of Music.app databases.
        // A brand-new install still gets the normal first scan; later launches
        // rely on OwnTone's filesystem watcher and the explicit rescan action.
        let skipInitialScan = FileManager.default.fileExists(atPath: dbFile.path)
        return """
        general {
            uid = "\(NSUserName())"
            db_path = "\(dbFile.path)"
            logfile = "\(logFile.path)"
            loglevel = info
            trusted_networks = { "localhost" }
            websocket_interface = "lo0"
            websocket_port = \(websocketPort)
            ipv6 = no
            start_buffer_ms = \(startBufferMs)
        }
        library {
            name = "Beam"
            port = \(port)
            directories = { "\(mediaDir.path)", "\(musicDir.path)" }
            pipe_autostart = true
            filescan_disable = \(skipInitialScan ? "true" : "false")
            // Pin the pipe end to the exact format the capture side feeds
            // (s16le 44100/2). Makes the rate contract explicit so it can never
            // silently diverge from FormatConverter and cause clock drift.
            pipe_sample_rate = 44100
            pipe_bits_per_sample = 16
        }
        audio {
            type = "disabled"
        }
        sqlite {
            // Vacuuming is maintenance, not a launch prerequisite. On a live
            // audio appliance it must never hold the database during startup.
            vacuum = false
        }
        """
    }

    /// Create dirs, the FIFO, and write the config file.
    public func materialize() throws {
        let fm = FileManager.default
        for dir in [etcDir, varDir, mediaDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: pipePath.path) {
            guard mkfifo(pipePath.path, 0o644) == 0 else {
                throw BeamAPIError(what: "mkfifo failed errno \(errno)")
            }
        }
        try rendered.write(to: confFile, atomically: true, encoding: .utf8)
    }
}
