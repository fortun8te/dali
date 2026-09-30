// Thin client for OwnTone's JSON API on localhost.
// Every endpoint here was proven by curl during Phase 0.

import Foundation
import os

public struct Output: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public var selected: Bool
    /// Actual backend session state. `selected` is only intent and may stay true
    /// after an AirPlay session has silently died.
    public var connected: Bool?
    public var streaming: Bool?
    public var volume: Int
    /// Per-speaker playback offset (ms, positive = plays later). Optional so
    /// engines/responses without the field keep decoding.
    public var offset_ms: Int?
}

public struct PlayerState: Codable, Equatable, Sendable {
    public let state: String      // "play" | "pause" | "stop"
    public let volume: Int
    // OwnTone's real playback clock: ms of audio it has actually rendered to the
    // outputs. For a live pipe this advances at the SPEAKER clock, so it is the
    // only signal that reflects true end-to-end backlog (our pipe-side counters
    // can't see OwnTone's internal + AirPlay buffers).
    public let item_progress_ms: Int?
    // Player-model fields: which queue item is current and how long it is, so the
    // UI can show now-playing title/artist and a progress bar.
    public let item_id: Int?
    public let item_length_ms: Int?

    enum CodingKeys: String, CodingKey {
        case state, volume, item_progress_ms, item_id, item_length_ms
    }

    /// A reply without a usable `volume` is still proof the engine is alive; it
    /// must not surface as a failed poll (the health loop counts those).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        volume = (try? c.decodeIfPresent(Int.self, forKey: .volume)) ?? 0
        item_progress_ms = try? c.decodeIfPresent(Int.self, forKey: .item_progress_ms)
        item_id = try? c.decodeIfPresent(Int.self, forKey: .item_id)
        item_length_ms = try? c.decodeIfPresent(Int.self, forKey: .item_length_ms)
    }
}

/// An album in OwnTone's library (your ~/Music), used by the player model.
public struct LibraryAlbum: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let artist: String?
    public let uri: String
}

/// One item in the play queue. `id` matches PlayerState.item_id for the current track.
public struct QueueItem: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String?
    public let artist: String?
    public let album: String?
    public let length_ms: Int?
    public let uri: String?
}

public struct BeamAPIError: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "BeamAPI: \(what)" }
}

// MARK: - transport
//
// THE KNOWN OWNTONE CRASH: SIGSEGV in evhttp_add_header_internal <-
// httpd_header_add <- jsonapi_request. OwnTone's HTTP thread is single and its
// command lane stalls for ~15 s whenever it is inside an RTSP handshake. Any
// request queued behind that stall is served LATE; if the client has already
// hung up (a URLSession timeout, a cancelled Task, a second client's overlapping
// request) the engine writes headers onto a connection that is gone and dies.
//
// So the client rules are: (1) one request on the wire per engine at a time,
// shared by EVERY BeamAPI value for that port (DALIStore and EngineSupervisor
// each own one), (2) a request that has been written is NEVER cancelled or
// abandoned at the socket — a caller that runs out of patience (its deadline,
// or its own Task being cancelled) simply stops waiting and the late reply is
// dropped, (3) a request that has not been written yet is dropped when its
// caller gives up, so an abandoned burst cannot pile onto a stalled engine,
// (4) no connection reuse (a fresh session per request) so we never talk to the
// corpse of a previous engine over a pooled socket.

/// Resumes exactly one waiter exactly once, from any thread, in any order
/// relative to `wait()` — the result may land before the continuation exists.
final class ReplySlot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var finished = false

    var isResolved: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    @discardableResult
    func resolve(_ r: Result<Data, Error>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume(with: r)
        } else {
            result = r
            lock.unlock()
        }
        return true
    }

    func wait() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            lock.lock()
            if let r = result {
                result = nil
                lock.unlock()
                c.resume(with: r)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

/// One serial lane per engine port; see the block comment above.
final class RequestLane: @unchecked Sendable {
    /// `coalesceKey`: a write that says "set X to V" is made obsolete by a later
    /// "set X to W". While the older one is still queued (not yet on the wire) it
    /// is dropped and its caller told "done" — latest target wins, and a stalled
    /// engine never receives a backlog of values nobody wants any more.
    struct Op { let request: URLRequest; let slot: ReplySlot; var coalesceKey: String? = nil; var writeKind: String? = nil }
    private struct State {
        var queue: [Op] = []
        var busy = false
        var notBefore = Date.distantPast
        var wakePending = false
        /// Every state-changing request that actually reached the wire, so the
        /// app can publish "engine writes per minute" (each volume / offset /
        /// select is an RTSP SET_PARAMETER on OwnTone's shared player thread).
        var writes: [(at: Date, kind: String)] = []
        var totalWrites = 0
    }

    private static let registry = OSAllocatedUnfairLock(initialState: [Int: RequestLane]())
    static func shared(port: Int) -> RequestLane {
        registry.withLock { lanes in
            if let lane = lanes[port] { return lane }
            let lane = RequestLane()
            lanes[port] = lane
            return lane
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let config: URLSessionConfiguration

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        // These are the LAST-RESORT bounds for a socket that has gone silent, not
        // the caller's patience (that is BeamAPI.readDeadline/writeDeadline, and
        // it never touches the socket). They sit well beyond OwnTone's longest
        // observed stall (~34 s in the flight log) only for a truly dead peer;
        // the health loop respawns a wedged engine long before this fires, and a
        // respawn closes the socket from the server side anyway.
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.httpShouldUsePipelining = false
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]     // loopback: never via a system proxy
        config = cfg
    }

    func enqueue(_ op: Op) {
        let superseded: [ReplySlot] = state.withLock { s in
            s.queue.removeAll { $0.slot.isResolved }     // callers that gave up
            var dropped: [ReplySlot] = []
            if let key = op.coalesceKey {
                dropped = s.queue.filter { $0.coalesceKey == key }.map(\.slot)
                s.queue.removeAll { $0.coalesceKey == key }
            }
            s.queue.append(op)
            return dropped
        }
        // Outside the lock: resolving resumes a continuation.
        for slot in superseded { slot.resolve(.success(Data())) }
        pump()
    }

    /// Writes that went on the wire in the last `window` seconds, by kind.
    func recentWrites(window: TimeInterval) -> [String: Int] {
        let cutoff = Date().addingTimeInterval(-window)
        return state.withLock { s in
            s.writes.removeAll { $0.at < Date().addingTimeInterval(-600) }
            var out: [String: Int] = [:]
            for w in s.writes where w.at >= cutoff { out[w.kind, default: 0] += 1 }
            return out
        }
    }

    var totalWrites: Int { state.withLock { $0.totalWrites } }

    private func noteWrite(kind: String) {
        state.withLock { s in
            s.writes.append((Date(), kind))
            s.totalWrites += 1
        }
    }

    /// Keep the lane quiet for `seconds` (right after an engine spawn, while its
    /// HTTP thread is still initialising). Queued requests wait; they do not fail.
    func holdOff(_ seconds: TimeInterval) {
        state.withLock { $0.notBefore = max($0.notBefore, Date().addingTimeInterval(seconds)) }
    }

    private enum Next { case none, run(Op), wait(TimeInterval) }

    private func pump() {
        let next: Next = state.withLock { s in
            guard !s.busy else { return .none }
            s.queue.removeAll { $0.slot.isResolved }
            guard !s.queue.isEmpty else { return .none }
            let hold = s.notBefore.timeIntervalSinceNow
            if hold > 0 {
                if s.wakePending { return .none }
                s.wakePending = true
                return .wait(hold)
            }
            s.busy = true
            return .run(s.queue.removeFirst())
        }
        switch next {
        case .none:
            break
        case .wait(let hold):
            Task {
                try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000) + 10_000_000)
                self.state.withLock { $0.wakePending = false }
                self.pump()
            }
        case .run(let op):
            // Unstructured on purpose: nothing a caller does can cancel this.
            Task {
                await self.perform(op)
                self.state.withLock { $0.busy = false }
                self.pump()
            }
        }
    }

    private func perform(_ op: Op) async {
        // A throwaway session per request: URLSession pools keep-alive sockets
        // (and reserves the `Connection` header, so "close" cannot be forced),
        // and a pooled socket to a previous engine's corpse is exactly what a
        // respawn leaves behind. Invalidating after the reply has fully landed
        // closes the socket cleanly, never mid-serve. Loopback: connect is free.
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        if let kind = op.writeKind { noteWrite(kind: kind) }
        do {
            let (data, resp) = try await session.data(for: op.request)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw BeamAPIError(what: "\(op.request.httpMethod ?? "GET") \(op.request.url?.path ?? "?") -> \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            op.slot.resolve(.success(data))
        } catch {
            op.slot.resolve(.failure(error))
        }
    }
}

/// Decodes to nil instead of failing the whole list, so one odd element can
/// never make a healthy engine look dead to the health loop.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension Output {
    private enum DecodeKeys: String, CodingKey {
        case id, name, type, selected, connected, streaming, volume, offset_ms
    }
    /// Only `id` is essential; OwnTone omits or nulls the rest for some devices.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DecodeKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        selected = (try? c.decodeIfPresent(Bool.self, forKey: .selected)) ?? false
        connected = try? c.decodeIfPresent(Bool.self, forKey: .connected)
        streaming = try? c.decodeIfPresent(Bool.self, forKey: .streaming)
        volume = (try? c.decodeIfPresent(Int.self, forKey: .volume)) ?? 0
        offset_ms = try? c.decodeIfPresent(Int.self, forKey: .offset_ms)
    }
}

public struct BeamAPI: Sendable {
    public let baseURL: URL
    private let lane: RequestLane

    /// How long a CALLER waits before giving up on a reply. Giving up never
    /// touches the socket (see the transport notes above): the request stays
    /// queued or in flight and its late reply is discarded.
    /// Reads are cheap and the health loop counts every miss as a strike, so
    /// they are bounded tighter than writes, which can legitimately sit behind
    /// a ~15 s RTSP handshake on OwnTone's command lane.
    static let readDeadline: TimeInterval = 6
    static let writeDeadline: TimeInterval = 15

    public init(port: Int = 3689) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        lane = RequestLane.shared(port: port)
    }

    /// Keep every request to this engine waiting for `seconds` (used right after
    /// a spawn so nothing hits the HTTP thread while it is still coming up).
    public func holdOff(for seconds: TimeInterval) { lane.holdOff(seconds) }

    // MARK: requests

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         deadline: TimeInterval? = nil, coalesceKey: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        // Split the query manually: appendingPathComponent would escape "?".
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        if let q = path.firstIndex(of: "?") {
            comps.path = String(path[..<q])
            comps.percentEncodedQuery = String(path[path.index(after: q)...])
        } else {
            comps.path = path
        }
        guard let url = comps.url else { throw BeamAPIError(what: "bad path \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("close", forHTTPHeaderField: "Connection")   // hint; the per-request session is what enforces it
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let limit = deadline ?? (method == "GET" ? Self.readDeadline : Self.writeDeadline)
        let slot = ReplySlot()
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)) } catch { return }
            slot.resolve(.failure(BeamAPIError(what: "\(method) \(path) no reply in \(Int(limit))s")))
        }
        defer { timer.cancel() }
        // Anything but a GET changes engine state; count it under a coarse kind.
        let kind: String? = method == "GET" ? nil : (coalesceKey?.split(separator: ":").first.map(String.init)
            ?? (path.hasPrefix("/api/outputs") ? "select" : "player"))
        lane.enqueue(RequestLane.Op(request: req, slot: slot, coalesceKey: coalesceKey, writeKind: kind))
        // Cancelling THIS task only stops the wait; the lane keeps (or drops,
        // if not yet written) the request itself.
        return try await withTaskCancellationHandler {
            try await slot.wait()
        } onCancel: {
            slot.resolve(.failure(CancellationError()))
        }
    }

    // MARK: API surface

    public func isUp(deadline: TimeInterval? = nil) async -> Bool {
        (try? await request("GET", "/api/config", deadline: deadline)) != nil
    }

    public func outputs() async throws -> [Output] {
        struct Wrapper: Decodable { let outputs: [Lossy<Output>] }
        let data = try await request("GET", "/api/outputs")
        return try JSONDecoder().decode(Wrapper.self, from: data).outputs.compactMap(\.value)
    }

    public func setOutputs(ids: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["outputs": ids])
        _ = try await request("PUT", "/api/outputs/set", body: body)
    }

    public func setSelected(outputID: String, selected: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["selected": selected])
        _ = try await request("PUT", "/api/outputs/\(outputID)", body: body)
    }

    /// Engine write counts by kind ("volume", "offset", "select", "player") over
    /// the last `window` seconds — each one is an RTSP command on OwnTone's shared
    /// player thread, so this is the number to watch when audio glitches.
    public func recentWrites(window: TimeInterval = 60) -> [String: Int] { lane.recentWrites(window: window) }
    public var totalWrites: Int { lane.totalWrites }

    public func setVolume(outputID: String, volume: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["volume": max(0, min(100, volume))])
        _ = try await request("PUT", "/api/outputs/\(outputID)", body: body,
                              coalesceKey: "volume:\(outputID)")
    }

    /// Per-speaker playback offset in milliseconds (positive = this speaker
    /// plays LATER). OwnTone applies it to the sync-packet anchor only — same
    /// bytes, shifted claimed play-time — and persists it in its own DB.
    /// Engine-enforced range is ±2000; we clamp to ±250 because this is a
    /// perceptual trim for inter-speaker DSP-latency differences, not a delay
    /// line — beyond ~100ms something else is wrong.
    public func setOffset(outputID: String, offsetMs: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["offset_ms": max(-250, min(250, offsetMs))])
        _ = try await request("PUT", "/api/outputs/\(outputID)", body: body,
                              coalesceKey: "offset:\(outputID)")
    }

    public func setMasterVolume(_ volume: Int) async throws {
        _ = try await request("PUT", "/api/player/volume?volume=\(max(0, min(100, volume)))")
    }

    /// Find the pipe track in the library by title (the FIFO file name).
    public func pipeTrackURI(named name: String) async throws -> String? {
        struct Track: Codable { let title: String; let uri: String }
        struct Items: Codable { let items: [Track] }
        struct Wrapper: Codable { let tracks: Items }
        let data = try await request("GET", "/api/search?type=tracks&query=\(name)")
        return try JSONDecoder().decode(Wrapper.self, from: data).tracks.items
            .first { $0.title == name }?.uri
    }

    public func playPipe(uri: String) async throws {
        _ = try await request("POST", "/api/queue/items/add?uris=\(uri)&clear=true")
        _ = try await request("PUT", "/api/player/play")
    }

    public func pause(deadline: TimeInterval? = nil) async throws {
        _ = try await request("PUT", "/api/player/pause", deadline: deadline)
    }

    public func stop() async throws {
        _ = try await request("PUT", "/api/player/stop")
    }

    public func playerState() async throws -> PlayerState {
        try JSONDecoder().decode(PlayerState.self, from: try await request("GET", "/api/player"))
    }

    public func rescan() async throws {
        _ = try await request("PUT", "/api/update")
    }

    // MARK: player model (OwnTone sources audio from its own library)

    /// Albums in the library, alphabetical. Best-effort: returns [] if the
    /// library is empty or still indexing.
    public func albums() async throws -> [LibraryAlbum] {
        struct Wrapper: Codable { let items: [LibraryAlbum] }
        let data = try await request("GET", "/api/library/albums")
        return try JSONDecoder().decode(Wrapper.self, from: data).items
    }

    /// The current play queue (title/artist/length per item).
    public func queue() async throws -> [QueueItem] {
        struct Wrapper: Codable { let items: [QueueItem] }
        let data = try await request("GET", "/api/queue")
        return try JSONDecoder().decode(Wrapper.self, from: data).items
    }

    /// Replace the queue with the given library URIs and start playing.
    public func playUris(_ uris: String, shuffle: Bool = false) async throws {
        var path = "/api/queue/items/add?uris=\(uris)&clear=true&playback=start"
        if shuffle { path += "&shuffle=true" }
        _ = try await request("POST", path)
    }

    /// Replace the queue with everything matching an OwnTone smart expression
    /// (e.g. "media_kind is music") and start playing.
    public func playExpression(_ expr: String, shuffle: Bool = false) async throws {
        let e = expr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? expr
        var path = "/api/queue/items/add?expression=\(e)&clear=true&playback=start"
        if shuffle { path += "&shuffle=true" }
        _ = try await request("POST", path)
    }

    /// Resume the existing queue (also used to recover after a device blip).
    public func play() async throws {
        _ = try await request("PUT", "/api/player/play")
    }

    public func next() async throws {
        _ = try await request("PUT", "/api/player/next")
    }

    public func previous() async throws {
        _ = try await request("PUT", "/api/player/previous")
    }
}
