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

    /// Requests that arrive with no video playing are common (the extension
    /// polls), so the cut is armed only by an explicit /cut and cleared by an
    /// explicit /resume — never inferred from silence on this socket.
    private func handle(path: String) {
        // The route is what precedes "?": the worker cache-busts every request
        // with ?t=… (and /now carries its payload as a query), so an exact
        // match on the whole path would never see "/cut" at all.
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
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

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback      // never leaves this Mac
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            // Without this the listener could die (port stolen across a sleep/
            // wake, network stack reset) while `listener` stayed non-nil, so the
            // `guard listener == nil` above made start() a permanent no-op and
            // the beacon never came back for the rest of the app's life.
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    Task { @MainActor in
                        guard let self, self.listener === l else { return }
                        self.listener = nil
                    }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { conn.cancel() }
                Task { @MainActor in self?.receive(conn, accumulated: Data()) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            // A beacon that cannot bind is not worth failing a stream over —
            // the extension simply falls back to its manual delay.
            listener = nil
        }
    }


    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// TCP can split headers across packets. Never execute a partial request.
    private func receive(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384 - accumulated.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, error == nil else { conn.cancel(); return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                if let end = bytes.range(of: Data("\r\n\r\n".utf8)),
                   let header = String(data: bytes[..<end.upperBound], encoding: .utf8) {
                    do {
                        let request = try SyncHTTPRequest(header: header)
                        self.handle(path: request.target)
                        self.send(self.response(origin: request.origin), to: conn)
                    } catch {
                        self.send(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: conn)
                    }
                } else if complete || bytes.count >= 16384 {
                    conn.cancel()
                } else {
                    self.receive(conn, accumulated: bytes)
                }
            }
        }
    }

    private func send(_ data: Data, to conn: NWConnection) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static var bundledExtensionVersion: String {
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
            "extensionVersion": Self.bundledExtensionVersion,
            "streaming": streaming, "delayMs": delayMs
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n"
        if let origin { head += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
