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
    public var cacheDir: URL { varDir.appendingPathComponent("cache") }
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

    func engineArguments(for binary: URL) -> [String] {
        ["-f", "-c", confFile.path, "-s", Self.sqliteExtension(for: binary).path,
         "-w", Self.webRoot(for: binary).path]
    }

    /// OwnTone's compiled default points into the build prefix. The module must
    /// follow the bundled executable when the app or checkout moves.
    static func sqliteExtension(for binary: URL) -> URL {
        binary.deletingLastPathComponent().appendingPathComponent("lib/owntone-sqlext.so")
    }

    static func webRoot(for binary: URL) -> URL {
        binary.deletingLastPathComponent().appendingPathComponent("htdocs")
    }

    /// libconfuse string literal: a path or user name containing `"` or `\` would
    /// otherwise end the string early and make the whole file unparseable — the
    /// engine then fails to start on every launch for that user.
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    public var rendered: String {
        // The database and media directory are persistent. Re-scanning the
        // user's whole Music folder on every app launch used to contend with
        // startup playback and fill the log with probes of Music.app databases.
        // A brand-new install still gets the normal first scan; later launches
        // rely on OwnTone's filesystem watcher and the explicit rescan action.
        let skipInitialScan = FileManager.default.fileExists(atPath: dbFile.path)
        return """
        general {
            uid = \(Self.quoted(NSUserName()))
            db_path = \(Self.quoted(dbFile.path))
            logfile = \(Self.quoted(logFile.path))
            cache_dir = \(Self.quoted(cacheDir.path))
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
            directories = { \(Self.quoted(mediaDir.path)), \(Self.quoted(musicDir.path)) }
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
        for dir in [etcDir, varDir, cacheDir, mediaDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The path must be a real FIFO. A regular file left there (a stray
        // touch, a restore from backup) makes OwnTone read EOF forever and the
        // capture side write into a file that nobody plays.
        var st = stat()
        if lstat(pipePath.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFIFO {
            try fm.removeItem(at: pipePath)
        }
        if !fm.fileExists(atPath: pipePath.path) {
            guard mkfifo(pipePath.path, 0o644) == 0 || errno == EEXIST else {
                throw BeamAPIError(what: "mkfifo failed errno \(errno)")
            }
        }
        try rendered.write(to: confFile, atomically: true, encoding: .utf8)
    }
}
