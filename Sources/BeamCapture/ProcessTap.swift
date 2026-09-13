// BeamCapture — system audio capture via Core Audio process taps (macOS 14.4+).
// Taps ALL processes' audio as a stereo mixdown, delivers Float32 buffers.
// The Mac's own output keeps playing; the tap only observes.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

public final class ProcessTap {
    public struct TapError: Error, CustomStringConvertible {
        public let stage: String
        public let status: OSStatus
        public var description: String { "ProcessTap failed at \(stage): OSStatus \(status)" }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "beam.tap.io")

    /// Format the tap delivers (set after start()).
    public private(set) var tapFormat: AVAudioFormat?

    /// Whether the aggregate ended up anchored to a real output device's clock
    /// (true) or fell back to the legacy tap-only shape (false). Logged at
    /// stream start so a degraded session is visible in the flight log.
    public private(set) var clockAnchored = false

    /// Called on the IO queue with each captured buffer.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    public init() {}

    public enum Source: Equatable, Sendable {
        case system            // everything the Mac plays
        case process(pid_t)    // one app only (e.g. Spotify)
    }

    /// muteLocal: true silences the tapped audio on the Mac's own speakers
    /// (the stream still gets it). With .process, only that app goes quiet locally.
    public func start(muteLocal: Bool = false, source: Source = .system) throws {
        // Every throw below happens AFTER at least one HAL object exists, and
        // those objects are process-global: an abandoned aggregate device stays
        // registered with coreaudiod until the machine reboots. Relying on
        // deinit was not enough, because CaptureController.rebuild() assigns the
        // failed tap to `self.tap` (start is `try?` there) and then retries every
        // ~10s — so a persistently failing rebuild leaked a fresh aggregate on
        // every attempt. Unwind explicitly instead.
        var ok = false
        defer { if !ok { stop() } }

        let desc: CATapDescription
        switch source {
        case .system:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .process(let pid):
            let obj = try Self.processObject(for: pid)
            desc = CATapDescription(stereoMixdownOfProcesses: [obj])
        }
        desc.name = "Beam System Tap"
        desc.isPrivate = true
        desc.muteBehavior = muteLocal ? .mutedWhenTapped : .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard status == noErr else { throw TapError(stage: "create tap", status: status) }
        tapID = newTapID

        // 2. Read the tap's stream format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError(stage: "read tap format", status: status) }
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError(stage: "wrap tap format", status: -1)
        }
        tapFormat = format

        // 3. Aggregate device carrying the tap, ANCHORED TO A REAL CLOCK.
        //
        // This used to be a tap-ONLY aggregate (tap list, no sub-devices). That
        // is a broken shape. From AudioHardware.h, kAudioAggregateDeviceMainSub-
        // DeviceKey is "the UID for the sub-device that is the TIME SOURCE for
        // the AudioAggregateDevice" — so with no sub-device list there is no
        // time source at all, and the kAudioSubTapDriftCompensationKey we set
        // below has no reference clock to correct against (it is a no-op).
        // Worse, a tap configured as the main sub-device with an empty
        // sub-device list is documented to silently deliver ZERO SAMPLES.
        //
        // Anchoring to the current default output device gives the aggregate the
        // real audio hardware clock, which is also the clock the tapped audio is
        // actually produced against — so "the tap delivers real-time samples"
        // becomes a contract the HAL enforces rather than an assumption we make.
        // We never render to it; it is present purely as the time source.
        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Beam Tap Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,     // required by TapAutoStart
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var anchored = false
        if let clockUID = Self.defaultOutputDeviceUID() {
            aggDesc[kAudioAggregateDeviceMainSubDeviceKey] = clockUID
            aggDesc[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: clockUID]
            ]
            anchored = true
        }
        // If the UID lookup fails we fall through to the old tap-only shape
        // rather than refusing to capture: degraded, but still audible.
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        if status != noErr && anchored {
            // The clock anchor itself can be the reason creation fails — e.g.
            // the default output is currently an AirPlay/virtual route that
            // can't be a sub-device. The old tap-only shape always created
            // fine here, so retry without the anchor rather than turning a
            // sync improvement into a capture regression.
            aggDesc.removeValue(forKey: kAudioAggregateDeviceMainSubDeviceKey)
            aggDesc.removeValue(forKey: kAudioAggregateDeviceSubDeviceListKey)
            anchored = false
            status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        }
        guard status == noErr else { throw TapError(stage: "create aggregate", status: status) }
        clockAnchored = anchored
        aggregateID = newAggID

        // 4. IO proc: input buffers on the aggregate are the tapped audio.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let onBuffer = self.onBuffer, let fmt = self.tapFormat else { return }
            let ablPointer = UnsafeMutablePointer(mutating: inInputData)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: ablPointer, deallocator: nil),
                  pcm.frameLength > 0 else { return }
            onBuffer(pcm)
        }
        guard status == noErr, ioProcID != nil else { throw TapError(stage: "create ioproc", status: status) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError(stage: "start device", status: status) }
        ok = true
    }

    /// UID of the current default output device, used as the aggregate's time
    /// source (see the aggregate construction above). Returns nil if the device
    /// or its UID can't be read, in which case the caller degrades gracefully.
    private static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }

        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &uidSize, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    /// Translate a Unix pid to the Core Audio process object that taps want.
    private static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var inPID = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeBytes(of: &inPID) { raw in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(raw.count), raw.baseAddress, &size, &obj)
        }
        guard status == noErr, obj != kAudioObjectUnknown else {
            throw TapError(stage: "translate pid \(pid)", status: status)
        }
        return obj
    }

    public func stop() {
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
