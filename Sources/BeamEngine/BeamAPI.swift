// Thin client for OwnTone's JSON API on localhost.
// Every endpoint here was proven by curl during Phase 0.

import Foundation

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

public struct BeamAPI: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(port: Int = 3689) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let cfg = URLSessionConfiguration.ephemeral
        // This is loopback, not the internet, so a wedged command lane should
        // announce itself fast — but 2s was measured too tight for this engine
        // under real load: the flight log's own `apiSLOW`/`APIHANG` samples are
        // not spread out, they are PINNED at 2000-2009ms (72 of 78 measured) —
        // i.e. requests that were about to succeed, cut off by the clock rather
        // than by a real wedge. The health loop reads any such timeout as a
        // strike, and two strikes SIGKILLs the engine (DALIStore.
        // noteEngineAPIFailure) — so this one number was killing healthy engines
        // and producing the volume-write-succeeded-but-reported-failed loop
        // ("Kitchen volume drift engine=81 want=63 -> resend" in the debug
        // log). 4s keeps a comfortable margin under the 8s FIFO ceiling (still
        // two clean strikes before that matters) while giving a merely slow
        // response room to actually land instead of being read as a wedge.
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        session = URLSession(configuration: cfg)
    }

    // MARK: requests

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        // appendingPathComponent escapes "?" so split query manually:
        if let q = path.firstIndex(of: "?") {
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            comps.path = String(path[..<q])
            comps.percentEncodedQuery = String(path[path.index(after: q)...])
            req = URLRequest(url: comps.url!)
        }
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BeamAPIError(what: "\(method) \(path) -> \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    // MARK: API surface

    public func isUp() async -> Bool {
        (try? await request("GET", "/api/config")) != nil
    }

    public func outputs() async throws -> [Output] {
        struct Wrapper: Codable { let outputs: [Output] }
        let data = try await request("GET", "/api/outputs")
        return try JSONDecoder().decode(Wrapper.self, from: data).outputs
    }

    public func setOutputs(ids: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["outputs": ids])
        _ = try await request("PUT", "/api/outputs/set", body: body)
    }

    public func setSelected(outputID: String, selected: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["selected": selected])
        _ = try await request("PUT", "/api/outputs/\(outputID)", body: body)
    }

    public func setVolume(outputID: String, volume: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["volume": max(0, min(100, volume))])
        _ = try await request("PUT", "/api/outputs/\(outputID)", body: body)
    }

    /// Per-speaker playback offset in milliseconds (positive = this speaker
    /// plays LATER). OwnTone applies it to the sync-packet anchor only — same
    /// bytes, shifted claimed play-time — and persists it in its own DB.
    /// Engine-enforced range is ±2000; we clamp to ±250 because this is a
    /// perceptual trim for inter-speaker DSP-latency differences, not a delay
    /// line — beyond ~100ms something else is wrong.
    public func setOffset(outputID: String, offsetMs: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["offset_ms": max(-250, min(250, offsetMs))])
        _ = try await request("PUT", "/api/outputs/\(outputID)", body: body)
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

    public func pause() async throws {
        _ = try await request("PUT", "/api/player/pause")
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
