// BeamCapture — system audio capture via Core Audio process taps (macOS 14.4+).
// Taps ALL processes' audio as a stereo mixdown, delivers Float32 buffers.
// The Mac's own output keeps playing; the tap only observes.
//
// THREADING. The HAL calls our IOProc on its realtime IO thread, so the IOProc
// (a plain C function, no block, no dispatch queue, no ARC) does nothing but
// memcpy the tap's samples into a lock-free ring and return. A separate
// non-realtime thread drains the ring and calls `onBuffer`. Everything that can
// block, allocate or take a lock (conversion, resampling, FIFO, metering) lives
// behind that hand-off, so no downstream stall can ever reach the audio callback.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Synchronization

// MARK: - realtime side

/// State shared between the IOProc (producer) and the consumer thread. The IOProc
/// reaches it through an unretained pointer, so it takes no retain/release traffic.
final class TapContext: @unchecked Sendable {
    let ring: AudioRing
    /// AudioBuffers the tap contributes to the aggregate's input list. When the
    /// aggregate is anchored to a device that ALSO has input streams (headset,
    /// USB DAC with a mic, Studio Display) those come FIRST in the list and the
    /// tap's streams come last — so we take the LAST `bufferCount` buffers.
    let bufferCount: Int
    let channelsPerBuffer: Int
    let bytesPerFrame: Int
    static let maxFrames = 1 << 16

    let callbacks = Atomic<Int>(0)
    let overruns = Atomic<Int>(0)
    let layoutErrors = Atomic<Int>(0)
    let staleRecords = Atomic<Int>(0)
    static let recordHeaderBytes = 12
    static let maximumRecordAgeNs: UInt64 = 250_000_000

    init(ring: AudioRing, bufferCount: Int, channelsPerBuffer: Int) {
        self.ring = ring
        self.bufferCount = bufferCount
        self.channelsPerBuffer = channelsPerBuffer
        self.bytesPerFrame = channelsPerBuffer * MemoryLayout<Float>.size
    }

    /// Record layout: [UInt32 frames][UInt64 host time][bufferCount x payload].
    /// REALTIME: no locks, no allocation, no syscalls, bounded work.
    @inline(__always)
    func deliver(_ list: UnsafePointer<AudioBufferList>) {
        _ = callbacks.wrappingAdd(1, ordering: .relaxed)
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let n = abl.count
        guard n >= bufferCount else { _ = layoutErrors.wrappingAdd(1, ordering: .relaxed); return }
        let first = n - bufferCount
        var frames = Int.max
        for i in 0..<bufferCount {
            let b = abl[first + i]
            guard b.mData != nil, Int(b.mNumberChannels) == channelsPerBuffer else {
                _ = layoutErrors.wrappingAdd(1, ordering: .relaxed); return
            }
            frames = min(frames, Int(b.mDataByteSize) / bytesPerFrame)
        }
        guard frames > 0, frames <= Self.maxFrames else { return }
        let payload = frames * bytesPerFrame
        let need = Self.recordHeaderBytes + bufferCount * payload
        guard ring.freeBytes() >= need else {
            // Consumer is behind by seconds. Dropping the NEW record is the only
            // legal move (only the consumer may advance tail); it is counted.
            _ = overruns.wrappingAdd(1, ordering: .relaxed)
            return
        }
        var f32 = UInt32(truncatingIfNeeded: frames)
        withUnsafeBytes(of: &f32) { ring.copyIn($0.baseAddress!, count: 4, at: 0) }
        var hostTime = AudioGetCurrentHostTime()
        withUnsafeBytes(of: &hostTime) { ring.copyIn($0.baseAddress!, count: 8, at: 4) }
        var off = Self.recordHeaderBytes
        for i in 0..<bufferCount {
            ring.copyIn(UnsafeRawPointer(abl[first + i].mData!), count: payload, at: off)
            off += payload
        }
        ring.commit(need)
    }
}

/// The HAL's IO callback. Plain C function: no captures, no ARC, no locks.
private func tapIOProc(_ device: AudioObjectID,
                       _ now: UnsafePointer<AudioTimeStamp>,
                       _ input: UnsafePointer<AudioBufferList>,
                       _ inputTime: UnsafePointer<AudioTimeStamp>,
                       _ output: UnsafeMutablePointer<AudioBufferList>,
                       _ outputTime: UnsafePointer<AudioTimeStamp>,
                       _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<TapContext>.fromOpaque(clientData)._withUnsafeGuaranteedRef { $0.deliver(input) }
    return noErr
}

/// Non-realtime drain thread: ring -> AVAudioPCMBuffer -> onBuffer.
final class TapConsumer: @unchecked Sendable {
    private let ctx: TapContext
    private let format: AVAudioFormat
    private let handler: ((AVAudioPCMBuffer) -> Void)?
    private let stopFlag = Atomic<Bool>(false)
    private let finished = DispatchSemaphore(value: 0)

    init(context: TapContext, format: AVAudioFormat, handler: ((AVAudioPCMBuffer) -> Void)?) {
        ctx = context
        self.format = format
        self.handler = handler
    }

    func start() {
        let t = Thread { [self] in
            run()
            finished.signal()
        }
        t.name = "beam.tap.consumer"
        t.qualityOfService = .userInteractive
        t.start()
    }

    // The thread owns itself and its context until run returns. Cancellation
    // does not pretend that a timed-out join terminated an in-flight handler.
    func requestStop() { stopFlag.store(true, ordering: .releasing) }
    func waitForCompletion(timeout: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    private func run() {
        var capacity: AVAudioFrameCount = 4096
        guard var pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        let ring = ctx.ring
        let bytesPerFrame = ctx.bytesPerFrame
        let perBuffer = ctx.channelsPerBuffer
        while !stopFlag.load(ordering: .acquiring) {
            while !stopFlag.load(ordering: .acquiring), ring.readableBytes() >= TapContext.recordHeaderBytes {
                var f32: UInt32 = 0
                ring.copyOut(&f32, count: 4, at: 0)
                let frames = Int(f32)
                let payload = frames * bytesPerFrame
                guard frames > 0, frames <= TapContext.maxFrames,
                      ring.readableBytes() >= TapContext.recordHeaderBytes + ctx.bufferCount * payload else {
                    // Impossible unless memory was corrupted: resync by discarding.
                    ring.release(ring.readableBytes())
                    break
                }
                let recordBytes = TapContext.recordHeaderBytes + ctx.bufferCount * payload
                var capturedHost: UInt64 = 0
                ring.copyOut(&capturedHost, count: 8, at: 4)
                let hostNow = AudioGetCurrentHostTime()
                if hostNow >= capturedHost,
                   AudioConvertHostTimeToNanos(hostNow - capturedHost) > TapContext.maximumRecordAgeNs {
                    ring.release(recordBytes)
                    _ = ctx.staleRecords.wrappingAdd(1, ordering: .relaxed)
                    continue
                }
                if capacity < AVAudioFrameCount(frames) {
                    capacity = AVAudioFrameCount(frames)
                    guard let bigger = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                        ring.release(recordBytes)
                        continue
                    }
                    pcm = bigger
                }
                pcm.frameLength = AVAudioFrameCount(frames)
                let dst = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                var off = TapContext.recordHeaderBytes
                var ok = dst.count >= ctx.bufferCount
                if ok {
                    for i in 0..<ctx.bufferCount {
                        guard let m = dst[i].mData else { ok = false; break }
                        ring.copyOut(m, count: payload, at: off)
                        Self.sanitize(m.assumingMemoryBound(to: Float.self), frames * perBuffer)
                        off += payload
                    }
                }
                ring.release(recordBytes)
                if ok, !stopFlag.load(ordering: .acquiring) { handler?(pcm) }
            }
            usleep(1500)
        }
    }

    /// Clamp to [-1, 1], zero NaN and flush denormals/near-zero. Anything else
    /// would reach the sample-rate converter (denormal arithmetic is slow) or
    /// wrap/clip unpredictably in the s16 conversion (NaN -> arbitrary int).
    @inline(__always)
    private static func sanitize(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let v = p[i]
            let a = abs(v)
            if a >= 1e-20 && a <= 1.0 { continue }
            if a < 1e-20 { p[i] = 0 }
            else if a > 1.0 { p[i] = v > 0 ? 1.0 : -1.0 }   // +-inf lands here too
            else { p[i] = 0 }                               // NaN: every comparison false
        }
    }
}

// MARK: - tap

public final class ProcessTap: @unchecked Sendable {
    public struct TapError: Error, CustomStringConvertible {
        public let stage: String
        public let status: OSStatus
        public var description: String { "ProcessTap failed at \(stage): OSStatus \(status)" }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var context: TapContext?
    private var consumer: TapConsumer?
    private let eventQueue = DispatchQueue(label: "beam.tap.events")

    /// Format the tap delivers (set after start()).
    public private(set) var tapFormat: AVAudioFormat?

    /// Whether the aggregate ended up anchored to a real output device's clock
    /// (true) or fell back to the legacy tap-only shape (false). Logged at
    /// stream start so a degraded session is visible in the flight log.
    public private(set) var clockAnchored = false

    /// Called on the consumer thread (NOT the realtime thread) with each captured
    /// buffer. The buffer is reused: copy out, do not retain. Set before start().
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// Fired once per start() on a private queue when the HAL reconfigured
    /// underneath the tap in a way that makes it stale: default output device
    /// changed (the aggregate's clock anchor), rate/format changed, the aggregate
    /// died, or coreaudiod restarted. The owner should rebuild the tap.
    public var onInvalidated: ((String) -> Void)?

    /// IOProc invocations since start (proves the HAL is calling us).
    public var callbackCount: Int { context?.callbacks.load(ordering: .relaxed) ?? 0 }
    /// Records dropped because the consumer thread fell seconds behind.
    public var overrunCount: Int {
        (context?.overruns.load(ordering: .relaxed) ?? 0) + (context?.staleRecords.load(ordering: .relaxed) ?? 0)
    }
    /// Callbacks whose buffer layout did not match the tap's format.
    public var layoutErrorCount: Int { context?.layoutErrors.load(ordering: .relaxed) ?? 0 }

    private let stopping = Atomic<Bool>(false)
    private let invalidated = Atomic<Bool>(false)
    private let eventGeneration = Atomic<Int>(0)
    private var anchorUID: String?
    private var startRate = 0.0
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private static let aggregateUIDPrefix = "com.dali.beam.tap."
    private static let aggregateName = "Beam Tap Aggregate"
    private static let liveAggregates = Mutex<Set<AudioObjectID>>([])
    // Exceptional HAL failure quarantine is identity-keyed, so repeated
    // teardown attempts never retain duplicate contexts. It may grow if the HAL
    // fails to destroy distinct IOProcs; those live pointers cannot be freed.
    private static let quarantinedContexts = Mutex<[ObjectIdentifier: TapContext]>([:])
    private static let teardownFailures = Atomic<Int>(0)
    public static var teardownFailureCount: Int { teardownFailures.load(ordering: .relaxed) }

    public init() {}

    public enum Source: Equatable, Sendable {
        case system            // everything the Mac plays
        case process(pid_t)    // one app only (e.g. Spotify)
    }

    /// muteLocal: true silences the tapped audio on the Mac's own speakers
    /// (the stream still gets it). With .process, only that app goes quiet locally.
    public func start(muteLocal: Bool = false, source: Source = .system) throws {
        // A second start() on a live instance would orphan the first tap.
        if tapID != kAudioObjectUnknown || aggregateID != kAudioObjectUnknown || ioProcID != nil {
            stop()
            guard ioProcID == nil else { throw TapError(stage: "previous tap teardown", status: -3) }
        }
        _ = eventGeneration.wrappingAdd(1, ordering: .relaxed)
        stopping.store(false, ordering: .releasing)
        invalidated.store(false, ordering: .relaxed)
        // Every throw below happens AFTER at least one HAL object exists, and
        // those objects are process-global: an abandoned aggregate device stays
        // registered with coreaudiod until the machine reboots. Relying on
        // deinit was not enough, because CaptureController.rebuild() assigns the
        // failed tap to `self.tap` (start is `try?` there) and then retries every
        // ~10s — so a persistently failing rebuild leaked a fresh aggregate on
        // every attempt. Unwind explicitly instead.
        var ok = false
        defer { if !ok { stop() } }

        // Anything a previous run/crash left registered under our name.
        Self.sweepStaleAggregates()

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
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            // Our prefix lets sweepStaleAggregates() recognise (and remove) an
            // aggregate a previous run left behind.
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,     // required by TapAutoStart
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var anchored = false
        let clockUID = Self.defaultOutputDeviceUID()
        if let clockUID {
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
        // The default output AT START, anchored or not: invalidation means "the
        // default moved since we looked", so a session that could not anchor
        // (e.g. default is an AirPlay route) does not re-fire on every event.
        anchorUID = clockUID
        aggregateID = newAggID
        Self.liveAggregates.withLock { _ = $0.insert(newAggID) }

        // 2. Read the tap's stream format — AFTER the aggregate exists, so we see
        // what the HAL settled on once the tap joined the aggregate's clock.
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
        // The ring/consumer copy raw Float32; refuse anything else loudly rather
        // than reinterpreting bytes.
        guard format.commonFormat == .pcmFormatFloat32,
              format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 768_000,
              (1...8).contains(Int(format.channelCount)) else {
            throw TapError(stage: "unsupported tap format", status: -2)
        }
        tapFormat = format
        startRate = Self.nominalRate(aggregateID)

        // 4. IO proc: input buffers on the aggregate are the tapped audio.
        let interleaved = format.isInterleaved
        let ctx = TapContext(
            // Half a second of input storage; age-based discard below limits
            // delivery to the freshest 250ms even when the source pauses.
            ring: AudioRing(capacity: min(1 << 22, Int(format.sampleRate * Double(format.channelCount) * 4 * 0.5))),
            bufferCount: interleaved ? 1 : Int(format.channelCount),
            channelsPerBuffer: interleaved ? Int(format.channelCount) : 1)
        context = ctx
        let cons = TapConsumer(context: ctx, format: format, handler: onBuffer)
        consumer = cons

        status = AudioDeviceCreateIOProcID(aggregateID, tapIOProc,
                                           Unmanaged.passUnretained(ctx).toOpaque(), &ioProcID)
        guard status == noErr, ioProcID != nil else { throw TapError(stage: "create ioproc", status: status) }

        cons.start()
        eventQueue.sync { installListeners() }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw TapError(stage: "start device", status: status) }
        ok = true
    }

    // MARK: HAL change listeners

    private func installListeners() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let generation = eventGeneration.load(ordering: .relaxed)
        func add(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ why: String) {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.eventGeneration.load(ordering: .acquiring) == generation else { return }
                self.evaluate(trigger: why)
            }
            if AudioObjectAddPropertyListenerBlock(obj, &addr, eventQueue, block) == noErr {
                listeners.append((obj, addr, block))
            }
        }
        add(sys, kAudioHardwarePropertyDefaultOutputDevice, "default_output_changed")
        add(sys, kAudioHardwarePropertyServiceRestarted, "hal_restarted")
        add(aggregateID, kAudioDevicePropertyNominalSampleRate, "rate_changed")
        add(aggregateID, kAudioDevicePropertyDeviceIsAlive, "aggregate_dead")
        add(tapID, kAudioTapPropertyFormat, "tap_format_changed")
    }

    private func removeListeners() {
        for (obj, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, eventQueue, block)
        }
        listeners.removeAll()
    }

    /// Runs on eventQueue. Re-checks ALL invalidation conditions (cheap) and
    /// fires `onInvalidated` at most once per start().
    private func evaluate(trigger: String) {
        guard !stopping.load(ordering: .relaxed) else { return }
        var reason: String?
        if trigger == "hal_restarted" {
            reason = trigger
        } else if Self.deviceIsAlive(aggregateID) == false {
            reason = "aggregate_dead"
        } else if Self.defaultOutputDeviceUID() != anchorUID {
            reason = "default_output_changed"
        } else if startRate > 0, abs(Self.nominalRate(aggregateID) - startRate) > 0.5 {
            reason = "rate_changed"
        } else if let f = tapFormat, let now = Self.currentTapFormat(tapID),
                  now.sampleRate != f.sampleRate || now.channelCount != f.channelCount {
            reason = "tap_format_changed"
        }
        guard let reason else { return }
        guard !invalidated.exchange(true, ordering: .relaxed) else { return }
        onInvalidated?(reason)
    }

    // MARK: HAL helpers

    private static func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func nominalRate(_ dev: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate) == noErr,
              rate.isFinite else { return 0 }
        return rate
    }

    /// nil when the property can't be read (treated as "unknown", not "dead").
    private static func deviceIsAlive(_ dev: AudioObjectID) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &alive) == noErr else { return nil }
        return alive != 0
    }

    private static func currentTapFormat(_ tap: AudioObjectID) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Destroy aggregate devices carrying our name/UID prefix that no live
    /// ProcessTap in this process owns (left by a crashed/aborted earlier run).
    private static func sweepStaleAggregates() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return }
        ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        let live = liveAggregates.withLock { $0 }
        for id in ids where id != kAudioObjectUnknown && !live.contains(id) {
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            let name = stringProperty(id, kAudioObjectPropertyName) ?? ""
            guard uid.hasPrefix(aggregateUIDPrefix) || name == aggregateName else { continue }
            let st = AudioHardwareDestroyAggregateDevice(id)
            FileHandle.standardError.write(Data(
                "ProcessTap: removed stale aggregate device \(id) (status \(st))\n".utf8))
        }
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
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
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

    /// Teardown order matters: listeners -> stop IOProc -> destroy IOProc (after
    /// which the HAL can no longer touch `context`) -> retire consumer -> destroy
    /// aggregate -> destroy tap. Idempotent.
    public func stop() {
        stopping.store(true, ordering: .releasing)
        _ = eventGeneration.wrappingAdd(1, ordering: .releasing)
        consumer?.requestStop()
        eventQueue.sync { removeListeners() }
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            let status = AudioDeviceDestroyIOProcID(aggregateID, proc)
            guard status == noErr else {
                // The HAL may still hold the unretained context. Preserve all
                // resources rather than manufacture a use-after-free. The
                // consumer cancels independently and its old generation cannot
                // publish into CaptureController. A later stop may retry.
                FileHandle.standardError.write(Data("ProcessTap: IOProc teardown failed: \(status)\n".utf8))
                _ = Self.teardownFailures.wrappingAdd(1, ordering: .relaxed)
                if let context { Self.quarantinedContexts.withLock { $0[ObjectIdentifier(context)] = context } }
                return
            }
        }
        ioProcID = nil
        if let context { Self.quarantinedContexts.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(context)) } }
        consumer = nil
        context = nil
        if aggregateID != kAudioObjectUnknown {
            let id = aggregateID
            AudioHardwareDestroyAggregateDevice(id)
            Self.liveAggregates.withLock { _ = $0.remove(id) }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}
