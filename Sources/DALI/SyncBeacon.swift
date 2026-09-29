// DALI — Sync beacon.
//
// A tiny loopback HTTP endpoint whose only job is to tell the browser
// extension two things: whether the room is live, and how far behind the
// speakers currently are in milliseconds.
//
// WHY THIS EXISTS: the extension has to delay video by the audio latency, and
// nothing in the engine's own API reports that number — an agent probed every
// endpoint (/api/player, /api/outputs, /api/config, /api/queue, /api/settings)
// and the only latency-ish field is per-speaker offset_ms, which is a relative
// trim between speakers, not delay to the ear. The app is the only process that
// knows the real figure, because it measures the pipe itself. So the app
// publishes it and the extension consumes it. That turns "type a number and
// nudge it until the lips match" into "it just lines up".
//
// Deliberately minimal: 127.0.0.1 only (never routable), GET only, one JSON
// object, no dependencies. It is a read-only status beacon, not an API.

import Foundation
import Network

@MainActor
final class SyncBeacon {
    static let port: UInt16 = 3697

    private var listener: NWListener?
    /// Set by DALIStore every flight tick. Read on each request.
    private(set) var streaming = false
    private(set) var delayMs = 0

    /// Called with `true` when the browser reports the video stopped, `false`
    /// when it starts again. Wired to DALIStore.setAudioCut(_:).
    var onCut: ((Bool) -> Void)?
    /// The worker's now-playing report: the raw JSON array from GET /now?d=…
    /// Wired to NowPlayingMonitor.browserReport(json:).
    var onNow: ((String) -> Void)?
    /// The version of the extension that is actually talking to us, or nil once
    /// it has been silent for `extensionTTL`. Fired only on change.
    var onExtensionSeen: ((String?) -> Void)?

    /// Extension 1.2+ stamps every request with `v=<version>&b=<build>`. The
    /// old `extensionVersion` field only compared two folders on disk (bundle vs
    /// managed copy) and said nothing about whether Chrome runs the extension —
    /// with no managed copy it was always "", even while a source-folder install
    /// was polling every second. This is the live answer.
    private(set) var seenExtensionVersion: String?
    private(set) var seenExtensionBuild = ""
    private var seenExtensionAt = Date.distantPast
    private var extensionExpiry: Task<Void, Never>?
    /// Content scripts poll once a second while a tab has media, and the
    /// worker checks in on a 30 s alarm even with no video open. Two missed
    /// alarms means no extension is running.
    static let extensionTTL: TimeInterval = 70

    private func noteExtension(query: Substring) {
        var version: String?, build = ""
        for pair in query.split(separator: "&") {
            if pair.hasPrefix("v=") { version = String(pair.dropFirst(2)).removingPercentEncoding }
            else if pair.hasPrefix("b=") { build = String(pair.dropFirst(2)).removingPercentEncoding ?? "" }
        }
        guard let v = version?.prefix(32), !v.isEmpty,
              v.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        let changed = seenExtensionVersion != String(v)
        seenExtensionVersion = String(v)
        seenExtensionBuild = String(build.prefix(32))
        seenExtensionAt = Date()
        // One sleeping Task, replaced on every request. A DispatchWorkItem
        // per request stayed queued in GCD for the full 70 s even after
        // cancel(), so a tab polling once a second piled up ~70 dead timers.
        extensionExpiry?.cancel()
        extensionExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.extensionTTL))
            guard !Task.isCancelled, let self,
                  Date().timeIntervalSince(self.seenExtensionAt) >= Self.extensionTTL - 0.5 else { return }
            self.seenExtensionVersion = nil
            self.seenExtensionBuild = ""
            self.onExtensionSeen?(nil)
        }
        if changed { onExtensionSeen?(seenExtensionVersion) }
    }

    /// Requests that arrive with no video playing are common (the extension
    /// polls), so the cut is armed only by an explicit /cut and cleared by an
    /// explicit /resume — never inferred from silence on this socket.
    private func handle(path: String, authorized: Bool) {
        // The route is what precedes "?": the worker cache-busts every request
        // with ?t=… (and /now carries its payload as a query), so an exact
        // match on the whole path would never see "/cut" at all.
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        // Plain `GET /` needs no credentials (it is the status probe), so a
        // web page could fire `no-cors` GETs at it with a forged `?v=`. Only
        // a request that proved it is the extension may claim to be one.
        if authorized, parts.count > 1 { noteExtension(query: Substring(parts[1])) }
        switch parts.first ?? "/" {
        case "/cut":    onCut?(true)
        case "/resume": onCut?(false)
        case "/now":
            // GET /now?d=<url-encoded JSON array>&t=… — fire-and-forget from
            // the worker; the monitor expires it if the worker goes quiet.
            if parts.count > 1,
               let q = parts[1].split(separator: "&").first(where: { $0.hasPrefix("d=") }),
               let json = String(q.dropFirst(2)).removingPercentEncoding {
                onNow?(json)
            }
        default:        break          // "/" and anything else: status only
        }
    }

    /// Publish the app's stable configured delay estimate, including the
    /// engine's scheduling allowance and the user's saved trim. Diagnostic
    /// progress deltas are not absolute measurements of sound at the speaker.
    func publish(streaming: Bool, delaySeconds: Double?) {
        self.streaming = streaming
        guard streaming, let delay = delaySeconds, delay.isFinite, delay > 0 else {
            delayMs = 0
            return
        }
        delayMs = Int((min(max(delay, 0.05), 4.0) * 1000).rounded())
    }

    // MARK: listener lifecycle

    /// The beacon should be up. False after stop(), so a cancelled listener
    /// is never resurrected by the retry below.
    private var wanted = false
    private var restartTask: Task<Void, Never>?
    private var restartDelay: Duration = .seconds(1)

    func start() {
        wanted = true
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback      // never leaves this Mac
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            // Without this the listener could die (port stolen across a sleep/
            // wake, network stack reset) while `listener` stayed non-nil, so the
            // `guard listener == nil` above made start() a permanent no-op and
            // the beacon never came back for the rest of the app's life. It is
            // also what makes a port still held by the previous instance (a
            // quick relaunch) heal itself instead of failing once at boot.
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in
                        guard let self, self.listener === l else { return }
                        self.restartDelay = .seconds(1)
                    }
                case .failed, .cancelled:
                    Task { @MainActor in
                        guard let self, self.listener === l else { return }
                        self.listener = nil
                        l.cancel()
                        self.scheduleRestart()
                    }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    guard let self else { conn.cancel(); return }
                    self.accept(conn)
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            // A beacon that cannot bind is not worth failing a stream over —
            // the extension simply falls back to its manual delay. Keep trying
            // in the background, though: the port is usually free a moment later.
            listener = nil
            scheduleRestart()
        }
    }

    func stop() {
        wanted = false
        restartTask?.cancel(); restartTask = nil
        listener?.cancel()
        listener = nil
        for id in Array(inflight.keys) { finish(id) }
        extensionExpiry?.cancel(); extensionExpiry = nil
    }

    /// Back off 1, 2, 4 … 30 s. A permanently unbindable port costs one
    /// attempt per half minute, not a hot loop.
    private func scheduleRestart() {
        guard wanted, restartTask == nil else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, .seconds(30))
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            if self.wanted { self.start() }
        }
    }

    // MARK: connections

    /// Requests are tiny and the only client is one extension worker, so this
    /// is generous. It exists so a flood (or a stuck peer) cannot grow open
    /// sockets without bound.
    private static let maxConnections = 24
    private static let maxRequestBytes = 16384
    /// A whole request must arrive inside this, or the socket is dropped
    /// (slow-loris: a peer that dribbles bytes never holds one open).
    private static let requestDeadline: TimeInterval = 4

    private struct Inflight {
        let conn: NWConnection
        let deadline: DispatchWorkItem
    }
    private var inflight: [Int: Inflight] = [:]
    /// A serial number, not ObjectIdentifier: a freed connection's address can
    /// be reused, and a late state callback must never end its successor.
    private var nextConnectionID = 0

    private func accept(_ conn: NWConnection) {
        guard inflight.count < Self.maxConnections else { conn.cancel(); return }
        nextConnectionID &+= 1
        let id = nextConnectionID
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(id) }
        }
        inflight[id] = Inflight(conn: conn, deadline: deadline)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestDeadline, execute: deadline)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.finish(id) }
            default: break
            }
        }
        conn.start(queue: .main)
        receive(conn, id: id, accumulated: Data())
    }

    /// Drop a connection and its deadline together, exactly once.
    private func finish(_ id: Int) {
        guard let entry = inflight.removeValue(forKey: id) else { return }
        entry.deadline.cancel()
        entry.conn.stateUpdateHandler = nil
        entry.conn.cancel()
    }

    /// TCP can split headers across packets. Never execute a partial request.
    private func receive(_ conn: NWConnection, id: Int, accumulated: Data) {
        let room = Self.maxRequestBytes - accumulated.count
        guard room > 0 else { finish(id); return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: room) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.inflight[id] != nil else { return }
                guard error == nil else { self.finish(id); return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                    guard let header = String(data: bytes[..<end.upperBound], encoding: .utf8) else {
                        self.reply(Self.bad(400, "Bad Request"), to: id)
                        return
                    }
                    do {
                        let request = try SyncHTTPRequest(header: header)
                        self.handle(path: request.target, authorized: request.authorizedControl)
                        self.reply(self.response(origin: request.origin), to: id)
                    } catch {
                        self.reply(Self.bad(403, "Forbidden"), to: id)
                    }
                } else if complete || bytes.count >= Self.maxRequestBytes {
                    self.finish(id)
                } else {
                    self.receive(conn, id: id, accumulated: bytes)
                }
            }
        }
    }

    private static func bad(_ code: Int, _ text: String) -> Data {
        Data("HTTP/1.1 \(code) \(text)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private func reply(_ data: Data, to id: Int) {
        guard let entry = inflight[id] else { return }
        // Network.framework never raises SIGPIPE, so a peer that hangs up
        // mid-write cannot kill the app the way a raw write(2) would.
        entry.conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(id) }
        })
    }

    // The bundled manifest and the managed copy change only when an update is
    // installed, but this used to be re-read and re-parsed from disk on every
    // request — once a second per video tab, on the main thread.
    private static var cachedBundledVersion: (value: String, at: Date)?
    private static var bundledExtensionVersion: String {
        if let c = cachedBundledVersion, Date().timeIntervalSince(c.at) < 30 { return c.value }
        let v = readBundledExtensionVersion()
        cachedBundledVersion = (v, Date())
        return v
    }

    private static func readBundledExtensionVersion() -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension/manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        guard let version = manifest["version"] as? String,
              let installedData = try? Data(contentsOf: ExtensionInstaller.installURL.appendingPathComponent("manifest.json")),
              let installed = try? JSONSerialization.jsonObject(with: installedData) as? [String: Any],
              installed["version"] as? String == version else { return "" }
        return version
    }

    private func response(origin: String?) -> Data {
        let payload: [String: Any] = [
            "app": "DALI", "protocolVersion": 1,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "capabilities": ["status", "audio-cut", "now-playing"],
            // What Chrome is really running ("" = nothing checked in lately).
            "extensionVersion": seenExtensionVersion ?? "",
            "extensionBuild": seenExtensionBuild,
            // What this app ships in the managed folder; extension 1.2+ reloads
            // itself once when this is newer than its own manifest.
            "bundledExtensionVersion": Self.bundledExtensionVersion,
            "streaming": streaming, "delayMs": delayMs
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n"
        if let origin { head += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
