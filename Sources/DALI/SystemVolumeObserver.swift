// Watches the system output volume (what the hardware volume keys change)
// so DALI can mirror it onto the room master in room-only mode.
// Re-attaches when the default output device changes (headphones etc).

import Foundation
import CoreAudio
import AudioToolbox

final class SystemVolumeObserver: @unchecked Sendable {
    /// Called with (newVolume, previousVolume), both 0...1.
    var onChange: ((Double, Double) -> Void)?
    private var lastVolume: Double = 0.5

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private let queue = DispatchQueue(label: "dali.sysvol")

    private var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private lazy var volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        if let v = self.readEffectiveVolume() {
            let prev = self.lastVolume
            self.lastVolume = v
            self.onChange?(v, prev)
        }
    }
    private lazy var defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.attachToDefaultDevice()
    }

    init() {
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, queue, defaultBlock)
        attachToDefaultDevice()
    }

    private func attachToDefaultDevice() {
        if deviceID != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddr, queue, volumeBlock)
            if AudioObjectHasProperty(deviceID, &muteAddr) {
                AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddr, queue, volumeBlock)
            }
        }
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &defaultAddr, 0, nil, &size, &dev) == noErr else { return }
        deviceID = dev
        if let v = readEffectiveVolume() { lastVolume = v }   // baseline, no event fired
        AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddr, queue, volumeBlock)
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, queue, volumeBlock)
        }
    }

    /// Current system output volume 0...1, or nil if the device has none.
    func current() -> Double? { readEffectiveVolume() }

    /// Set the system output volume 0...1 (what the volume keys/menu control).
    func setVolume(_ v: Double) {
        guard deviceID != kAudioObjectUnknown else { return }
        var vol = Float32(min(max(v, 0), 1))
        lastVolume = Double(vol)   // pre-set so our own change isn't echoed back
        AudioObjectSetPropertyData(deviceID, &volumeAddr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &vol)
    }

    private func readVolume() -> Double? {
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard deviceID != kAudioObjectUnknown,
              AudioObjectGetPropertyData(deviceID, &volumeAddr, 0, nil, &size, &vol) == noErr
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
        guard deviceID != kAudioObjectUnknown,
              AudioObjectHasProperty(deviceID, &muteAddr) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &size, &muted) == noErr
        else { return false }
        return muted != 0
    }
}
