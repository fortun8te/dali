import Foundation
import SwiftUI
import Observation
import CoreAudio
import AudioToolbox

// These UI-only stubs let this executable compile the unmodified production
// Desk-mode file. Tests instantiate only an injected state, never the singleton.
@MainActor @Observable final class DALIStore {
    enum Phase { case idle, streaming; var isOn: Bool { self == .streaming } }
    var phase = Phase.idle
    var playerMode = false
    func stopPlayback() { phase = .idle }
    func stopStream() { phase = .idle }
    func dlog(_ value: String) {}
}
extension Color {
    static let hairline = Color.gray
    static let paper = Color.white
    static let paper35 = Color.gray
    static let accentBlue = Color.blue
    static let amber = Color.orange
}
extension Font {
    static let bodyBase = Font.body
    static let badge = Font.caption
}

@MainActor private final class DeskHardware {
    let previous = WiredOutputDevice(id: 1, name: "Fixture Mac", uid: "original")
    let amp = WiredOutputDevice(id: 2, name: "Fixture POWERNODE", uid: "amp")
    let alternative = WiredOutputDevice(id: 3, name: "Fixture Headphones", uid: "headphones")
    var available: [WiredOutputDevice] = []
    var current: WiredOutputDevice?
    var failure: OSStatus = noErr
    var calls: [AudioObjectID] = []
    var events: [String] = []
    init() { available = [previous, amp, alternative]; current = previous }
    var adapter: VideoModeState.Hardware {
        .init(firstMatching: { self.available.first { $0.uid == "amp" } },
              defaultOutput: { self.current },
              device: { uid in self.available.first { $0.uid == uid } },
              setDefaultOutput: { id in
                  self.calls.append(id); self.events.append("switch")
                  if self.failure == noErr { self.current = self.available.first { $0.id == id } }
                  return self.failure
              })
    }
}

@main struct DeskModeTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !value() { throw NSError(domain: "DeskModeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func fixture() -> (DeskHardware, UserDefaults, VideoModeState, String) {
            let name = "dali-video-mode-fixture-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            let hardware = DeskHardware()
            let state = VideoModeState(defaults: defaults, hardware: hardware.adapter, observeDevices: false)
            return (hardware, defaults, state, name)
        }
        let previousKey = "dali.videoMode.previousOutputUID"
        let activeKey = "dali.videoMode.active"

        do {
            let (h, d, s, name) = fixture(); defer { d.removePersistentDomain(forName: name) }
            try expect(s.enter { h.events.append("stop") }, "entry succeeds")
            try expect(h.events == ["switch", "stop"], "output must switch before stopping AirPlay")
            try expect(s.isActive && h.current == h.amp, "entry owns amp output")
            try expect(d.string(forKey: previousKey) == h.previous.uid, "entry remembers original persistent UID")
            try expect(s.exit(), "exit succeeds")
            try expect(h.current == h.previous, "exit restores original output")
            try expect(!s.isActive && d.string(forKey: previousKey) == nil, "successful restore clears state")
        }
        do {
            let (h, d, s, name) = fixture(); defer { d.removePersistentDomain(forName: name) }
            h.failure = -50
            try expect(!s.enter { h.events.append("stop") }, "failed switch refuses entry")
            try expect(h.events == ["switch"], "failed switch does not stop AirPlay")
            try expect(h.current == h.previous && !s.isActive, "failed entry leaves output unchanged")
            try expect(d.string(forKey: previousKey) == nil, "failed entry does not replace saved route")
        }
        do {
            let (h, d, s, name) = fixture(); defer { d.removePersistentDomain(forName: name) }
            _ = s.enter {}
            h.failure = -50
            try expect(!s.exit(), "failed restore reports failure")
            try expect(s.isActive && d.bool(forKey: activeKey), "failed restore retains active ownership")
            try expect(d.string(forKey: previousKey) == h.previous.uid, "failed restore retains original UID")
            try expect(s.enter {}, "re-enter does not overwrite pending restoration")
            try expect(d.string(forKey: previousKey) == h.previous.uid, "re-enter preserves original UID")
            h.failure = noErr
            try expect(s.exit() && h.current == h.previous, "failed exit can be retried successfully")
        }
        do {
            let (h, d, s, name) = fixture(); defer { d.removePersistentDomain(forName: name) }
            _ = s.enter {}
            h.available.removeAll { $0 == h.amp }; h.current = nil
            s.refresh()
            try expect(h.current == h.previous && !s.isActive, "amp unplug restores original output")
            try expect(d.string(forKey: previousKey) == nil, "unplug clears only after restoration")
        }
        do {
            let (h, d, s, name) = fixture(); defer { d.removePersistentDomain(forName: name) }
            _ = s.enter {}
            h.available.removeAll { $0 == h.amp || $0 == h.previous }; h.current = nil
            s.refresh()
            try expect(s.isActive && s.lastError != nil, "missing original output keeps restoration pending")
            try expect(d.string(forKey: previousKey) == h.previous.uid, "missing route UID survives unplug")
            let restarted = VideoModeState(defaults: d, hardware: h.adapter, observeDevices: false)
            try expect(restarted.isActive, "pending restore survives state recreation")
            h.available.append(h.amp); h.current = h.alternative
            restarted.refresh()
            try expect(restarted.isActive, "amp return must not discard an unresolved restoration")
            try expect(d.string(forKey: previousKey) == h.previous.uid, "automatic fallback cannot replace saved UID")
            h.available.append(h.previous)
            restarted.refresh()
            try expect(!restarted.isActive && h.current == h.previous, "pending restore retries when original returns")
        }
        do {
            let (h, d, s, name) = fixture(); defer { d.removePersistentDomain(forName: name) }
            _ = s.enter {}
            h.current = h.alternative
            let before = h.calls.count
            s.refresh()
            try expect(!s.isActive && h.current == h.alternative, "manual output selection is respected")
            try expect(h.calls.count == before, "manual selection is not overwritten")
            try expect(d.string(forKey: previousKey) == nil, "manual selection relinquishes old restoration state")
        }
        do {
            let (h, d, s, name) = fixture(); defer { d.removePersistentDomain(forName: name) }
            h.current = h.amp
            try expect(s.enter {}, "entry while already on amp succeeds")
            try expect(d.string(forKey: previousKey) == nil, "amp is not stored as its own prior output")
            let before = h.calls.count
            try expect(s.exit(), "exit without original route succeeds")
            try expect(h.calls.count == before && h.current == h.amp, "exit does not invent a route")
        }
        print("PASS: \(checks) Desk-mode checks with isolated preferences and fake audio devices")
    }
}
