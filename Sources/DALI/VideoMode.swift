// DALI — Video mode ("Desk mode"): wired, lip-synced playback.
// ============================================================
// AirPlay buys its rock-solid multi-room sync with ~450ms of scheduling lead.
// That is fine for music and fatal for picture: nothing lip-syncs.
//
// The POWERNODE N331 that drives the front DALI Opticons also has a USB-C
// PC-audio input, so the Mac can see it as an ordinary CoreAudio output
// device. Measured on this machine: 46 frames latency + 46 frames safety
// offset + a 512-frame buffer at 44.1kHz ~= 13.7ms. That is lip sync.
//
// A hybrid (wired front + AirPlay back) was considered and rejected: a synced
// AirPlay group is only as fast as its slowest member, and running the wired
// amp in its own clock domain alongside it gives two clocks with no feedback
// signal between them — they smear audibly within about five minutes.
//
// So Video mode is deliberately exclusive and deliberately boring:
//   stream stopped -> Sonos silent -> system output switched to the wired amp.
// Nothing is compromised; the room just shrinks to the front pair for the
// length of the film.
//
// ---------------------------------------------------------------
// Why the state lives in its own object
// ---------------------------------------------------------------
// `DALIStore` is `@MainActor @Observable`, and a Swift extension cannot add
// stored properties — so `isVideoMode` cannot simply be declared here. The
// three ways out were: (a) a UserDefaults-backed computed property, (b) a
// global holder, (c) a small `@Observable` companion object.
//
// (a) loses observation: `@AppStorage` is a SwiftUI property wrapper, not
// something an `@Observable` class can vend, so views would not redraw when
// the mode flipped from code. (b) has the same problem plus no ownership.
// (c) keeps the app's existing idiom exactly — SwiftUI's observation tracking
// follows the read through `store.videoMode.isActive` and registers on the
// companion, so a `Toggle` bound to it behaves like any other store property.
// The companion is where the *persistent* bits (the remembered previous output
// device) get written to UserDefaults, which is the right place for them: they
// must survive a crash so the user's speakers can be given back.

import Foundation
import SwiftUI
import Observation
import CoreAudio
import AudioToolbox

// MARK: - Device model

/// A CoreAudio output device, reduced to the three things this feature needs.
struct WiredOutputDevice: Equatable, Identifiable, Sendable {
    /// Session-scoped CoreAudio object id. Never persist this — it is not
    /// stable across reboots or replugs. Persist `uid` instead.
    let id: AudioObjectID
    let name: String
    let uid: String
}

// MARK: - CoreAudio plumbing

/// Thin, read-mostly wrapper over the HAL. Every call is failable and returns
/// nil / an OSStatus rather than trapping: an audio device can vanish between
/// two lines of code.
enum WiredOutput {

    /// Name fragments that identify the wired amplifier, matched
    /// case-insensitively as a substring. A list, not a constant, so a second
    /// wired amp (or a renamed one) is a one-line change here and nowhere else.
    static let deviceNameNeedles = ["powernode"]

    // MARK: enumeration

    /// Every device that can actually play audio, i.e. has at least one output
    /// stream with channels. Input-only devices (microphones) are filtered out.
    static func outputDevices() -> [WiredOutputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard id != AudioObjectID(kAudioObjectUnknown),
                  hasOutputStreams(id),
                  let uid = uid(of: id) else { return nil }
            return WiredOutputDevice(id: id, name: name(of: id) ?? uid, uid: uid)
        }
    }

    /// The wired amp, if it is plugged in and awake.
    static func firstMatching(_ needles: [String] = deviceNameNeedles) -> WiredOutputDevice? {
        outputDevices().first { dev in
            let hay = dev.name.lowercased()
            return needles.contains { hay.contains($0.lowercased()) }
        }
    }

    /// Look a device back up by its persistent UID (used to restore the
    /// previous default output when leaving video mode).
    static func device(uid wanted: String) -> WiredOutputDevice? {
        outputDevices().first { $0.uid == wanted }
    }

    // MARK: default output device

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The device macOS is currently sending audio to.
    static func defaultOutput() -> WiredOutputDevice? {
        var addr = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown),
              let uid = uid(of: device) else { return nil }
        return WiredOutputDevice(id: device, name: name(of: device) ?? uid, uid: uid)
    }

    /// Point the system output at `device`. Returns the raw OSStatus so the
    /// caller can tell the user the truth instead of silently doing nothing.
    static func setDefaultOutput(_ device: AudioObjectID) -> OSStatus {
        var addr = defaultOutputAddress
        var id = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    // MARK: per-device properties

    static func name(of device: AudioObjectID) -> String? {
        cfString(device, kAudioObjectPropertyName)
    }

    static func uid(of device: AudioObjectID) -> String? {
        cfString(device, kAudioDevicePropertyDeviceUID)
    }

    private static func cfString(_ device: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    /// True when the device has an output stream with at least one channel.
    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr
        else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Human-readable OSStatus, so an error message says something.
    static func describe(_ status: OSStatus) -> String {
        // Most CoreAudio codes are four-char literals ('!obj', 'nope', ...).
        let bytes = [UInt8((status >> 24) & 0xFF), UInt8((status >> 16) & 0xFF),
                     UInt8((status >> 8) & 0xFF), UInt8(status & 0xFF)]
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        if printable, let fourCC = String(bytes: bytes, encoding: .ascii) {
            return "'\(fourCC)' (\(status))"
        }
        return "\(status)"
    }
}

// MARK: - Observable companion state

/// The stored half of video mode. See the file header for why this is a
/// separate object instead of properties on `DALIStore`.
@MainActor
@Observable
final class VideoModeState {
    static let shared = VideoModeState()

    private static let previousUIDKey = "dali.videoMode.previousOutputUID"
    private static let activeKey = "dali.videoMode.active"

    /// The wired amp, refreshed whenever the device list changes. nil = unplugged.
    private(set) var wiredDevice: WiredOutputDevice?
    /// True while the Mac's output is parked on the wired amp by us.
    private(set) var isActive: Bool = false
    /// Last thing that went wrong, shown in the UI. Cleared on the next success.
    private(set) var lastError: String?

    /// Name the UI shows, e.g. "Bluesound POWERNODE".
    var wiredDeviceName: String? { wiredDevice?.name }
    /// Whether the control should be enabled at all.
    var isAvailable: Bool { wiredDevice != nil }

    /// UID (not object id — object ids are session-scoped) of whatever the
    /// system default output was before we took it over. Persisted so a crash
    /// mid-film does not strand the user on the amp with no way back.
    private var previousOutputUID: String? {
        get { UserDefaults.standard.string(forKey: Self.previousUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.previousUIDKey) }
    }

    private init() {
        isActive = UserDefaults.standard.bool(forKey: Self.activeKey)
        refresh()
        Self.installDeviceListListener()
    }

    /// Re-read the device list and reconcile our flag with reality. Cheap
    /// enough to call on every appearance of the settings pane.
    func refresh() {
        wiredDevice = WiredOutput.firstMatching()

        // We only claim to be in video mode if the wired amp is present *and*
        // it is genuinely the system default right now. The user can change
        // output in Sound settings or via a menu-bar click behind our back, and
        // pretending otherwise would leave a lit toggle over silent speakers.
        if isActive {
            let currentUID = WiredOutput.defaultOutput()?.uid
            if wiredDevice == nil || currentUID != wiredDevice?.uid {
                setActive(false)
            }
        }
    }

    fileprivate func setActive(_ on: Bool) {
        isActive = on
        UserDefaults.standard.set(on, forKey: Self.activeKey)
    }

    fileprivate func rememberPrevious(_ uid: String?) { previousOutputUID = uid }
    fileprivate var previousUID: String? { previousOutputUID }
    fileprivate func forgetPrevious() { previousOutputUID = nil }

    fileprivate func fail(_ message: String) { lastError = message }
    fileprivate func clearError() { lastError = nil }

    /// Wake up when a device is plugged in or pulled out, so the control
    /// enables itself the moment the USB-C cable goes in.
    private nonisolated static func installDeviceListListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
        ) { _, _ in
            Task { @MainActor in VideoModeState.shared.refresh() }
        }
    }
}

// MARK: - Store API

extension DALIStore {

    /// The observable companion. Read through this in views
    /// (`store.videoMode.isActive`) so SwiftUI tracks the right object.
    var videoMode: VideoModeState { VideoModeState.shared }

    /// True while system audio is parked on the wired amp.
    var isVideoMode: Bool { videoMode.isActive }

    /// Display name of the wired amp, or nil when it is not connected.
    var wiredDeviceName: String? { videoMode.wiredDeviceName }

    /// Copy for a disabled control — the user should always know *why* it is off.
    var videoModeUnavailableReason: String? {
        videoMode.isAvailable ? nil : "Connect the POWERNODE by USB-C"
    }

    /// Stop the AirPlay stream and hand system audio to the wired amp.
    /// Returns false (and sets `videoMode.lastError`) if anything stopped it.
    @discardableResult
    func enterVideoMode() -> Bool {
        let state = videoMode
        state.refresh()

        guard let wired = state.wiredDevice else {
            state.fail("The POWERNODE isn't connected. Plug it into the Mac with USB-C.")
            dlog("video mode refused: no wired device matching \(WiredOutput.deviceNameNeedles)")
            return false
        }
        guard !state.isActive else { return true }

        // Remember where audio was going *before* anything moves, so exit has
        // somewhere to put it back. Read it first: stopping the stream can make
        // OwnTone's virtual outputs disappear.
        let previous = WiredOutput.defaultOutput()

        // Video mode is exclusive by design (see file header): the AirPlay group
        // and the wired amp are two clock domains that would drift apart.
        if phase.isOn { playerMode ? stopPlayback() : stopStream() }

        let status = WiredOutput.setDefaultOutput(wired.id)
        guard status == noErr else {
            state.fail("macOS refused to switch output to \(wired.name) — error \(WiredOutput.describe(status)).")
            dlog("video mode FAILED: setDefaultOutput(\(wired.name)) -> \(status)")
            return false
        }

        // Don't record the amp as its own "previous": if the user was already
        // listening through USB-C, exiting should be a no-op, not a loop.
        state.rememberPrevious(previous?.uid == wired.uid ? nil : previous?.uid)
        state.setActive(true)
        state.clearError()
        dlog("video mode ON -> \(wired.name) (was: \(previous?.name ?? "unknown"))")
        return true
    }

    /// Give the Mac's output back to whatever had it before.
    ///
    /// Deliberately does NOT restart the AirPlay stream. Leaving video mode
    /// usually means the film ended, not that the room should suddenly start
    /// playing again — and an automatic restart would push audio at the whole
    /// house without anyone asking. The user presses play when they want the
    /// room back.
    func exitVideoMode() {
        let state = videoMode
        guard state.isActive else { return }

        // The flag drops either way: once we stop claiming the output, the
        // toggle must not stay lit. The remembered UID is only *forgotten* on a
        // successful restore, so a transient failure can still be retried by
        // hand from System Settings without us having thrown the answer away.
        defer { state.setActive(false) }

        guard let uid = state.previousUID else {
            // Nothing to restore (we were already on the amp when we entered,
            // or the app was relaunched with the key cleared). Leaving output
            // where it is beats guessing at a device.
            state.clearError()
            dlog("video mode OFF (no previous device recorded; output left as-is)")
            return
        }
        guard let previous = WiredOutput.device(uid: uid) else {
            state.fail("The previous output device is gone. Pick one in System Settings › Sound.")
            dlog("video mode OFF but previous device \(uid) is no longer present")
            state.forgetPrevious()
            return
        }

        let status = WiredOutput.setDefaultOutput(previous.id)
        guard status == noErr else {
            state.fail("Couldn't switch back to \(previous.name) — error \(WiredOutput.describe(status)).")
            dlog("video mode OFF FAILED: setDefaultOutput(\(previous.name)) -> \(status)")
            return
        }
        state.forgetPrevious()
        state.clearError()
        dlog("video mode OFF -> \(previous.name)")
    }
}

// MARK: - Control

/// Compact control for the Engine settings pane.
///
/// Named "Desk mode", not "Video mode": the pane already has a Music/Video
/// segmented picker directly above, and that one is about the AirPlay *start
/// buffer* (700ms vs 500ms) — an entirely different thing. Two controls called
/// "Video" a centimetre apart, one of which silently stops the stream, is a
/// trap. "Desk mode (wired, lip-sync)" says where the sound goes, how, and why.
struct VideoModeControl: View {
    @Environment(DALIStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.hairline)

            Toggle("Desk mode (wired, lip-sync)", isOn: Binding(
                get: { store.isVideoMode },
                set: { on in
                    if on { store.enterVideoMode() } else { store.exitVideoMode() }
                }))
                .font(.bodyBase)
                .foregroundStyle(store.videoMode.isAvailable ? Color.paper : Color.paper35)
                .toggleStyle(.switch).controlSize(.small).tint(.accentBlue)
                .disabled(!store.videoMode.isAvailable)

            Text(blurb)
                .font(.badge)
                .foregroundStyle(store.videoMode.lastError != nil ? Color.amber : Color.paper35)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { store.videoMode.refresh() }
    }

    private var blurb: String {
        if let error = store.videoMode.lastError { return error }
        if let reason = store.videoModeUnavailableReason { return "\(reason) to play at ~14 ms." }
        let name = store.wiredDeviceName ?? "the amp"
        return store.isVideoMode
            ? "Playing through \(name) over USB-C at ~14 ms. The Sonos is silent until you turn this off and press play."
            : "Sends everything to \(name) over USB-C at ~14 ms — real lip sync. Stops the stream; the back speakers go quiet."
    }
}
