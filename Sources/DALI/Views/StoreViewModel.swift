// DALI — read-only presentation values derived from the store. Views ask
// these instead of each re-deriving labels and tones from `phase`, so the
// window, the menu bar and the footer can never disagree.

import SwiftUI

extension DALIStore {
    var isError: Bool {
        if case .error = phase { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let message) = phase { return message }
        return nil
    }

    /// The primary button's verb, shared with the menu bar.
    var primaryVerb: String {
        switch phase {
        case .idle: return mode == .player ? "Play to room" : "Play everywhere"
        case .starting: return "Connecting…"
        case .streaming:
            if mode == .player { return isPlaying ? "Pause" : "Resume" }
            return "Stop"
        case .error: return "Fix the issue below"
        }
    }

    /// Header status, sentence case.
    var statusText: String {
        switch roomChrome {
        case .idle: return "Ready"
        case .starting: return "Connecting"
        case .live: return "Live"
        case .muted: return "Muted"
        case .catchingUp: return "Catching up"
        case .speakerOut: return "Speaker out"
        case .error: return "Needs you"
        }
    }

    var statusTone: StatusDot.Tone {
        switch roomChrome {
        case .live, .catchingUp, .starting: return .live
        case .idle, .muted: return .idle
        case .speakerOut, .error: return .trouble
        }
    }

    /// Pulses while something is being connected — and only then.
    var statusPulsing: Bool {
        roomChrome == .starting || roomChrome == .catchingUp
    }

    /// What the room is behind the Mac, in ms: measured while live, the
    /// nominal figure for the configured buffer while idle.
    var roomDelayMs: Int {
        phase == .streaming ? max(0, safeInt((roomDelaySec * 1000).rounded()))
                            : RoomDelayPolicy.automaticStartBufferMs + 200
    }

    var roomDelayLabel: String {
        let ms = roomDelayMs
        return ms >= 1000 ? String(format: "%.1f s", Double(ms) / 1000) : "\(ms) ms"
    }

    /// The quiet "in sync" mark: the room is live and the browser companion
    /// is checking in (so video is being held to the room), or a picture is
    /// being held right now.
    var videoInSync: Bool {
        phase == .streaming && (browserExtensionVersion != nil || nowPlaying.anyHeld)
    }

    /// Whether the room has a front/back plan to draw.
    var hasRoomPlan: Bool { front != nil || back != nil }

    var enabledExtras: [RoomSpeaker] { extras.filter(\.enabled) }

    /// Now-playing items that actually reach the room: with one app picked
    /// as the source, only that app's.
    var audibleNowPlaying: [NowItem] {
        let all = nowPlaying.items
        if case .app(_, let name) = source {
            return all.filter { name.localizedCaseInsensitiveContains($0.app) }
        }
        return all
    }

    /// A pair is lit when the session is up, the pair is in the set, and its
    /// AirPlay session is live (or calmly reconnecting).
    func isLit(_ speaker: RoomSpeaker?) -> Bool {
        guard let speaker, speaker.enabled, phase == .streaming else { return false }
        return speaker.health == .live || speaker.health == .connecting
    }

    func tone(for speaker: RoomSpeaker) -> StatusDot.Tone {
        guard speaker.enabled, phase.isOn else { return .idle }
        switch speaker.health {
        case .live, .connecting: return .live
        case .trouble: return .trouble
        case .off: return .idle
        }
    }
}
