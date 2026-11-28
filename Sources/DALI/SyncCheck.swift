import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Hardware latency of the Mac's default audio devices, from Core Audio.
enum DeviceLatency {
    static func defaultDevice(input: Bool) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func nominalRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr,
              rate.isFinite, rate >= 8_000 else { return nil }
        return rate
    }

    private static func frames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func firstStream(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    /// Seconds between the sound and its time stamp on the microphone: device plus
    /// stream latency.
    static func inputSeconds(_ device: AudioObjectID) -> Double {
        guard let rate = nominalRate(device) else { return 0 }
        let scope = kAudioObjectPropertyScopeInput
        var total = frames(device, kAudioDevicePropertyLatency, scope)
        if let stream = firstStream(device, scope) {
            total += frames(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
        }
        return Double(total) / rate
    }

    /// Seconds from the Mac mixing a buffer to the Mac's own output playing it:
    /// the IO buffer, safety offset and device plus stream latency. Chrome shows a
    /// frame when its sound would come out here, so this is how much later than
    /// the capture an undelayed picture appears.
    static func outputSeconds(_ device: AudioObjectID) -> Double {
        guard let rate = nominalRate(device) else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        var total = frames(device, kAudioDevicePropertyLatency, scope)
            + frames(device, kAudioDevicePropertySafetyOffset, scope)
            + frames(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        if let stream = firstStream(device, scope) {
            total += frames(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
        }
        let seconds = Double(total) / rate
        return seconds.isFinite ? min(max(seconds, 0), 0.1) : 0
    }
}

/// A few seconds of the default microphone, stamped on the host clock.
final class MicRecorder: @unchecked Sendable {
    struct Recording {
        var samples: [Float]
        let sampleRate: Double
        /// Host-clock seconds at which the first sample was heard (input latency removed).
        let startSec: Double
    }

    enum Failure: Error { case noMicrophone, start(OSStatus), noTimestamps, noAudio }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstSampleTime: Double?
    private var firstHostSec: Double?
    private var wanted = 0
    private var done = false
    private var continuation: CheckedContinuation<Recording, Error>?
    private var started: (@Sendable () -> Void)?
    private var queue: AudioQueueRef?
    private var rate = 48_000.0
    private var inputLatency = 0.0

    static func hostSeconds(_ host: UInt64) -> Double { Double(AudioConvertHostTimeToNanos(host)) / 1_000_000_000 }

    /// Records `seconds` of audio. `started` runs once the microphone is delivering.
    func record(seconds: Double, started: @escaping @Sendable () -> Void) async throws -> Recording {
        guard let device = DeviceLatency.defaultDevice(input: true) else { throw Failure.noMicrophone }
        rate = DeviceLatency.nominalRate(device) ?? 48_000
        inputLatency = DeviceLatency.inputSeconds(device)
        wanted = Int(seconds * rate)
        self.started = started
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            var format = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            var ref: AudioQueueRef?
            let status = AudioQueueNewInputWithDispatchQueue(&ref, &format, 0,
                                                             DispatchQueue(label: "dali.sync.mic", qos: .userInitiated)) {
                [weak self] aq, buffer, start, _, _ in
                self?.receive(aq, buffer, start)
            }
            guard status == noErr, let ref else { finish(.failure(Failure.start(status))); return }
            queue = ref
            for _ in 0..<4 {
                var buffer: AudioQueueBufferRef?
                if AudioQueueAllocateBuffer(ref, 4096 * 4, &buffer) == noErr, let buffer {
                    AudioQueueEnqueueBuffer(ref, buffer, 0, nil)
                }
            }
            let startStatus = AudioQueueStart(ref, nil)
            if startStatus != noErr { finish(.failure(Failure.start(startStatus))) }
            // Never hang: a microphone that stops delivering ends the recording.
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 3) { [weak self] in
                self?.finish(.failure(Failure.noAudio))
            }
        }
    }

    private func receive(_ aq: AudioQueueRef, _ buffer: AudioQueueBufferRef,
                         _ start: UnsafePointer<AudioTimeStamp>) {
        let count = Int(buffer.pointee.mAudioDataByteSize) / 4
        let stamp = start.pointee
        var notifyStarted: (@Sendable () -> Void)?
        lock.lock()
        if done { lock.unlock(); return }
        if count > 0 {
            if firstSampleTime == nil {
                guard stamp.mFlags.contains(.hostTimeValid), stamp.mFlags.contains(.sampleTimeValid) else {
                    lock.unlock(); finish(.failure(Failure.noTimestamps)); return
                }
                firstSampleTime = stamp.mSampleTime
                firstHostSec = Self.hostSeconds(stamp.mHostTime)
                notifyStarted = started
                started = nil
            }
            // Place each buffer by its own sample time, so a dropped buffer leaves a
            // gap instead of sliding everything after it earlier.
            if let first = firstSampleTime, stamp.mFlags.contains(.sampleTimeValid) {
                let at = Int((stamp.mSampleTime - first).rounded())
                if at > samples.count, at - samples.count < Int(rate) {
                    samples.append(contentsOf: repeatElement(0, count: at - samples.count))
                }
            }
            let pointer = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
        }
        let complete = samples.count >= wanted
        lock.unlock()
        notifyStarted?()
        if complete {
            lock.lock()
            let recording = Recording(samples: samples, sampleRate: rate,
                                      startSec: (firstHostSec ?? 0) - inputLatency)
            lock.unlock()
            finish(.success(recording))
        } else {
            AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
        }
    }

    private func finish(_ result: Result<Recording, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let continuation = self.continuation
        self.continuation = nil
        let queue = self.queue
        self.queue = nil
        lock.unlock()
        if let queue {
            // Off the queue's own callback thread: disposing synchronously there deadlocks.
            DispatchQueue.global().async {
                AudioQueueStop(queue, true)
                AudioQueueDispose(queue, true)
            }
        }
        continuation?.resume(with: result)
    }
}
