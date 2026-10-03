// Watches the system output volume (what the hardware volume keys change)
// so DALI can mirror it onto the room master in room-only mode.
// Re-attaches when the default output device changes (headphones etc).

import Foundation
import CoreAudio
import AudioToolbox

final class SystemVolumeObserver: @unchecked Sendable {
    /// Installed by start; invoked only on the observer's private queue.
    private var onChange: (@Sendable (Double, Double) -> Void)?

    // Callers only touch cached state. All HAL work and device changes belong
    // to the serial queue, including setup and listener removal.
    private let state = NSLock()
    private var _lastVolume: Double = 0.5
    private var cachedVolume: Double?
    private var knownMuted = false
    private var pendingVolume: Double?
    private var intentRevision: UInt64 = 0
    private var writeScheduled = false
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var started = false
    private let queue = DispatchQueue(label: "dali.sysvol")

    // Fresh address per call: passing `&self.someVar` from several threads is an
    // overlapping inout access to the same stored property.
    private static func volumeAddr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }
    private static func muteAddr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }
    private static func defaultAddr() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    // Built in init (not `lazy`: lazy initialisation is not thread-safe and both
    // init and the listener queue reach for these).
    private typealias Listener = @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    private var volumeBlock: Listener!
    private var defaultBlock: Listener!

    init() {
        volumeBlock = { [weak self] _, _ in
            self?.refreshVolume()
        }
        defaultBlock = { [weak self] _, _ in self?.attachToDefaultDevice() }
    }

    /// Register after the callback is installed. A slow audio driver must not
    /// hold the main actor while the app opens or a slider moves.
    func start(onChange: @escaping @Sendable (Double, Double) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.onChange = onChange
            var addr = Self.defaultAddr()
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, self.queue, self.defaultBlock)
            self.attachToDefaultDevice()
        }
    }

    deinit {
        // Copy listener handles, so cleanup does not retain a dying observer or
        // wait on HAL from whichever thread released it.
        let queue = queue, dev = deviceID
        let defaultBlock = defaultBlock!, volumeBlock = volumeBlock!
        let started = started
        queue.async {
            guard started else { return }
            var addr = Self.defaultAddr()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, queue, defaultBlock)
            Self.detach(from: dev, queue: queue, block: volumeBlock)
        }
    }

    private static func detach(from dev: AudioObjectID, queue: DispatchQueue,
                               block: @escaping AudioObjectPropertyListenerBlock) {
        guard dev != kAudioObjectUnknown else { return }
        var v = Self.volumeAddr()
        AudioObjectRemovePropertyListenerBlock(dev, &v, queue, block)
        var m = Self.muteAddr()
        AudioObjectRemovePropertyListenerBlock(dev, &m, queue, block)
    }

    /// Runs on `queue`.
    private func attachToDefaultDevice() {
        Self.detach(from: deviceID, queue: queue, block: volumeBlock)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var d = Self.defaultAddr()
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &d, 0, nil, &size, &dev) == noErr
        deviceID = ok ? dev : AudioObjectID(kAudioObjectUnknown)
        guard ok, dev != kAudioObjectUnknown else {
            state.lock()
            let fallback = cachedVolume ?? 0.5, previous = _lastVolume
            cachedVolume = fallback
            _lastVolume = fallback
            knownMuted = false
            state.unlock()
            onChange?(fallback, previous)
            return
        }
        var v = Self.volumeAddr()
        AudioObjectAddPropertyListenerBlock(dev, &v, queue, volumeBlock)
        var m = Self.muteAddr()
        if AudioObjectHasProperty(dev, &m) {
            AudioObjectAddPropertyListenerBlock(dev, &m, queue, volumeBlock)
        }
        // Register before reading, so a change during the initial read also
        // gets a queued refresh. A new route needs a publication of its own.
        refreshVolume()
        // Preserve intent queued before startup or while the route was read.
        writePendingVolume()
    }

    /// Last known effective volume, or nil while the first read is pending.
    /// Never waits on the driver. Route/property events keep the cache current.
    func current() -> Double? {
        state.lock(); defer { state.unlock() }
        return cachedVolume
    }

    /// Set the system output volume 0...1 (what the volume keys/menu control).
    func setVolume(_ v: Double) {
        guard v.isFinite else { return }
        let vol = Double(Float32(min(max(v, 0), 1)))
        state.lock()
        pendingVolume = vol
        intentRevision &+= 1
        cachedVolume = knownMuted ? 0 : vol
        _lastVolume = cachedVolume!
        let schedule = !writeScheduled
        writeScheduled = true
        state.unlock()
        if schedule { queue.async { [weak self] in self?.writePendingVolume() } }
    }

    /// One write per queue turn lets route events run between slider writes.
    /// New slider intent replaces queued values while a driver call is blocked.
    private func writePendingVolume() {
        state.lock()
        guard deviceID != kAudioObjectUnknown, let pending = pendingVolume else {
            writeScheduled = false
            state.unlock()
            return
        }
        pendingVolume = nil
        let revision = intentRevision
        state.unlock()
        var vol = Float32(pending)
        var addr = Self.volumeAddr()
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &vol)
        refreshVolume(expectedRevision: revision)
        state.lock()
        let again = pendingVolume != nil
        writeScheduled = again
        state.unlock()
        if again { queue.async { [weak self] in self?.writePendingVolume() } }
    }

    private func readVolume() -> Double? {
        let dev = deviceID
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = Self.volumeAddr()
        guard dev != kAudioObjectUnknown,
              AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr,
              vol.isFinite
        else { return nil }
        return Double(vol)
    }

    /// Muting does not change the Mac volume scalar, so it needs its own Core
    /// Audio property. Expose mute as an effective volume of zero; unmuting then
    /// reports the still-current scalar and restores the room master.
    private func refreshVolume(expectedRevision: UInt64? = nil) {
        state.lock()
        let revision = expectedRevision ?? intentRevision
        state.unlock()
        // Fixed-volume devices can omit the scalar property. Preserve the
        // existing 0.5 fallback, but still honor any mute property they expose.
        let volume = readVolume() ?? 0.5
        let muted = readMuted()
        state.lock()
        knownMuted = muted
        // A slow initial/property read must not overwrite newer slider intent.
        guard revision == intentRevision, pendingVolume == nil else {
            cachedVolume = muted ? 0 : pendingVolume ?? cachedVolume
            state.unlock()
            return
        }
        let effective = muted ? 0 : volume
        let previous = _lastVolume
        cachedVolume = effective
        _lastVolume = effective
        state.unlock()
        onChange?(effective, previous)
    }

    private func readMuted() -> Bool {
        let dev = deviceID
        var addr = Self.muteAddr()
        guard dev != kAudioObjectUnknown,
              AudioObjectHasProperty(dev, &addr) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &muted) == noErr
        else { return false }
        return muted != 0
    }
}
