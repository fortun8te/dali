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
//   system output switched successfully -> stream stopped -> Sonos silent.
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
    private static let restorePendingKey = "dali.videoMode.restorePending"

    struct Hardware {
        var firstMatching: @MainActor () -> WiredOutputDevice?
        var defaultOutput: @MainActor () -> WiredOutputDevice?
        var device: @MainActor (String) -> WiredOutputDevice?
        var setDefaultOutput: @MainActor (AudioObjectID) -> OSStatus

        static var live: Hardware {
            Hardware(firstMatching: { WiredOutput.firstMatching() },
                     defaultOutput: { WiredOutput.defaultOutput() },
                     device: { WiredOutput.device(uid: $0) },
                     setDefaultOutput: { WiredOutput.setDefaultOutput($0) })
        }
    }
    private let defaults: UserDefaults
    private let hardware: Hardware
    private var restorePending: Bool {
        get { defaults.bool(forKey: Self.restorePendingKey) }
        set { defaults.set(newValue, forKey: Self.restorePendingKey) }
    }

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
        get { defaults.string(forKey: Self.previousUIDKey) }
        set { defaults.set(newValue, forKey: Self.previousUIDKey) }
    }

    init(defaults: UserDefaults = .standard, hardware: Hardware? = nil,
         observeDevices: Bool = true) {
        self.defaults = defaults
        self.hardware = hardware ?? .live
        isActive = defaults.bool(forKey: Self.activeKey)
        refresh()
        if observeDevices { Self.installDeviceListListener() }
    }

    /// Re-read the device list and reconcile our flag with reality. Cheap
    /// enough to call on every appearance of the settings pane.
    func refresh() {
        let found = hardware.firstMatching()
        if found != wiredDevice { wiredDevice = found }
        guard isActive else { return }
        if found == nil || restorePending {
            // Unplugging must restore the saved route, not discard the only
            // state that lets Exit retry a temporarily missing output.
            exit()
        } else if let current = hardware.defaultOutput(), current.uid != found?.uid {
            // A deliberate external output selection takes ownership from us.
            // Respect it rather than switching it back on a later refresh.
            finish()
        }
    }

    @discardableResult
    func enter(stopRoom: () -> Void) -> Bool {
        refresh()
        guard let wired = wiredDevice else {
            fail("The POWERNODE isn't connected. Plug it into the Mac with USB-C.")
            return false
        }
        guard !isActive else { return true }
        let previous = hardware.defaultOutput()
        let status = hardware.setDefaultOutput(wired.id)
        guard status == noErr else {
            fail("macOS refused to switch output to \(wired.name). Error \(WiredOutput.describe(status)).")
            return false
        }
        // A legacy failed exit can leave a saved UID while already on the amp.
        // Do not replace that restoration target with the amp itself.
        if previous?.uid != wired.uid { rememberPrevious(previous?.uid) }
        setActive(true)
        clearError()
        // A failed HAL switch must leave the AirPlay room untouched.
        stopRoom()
        return true
    }

    @discardableResult
    func exit() -> Bool {
        guard isActive else { return true }
        guard let uid = previousUID else {
            // The amp was already selected before Enter. There is no previous
            // route to invent or change in this case.
            finish()
            return true
        }
        guard let previous = hardware.device(uid) else {
            restorePending = true
            fail("The previous output device is gone. Reconnect it and retry, or choose an output in Sound settings.")
            return false
        }
        let status = hardware.setDefaultOutput(previous.id)
        guard status == noErr else {
            restorePending = true
            fail("Couldn't switch back to \(previous.name). Error \(WiredOutput.describe(status)).")
            return false
        }
        finish()
        return true
    }

    private func finish() {
        restorePending = false
        setActive(false)
        forgetPrevious()
        clearError()
    }

    fileprivate func setActive(_ on: Bool) {
        if isActive != on { isActive = on }
        defaults.set(on, forKey: Self.activeKey)
    }

    /// Plugging in one USB device fires the device-list listener several times
    /// in a burst (aggregate/virtual devices appear one by one), and every
    /// refresh walks the whole HAL device list on the main thread. Coalesce.
    private var refreshPending = false
    fileprivate func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    fileprivate func rememberPrevious(_ uid: String?) { previousOutputUID = uid }
    fileprivate var previousUID: String? { previousOutputUID }
    fileprivate func forgetPrevious() { previousOutputUID = nil }

    fileprivate func fail(_ message: String) { lastError = message }
    fileprivate func clearError() { if lastError != nil { lastError = nil } }

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
            Task { @MainActor in VideoModeState.shared.scheduleRefresh() }
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
        let result = videoMode.enter {
            if phase.isOn { playerMode ? stopPlayback() : stopStream() }
        }
        if let error = videoMode.lastError { dlog("video mode: \(error)") }
        return result
    }

    /// Exit never restarts AirPlay. Failed restoration keeps the saved route
    /// and active state intact so the user can retry.
    func exitVideoMode() {
        videoMode.exit()
        if let error = videoMode.lastError { dlog("video mode: \(error)") }
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
                .disabled(!store.videoMode.isAvailable && !store.videoMode.isActive)

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
