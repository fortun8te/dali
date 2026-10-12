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

public struct BeamAPIError: LocalizedError, CustomStringConvertible {
    public let what: String
    public var description: String { "BeamAPI: \(what)" }
    public var errorDescription: String? { what }
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

    /// The shared engine generation. Work queued for an older generation fails.
    public var sessionEpoch: UInt64 { lane.sessionEpoch }

    @discardableResult
    public func invalidateSession() -> UInt64 { lane.invalidateSession() }

    /// Supervisor-only lifecycle fences. Sent sockets always drain naturally.
    func suspendSession() { lane.suspendSession() }
    func resumeSession() { lane.resumeSession() }
    func waitForDrain() async { await lane.waitForDrain() }

    /// How long a CALLER waits before giving up on a reply. Giving up never
    /// touches a sent socket. Unsent work is removed immediately, while a sent
    /// request drains and its late reply is discarded.
    /// Reads are cheap and the health loop counts every miss as a strike, so
    /// they are bounded tighter than writes, which can legitimately sit behind
    /// a ~15 s RTSP handshake on OwnTone's command lane.
    static let readDeadline: TimeInterval = 6
    static let writeDeadline: TimeInterval = 15

    public init(port: Int = 3689) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        lane = RequestLane.shared(port: port)
    }

    /// Tests use a private lane with a controlled transport, never a live port.
    init(port: Int = 0, lane: RequestLane) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.lane = lane
    }

    /// Keep every request to this engine waiting for `seconds` (used right after
    /// a spawn so nothing hits the HTTP thread while it is still coming up).
    public func holdOff(for seconds: TimeInterval) { lane.holdOff(seconds) }

    // MARK: requests

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         deadline: TimeInterval? = nil, coalesceKey: String? = nil,
                         epoch: UInt64? = nil) async throws -> Data {
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
        let kind: String? = method == "GET" ? nil : (coalesceKey?.split(separator: ":").first.map(String.init)
            ?? (path.hasPrefix("/api/outputs") ? "select" : "player"))
        return try await lane.send(req, deadline: limit, epoch: epoch ?? sessionEpoch,
                                   coalesceKey: coalesceKey, writeKind: kind)

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
        _ = try await request("PUT", "/api/outputs/set", body: body, coalesceKey: "select:room")
    }

    public func setSelected(outputID: String, selected: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["selected": selected])
        _ = try await request("PUT", "/api/outputs/\(outputID)", body: body,
                              coalesceKey: "select:\(outputID)")
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

    /// A successful HTTP acknowledgement confirms this command reached OwnTone.
    /// A replaced command was never sent. Cancellation, timeout and session
    /// changes leave application unknown until a fresh observation arrives.
    public func setVolumeConfirmed(outputID: String, volume: Int) async -> BeamWriteResult {
        let epoch = sessionEpoch
        do {
            try await setVolume(outputID: outputID, volume: volume)
            return epoch == sessionEpoch ? .applied : .unknown
        } catch BeamRequestError.superseded {
            return .superseded
        } catch {
            return .unknown
        }
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
        _ = try await request("PUT", "/api/player/volume?volume=\(max(0, min(100, volume)))",
                              coalesceKey: "volume:master")
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
        let epoch = sessionEpoch
        _ = try await request("POST", "/api/queue/items/add?uris=\(uri)&clear=true", epoch: epoch)
        _ = try await request("PUT", "/api/player/play", epoch: epoch)
    }

    public func pause(deadline: TimeInterval? = nil) async throws {
        _ = try await request("PUT", "/api/player/pause", deadline: deadline)
    }

    public func stop() async throws {
        _ = try await request("PUT", "/api/player/stop")
    }

    public func playerState(deadline: TimeInterval? = nil) async throws -> PlayerState {
        try JSONDecoder().decode(PlayerState.self, from: try await request("GET", "/api/player", deadline: deadline))
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
