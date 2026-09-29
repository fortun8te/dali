// Watches the system output volume (what the hardware volume keys change)
// so DALI can mirror it onto the room master in room-only mode.
// Re-attaches when the default output device changes (headphones etc).

import Foundation
import CoreAudio
import AudioToolbox

final class SystemVolumeObserver: @unchecked Sendable {
    /// Called with (newVolume, previousVolume), both 0...1. Set once, before use;
    /// invoked on the observer's private queue.
    var onChange: ((Double, Double) -> Void)?

    // `deviceID` and `_lastVolume` are touched from the listener queue, the
    // main actor (setVolume/current) and init, so they live behind `state`.
    private let state = NSLock()
    private var _lastVolume: Double = 0.5
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
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
    private var volumeBlock: AudioObjectPropertyListenerBlock!
    private var defaultBlock: AudioObjectPropertyListenerBlock!

    init() {
        volumeBlock = { [weak self] _, _ in
            guard let self, let v = self.readEffectiveVolume() else { return }
            self.state.lock()
            let prev = self._lastVolume
            self._lastVolume = v
            self.state.unlock()
            self.onChange?(v, prev)
        }
        defaultBlock = { [weak self] _, _ in self?.attachToDefaultDevice() }
        var addr = Self.defaultAddr()
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, defaultBlock)
        // Serialised with any default-device event that fires during init.
        queue.sync { self.attachToDefaultDevice() }
    }

    deinit {
        var addr = Self.defaultAddr()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, defaultBlock)
        detach(from: currentDevice())
    }

    private func currentDevice() -> AudioObjectID {
        state.lock(); defer { state.unlock() }
        return deviceID
    }

    private func detach(from dev: AudioObjectID) {
        guard dev != kAudioObjectUnknown else { return }
        var v = Self.volumeAddr()
        AudioObjectRemovePropertyListenerBlock(dev, &v, queue, volumeBlock)
        var m = Self.muteAddr()
        AudioObjectRemovePropertyListenerBlock(dev, &m, queue, volumeBlock)
    }

    /// Runs on `queue`.
    private func attachToDefaultDevice() {
        detach(from: currentDevice())
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var d = Self.defaultAddr()
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &d, 0, nil, &size, &dev) == noErr
        state.lock()
        deviceID = ok ? dev : AudioObjectID(kAudioObjectUnknown)
        state.unlock()
        guard ok, dev != kAudioObjectUnknown else { return }
        if let v = readEffectiveVolume() {   // baseline, no event fired
            state.lock(); _lastVolume = v; state.unlock()
        }
        var v = Self.volumeAddr()
        AudioObjectAddPropertyListenerBlock(dev, &v, queue, volumeBlock)
        var m = Self.muteAddr()
        if AudioObjectHasProperty(dev, &m) {
            AudioObjectAddPropertyListenerBlock(dev, &m, queue, volumeBlock)
        }
    }

    /// Current system output volume 0...1, or nil if the device has none.
    func current() -> Double? { readEffectiveVolume() }

    /// Set the system output volume 0...1 (what the volume keys/menu control).
    func setVolume(_ v: Double) {
        let dev = currentDevice()
        guard dev != kAudioObjectUnknown, v.isFinite else { return }
        var vol = Float32(min(max(v, 0), 1))
        state.lock(); _lastVolume = Double(vol); state.unlock()   // pre-set so our own change isn't echoed back
        var addr = Self.volumeAddr()
        AudioObjectSetPropertyData(dev, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &vol)
    }

    private func readVolume() -> Double? {
        let dev = currentDevice()
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
    private func readEffectiveVolume() -> Double? {
        guard let volume = readVolume() else { return nil }
        return readMuted() ? 0 : volume
    }

    private func readMuted() -> Bool {
        let dev = currentDevice()
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
