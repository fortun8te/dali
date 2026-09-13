// DALI — What is playing, right now.
//
// The room panel has one line under the pair rows that used to say
// "Everything your Mac plays is going to the room". True, and useless: the
// Mac is a mirror, and what matters is what it is mirroring. This object
// answers that with the two sources the app can actually see:
//
//   1. The browser. The Chrome extension already reports "is a video playing
//      in my frame" to its service worker once a second; that report now
//      carries the tab title, the host, whether the stream is live and whether
//      the extension is holding the picture back. The worker forwards the
//      union to the beacon as GET /now?d=<json>. Expires by itself: a browser
//      that stops reporting is a browser that stopped playing.
//   2. Spotify and Music, asked directly over Apple Events, only while they
//      are RUNNING (a `tell application` to an app that is not running would
//      launch it). Polled at 3 s while the room is live; nothing is asked when
//      the room is idle, so an idle DALI costs nothing.
//
// It is deliberately not a media-key/MediaRemote integration: that framework
// is private and, since macOS 15.4, refuses unentitled callers.

import Foundation
import AppKit
import Observation

struct NowItem: Equatable, Identifiable {
    enum Kind: Equatable { case video, music }
    var id: String { app + "|" + title }
    var title: String
    /// Where it comes from, for the eye: "YouTube", "Twitch", "Spotify", a host.
    var source: String
    /// Which process makes the sound: "Chrome", "Spotify", "Music".
    var app: String
    var kind: Kind
    /// A live stream: no track, no end. Shown as a quiet LIVE mark.
    var live: Bool
    /// The extension is holding this picture back by the room's delay.
    var held: Bool
    /// Cover art: Spotify's CDN URL, Music's exported file, a page's og:image.
    var artURL: URL? = nil
}

@MainActor
@Observable
final class NowPlayingMonitor {
    static let shared = NowPlayingMonitor()

    /// The browser's report, freshest first.
    private(set) var browser: [NowItem] = []
    private var browserAt: Date = .distantPast
    /// Spotify / Music, whichever is playing.
    private(set) var apps: [NowItem] = []

    private var pollTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    /// Fetched covers, keyed by URL. Small and bounded: the row shows one.
    private(set) var art: [URL: NSImage] = [:]
    @ObservationIgnored private var artInFlight = Set<URL>()

    /// The cover for `url` if it has arrived; starts the fetch if it has not.
    func artwork(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let img = art[url] { return img }
        guard !artInFlight.contains(url) else { return nil }
        artInFlight.insert(url)
        Task { [weak self] in
            let img: NSImage?
            if url.isFileURL {
                img = NSImage(contentsOf: url)
            } else if let (data, _) = try? await URLSession.shared.data(from: url) {
                img = NSImage(data: data)
            } else { img = nil }
            guard let self else { return }
            self.artInFlight.remove(url)
            if let img {
                if self.art.count > 12 { self.art.removeAll() }
                self.art[url] = img
            }
        }
        return nil
    }

    /// Browser reports go stale after this: the worker re-sends every 4 s
    /// while anything plays and once, empty, when it stops.
    private static let browserTTL: TimeInterval = 12

    /// Everything playing, held video first, then the rest in report order.
    var items: [NowItem] {
        let fresh = Date().timeIntervalSince(browserAt) < Self.browserTTL ? browser : []
        // Held video first, everything else in report order. Swift's sort is NOT
        // stable, and a comparator that returns false for equal elements let it
        // reorder equal rows between two redraws — so two things playing at once
        // could swap places on their own. Sorting on (held, position) is total,
        // which makes the order fixed.
        return (fresh + apps).enumerated().sorted { a, b in
            if a.element.held != b.element.held { return a.element.held }
            return a.offset < b.offset
        }.map(\.element)
    }

    var anyHeld: Bool {
        Date().timeIntervalSince(browserAt) < Self.browserTTL && browser.contains { $0.held }
    }

    // MARK: browser (via the beacon)

    /// `payload` is the JSON array the worker sends: [{"t","h","l","k"}].
    func browserReport(json payload: String) {
        guard let data = payload.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        var seen = Set<String>()
        var out: [NowItem] = []
        for o in arr {
            guard let raw = o["t"] as? String else { continue }
            let title = Self.cleanTitle(raw, host: o["h"] as? String ?? "")
            guard !title.isEmpty, seen.insert(title).inserted else { continue }
            let host = (o["h"] as? String ?? "").lowercased()
            let art = (o["a"] as? String).flatMap { URL(string: $0) }
                .flatMap { $0.scheme == "https" ? $0 : nil }
            out.append(NowItem(title: title,
                               source: Self.sourceName(host: host),
                               app: "Chrome",
                               kind: .video,
                               live: (o["l"] as? Int ?? 0) != 0,
                               held: (o["k"] as? Int ?? 0) != 0,
                               artURL: art))
        }
        browser = Array(out.prefix(3))
        browserAt = Date()
        armExpiry()
    }

    /// A stale report must fall off the panel even if no fresh one replaces it.
    private func armExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Self.browserTTL + 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if Date().timeIntervalSince(self.browserAt) >= Self.browserTTL { self.browser = [] }
        }
    }

    /// "Steely Dan – Aja (Remastered) - YouTube" -> "Steely Dan – Aja (Remastered)".
    private static func cleanTitle(_ t: String, host: String) -> String {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unread-count prefixes: "(3) Title".
        if let r = s.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        for suffix in [" - YouTube", " - Twitch", " – YouTube", " | Twitch", " - Netflix", " - Vimeo"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sourceName(host: String) -> String {
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") { return "TikTok" }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return "Instagram" }
        if host.contains("twitch") { return "Twitch" }
        if host.contains("netflix") { return "Netflix" }
        if host.contains("vimeo") { return "Vimeo" }
        if host.contains("kick.com") { return "Kick" }
        var h = host
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? "Chrome" : h
    }

    // MARK: Spotify / Music (Apple Events, only while running)

    /// Poll while the room is live; stop (and clear) when it is not.
    func setActive(_ on: Bool) {
        if on {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.apps = await Self.askApps()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        } else {
            pollTask?.cancel(); pollTask = nil
            apps = []
        }
    }

    private struct ScriptableApp {
        let bundleID: String, app: String, source: String
    }
    private static let scriptable = [
        ScriptableApp(bundleID: "com.spotify.client", app: "Spotify", source: "Spotify"),
        ScriptableApp(bundleID: "com.apple.Music", app: "Music", source: "Music"),
    ]

    private static func askApps() async -> [NowItem] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let targets = scriptable.filter { running.contains($0.bundleID) }
        guard !targets.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            var out: [NowItem] = []
            for t in targets {
                // osascript in its own process, not NSAppleScript in ours: Apple
                // Events block until the target answers, and an app that is
                // wedged must not take the panel with it. 2.5 s and it is killed.
                // Third line: the cover. Spotify hands over a CDN URL; Music
                // has only the bytes, which the script writes to a temp file
                // named after the track so a change of song is a new file.
                let src = t.app == "Spotify" ? """
                tell application id "\(t.bundleID)"
                    if player state is playing then
                        return (name of current track) & linefeed & (artist of current track) & linefeed & (artwork url of current track)
                    end if
                end tell
                return ""
                """ : """
                tell application id "\(t.bundleID)"
                    if player state is playing then
                        set tr to current track
                        set p to ""
                        try
                            set p to (POSIX path of (path to temporary items)) & "dali-cover-" & (database ID of tr) & ".img"
                            tell application "System Events" to set present to exists file p
                            if not present then
                                set d to raw data of artwork 1 of tr
                                set f to open for access POSIX file p with write permission
                                set eof f to 0
                                write d to f
                                close access f
                            end if
                        on error
                            set p to ""
                        end try
                        return (name of tr) & linefeed & (artist of tr) & linefeed & p
                    end if
                end tell
                return ""
                """
                guard let result = runOSAScript(src, timeout: 2.5), !result.isEmpty else { continue }
                let parts = result.components(separatedBy: "\n")
                let title = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let artist = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                let artRaw = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                let art: URL? = artRaw.isEmpty ? nil
                    : (artRaw.hasPrefix("/") ? URL(fileURLWithPath: artRaw) : URL(string: artRaw))
                guard !title.isEmpty else { continue }
                out.append(NowItem(title: artist.isEmpty ? title : "\(title) · \(artist)",
                                   source: t.source, app: t.app, kind: .music,
                                   live: false, held: false, artURL: art))
            }
            return out
        }.value
    }

    /// Run a script through /usr/bin/osascript; nil on error, timeout or a
    /// non-zero exit (including "not authorised" — the automation prompt is
    /// macOS's, shown once, and until it is answered this simply returns nil).
    nonisolated private static func runOSAScript(_ source: String, timeout: TimeInterval) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension DALIStore {
    /// Read through this in views so SwiftUI tracks the monitor, not the store.
    var nowPlaying: NowPlayingMonitor { NowPlayingMonitor.shared }
}
