// Calls stay on the Mac.
//
// AirPlay adds most of a second of delay (see RoomDelayPolicy), far beyond the
// ~150 ms a conversation tolerates, and a call app's echo canceller only hears
// what it plays on the Mac's own output, not the room speakers a moment later.
// So DALI (1) leaves known call apps out of the system tap: excluded processes
// are not muted by `.mutedWhenTapped` and keep playing on the Mac or headphones
// with no added delay; and (2) turns background room audio down while an
// excluded call app has its microphone open. Browser voice remains in the
// captured mix, so its microphone must not turn down its own replies.
//
// macOS has no public "call in progress" API for third-party apps, so both use
// Core Audio's process objects (macOS 14+), the same objects process taps use.

import Foundation
import CoreAudio

public enum CallAudio {
    /// Owner decision 2026-10-19: calls must play through the room speakers, not the
    /// Mac's. So call apps stay in the captured mix like any other audio, and
    /// nothing ducks the room for them (the call itself is in that mix). The
    /// list and classification below remain for this switch and for tests.
    public static let keepCallsOnMac = false

    /// Bundle IDs whose audio is a live conversation. Matching also covers each
    /// app's helpers ("<id>.helper", "<id>.helper.Renderer"), where Electron
    /// apps actually play sound. Fixed on purpose: no settings to manage.
    public static let callAppBundleIDs: [String] = [
        "com.apple.FaceTime",
        "com.apple.avconferenced",                         // FaceTime / FaceTime Audio media
        "com.apple.telephonyutilities.callservicesd",      // iPhone calls relayed to the Mac
        "com.apple.mobilephone",                           // Phone app (macOS 26)
        "ru.keepcoder.Telegram",                           // Telegram (App Store)
        "org.telegram.desktop",                            // Telegram Desktop
        "org.whispersystems.signal-desktop",               // Signal
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "net.whatsapp.WhatsApp",
        "desktop.WhatsApp",
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
        "Cisco-Systems.Spark",                             // Webex
        "com.skype.skype",
        "com.cisco.webexmeetingsapp",
        "com.openai.chat",                                 // ChatGPT desktop
        "com.openai.codex",                                // ChatGPT/Codex voice desktop
    ]

    /// Pure classification, unit tested.
    public static func isCallApp(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return callAppBundleIDs.contains { known in
            let k = known.lowercased()
            return id == k || id.hasPrefix(k + ".")
        }
    }

    public struct Process: Equatable, Sendable {
        public let object: AudioObjectID
        public let pid: pid_t
        public let bundleID: String?
        public let isRunningInput: Bool
        public init(object: AudioObjectID, pid: pid_t, bundleID: String?, isRunningInput: Bool) {
            self.object = object; self.pid = pid; self.bundleID = bundleID; self.isRunningInput = isRunningInput
        }
    }

    /// Process objects of call apps currently known to Core Audio.
    public static func callProcessObjects(in processes: [Process]) -> [AudioObjectID] {
        processes.filter { isCallApp(bundleID: $0.bundleID) }.map(\.object)
    }

    /// Duck only speech that is kept outside the captured mix. An arbitrary
    /// microphone (browser voice, dictation, recording) is not enough evidence:
    /// its reply may be the very audio the room is supposed to reproduce.
    public static func micInUse(in processes: [Process], ownPID: pid_t,
                                source: ProcessTap.Source = .system) -> Bool {
        if case .process(let selectedPID) = source,
           processes.contains(where: { $0.pid == selectedPID && isCallApp(bundleID: $0.bundleID) }) {
            return false // Explicitly capturing a call must not duck that call.
        }
        return processes.contains {
            guard $0.isRunningInput, $0.pid != ownPID, isCallApp(bundleID: $0.bundleID) else { return false }
            // This desktop helper observes SYSTEM OUTPUT for an audio meter.
            // Core Audio reports input IO for taps too; it is not a voice call
            // or a microphone. Do not leave the whole room ducked while idle.
            let bundle = $0.bundleID?.lowercased() ?? ""
            if bundle == "com.openai.codex.system-audio-spectrum" ||
               bundle.hasPrefix("com.openai.codex.system-audio-spectrum.") { return false }
            if case .process(let selectedPID) = source, $0.pid == selectedPID { return false }
            return true
        }
    }

    // MARK: HAL reads (non-realtime threads only)

    public static func currentProcesses() -> [Process] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        return ids.compactMap { obj in
            guard obj != kAudioObjectUnknown, let pid = pidOf(obj) else { return nil }
            return Process(object: obj, pid: pid, bundleID: bundleIDOf(obj),
                           isRunningInput: uint32(obj, kAudioProcessPropertyIsRunningInput) == 1)
        }
    }

    public static func micInUseByOtherApps(source: ProcessTap.Source = .system) -> Bool {
        guard keepCallsOnMac else { return false }
        return micInUse(in: currentProcesses(), ownPID: getpid(), source: source)
    }

    /// Whether a Core Audio process object belongs to a call app (and so is
    /// left out of a .system tap).
    public static func isCallProcess(_ obj: AudioObjectID) -> Bool {
        keepCallsOnMac && isCallApp(bundleID: bundleIDOf(obj))
    }

    private static func pidOf(_ obj: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    private static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bundleIDOf(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Room ducking decision. Duck at once when a microphone opens; restore only
/// after it has been closed for `releaseAfter` seconds, so a call app briefly
/// reopening its mic (device switch, mute toggle) does not pump the music.
public struct CallDuck: Sendable {
    public static let duckedGain = 0.1          // about -20 dB
    public static let releaseAfter = 3.0
    public private(set) var isDucked = false
    private var lastMicAt = -Double.infinity

    public init() {}

    public var gain: Double { isDucked ? Self.duckedGain : 1 }

    /// Feed one observation; returns true when `isDucked` changed.
    public mutating func update(micInUse: Bool, now: Double) -> Bool {
        let was = isDucked
        if micInUse {
            lastMicAt = now
            isDucked = true
        } else if isDucked, now - lastMicAt >= Self.releaseAfter {
            isDucked = false
        }
        return was != isDucked
    }
}
