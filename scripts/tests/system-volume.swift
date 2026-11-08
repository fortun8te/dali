import Foundation
import CoreAudio
import AudioToolbox

// These module-local functions shadow CoreAudio's imported calls. The test
// compiles the unmodified production observer against a slow, isolated HAL.
private final class FakeHAL: @unchecked Sendable {
    struct Write: Equatable { let device: AudioObjectID; let volume: Float32 }
    private struct Listener: @unchecked Sendable {
        let queue: DispatchQueue?
        let block: AudioObjectPropertyListenerBlock
    }
    static let shared = FakeHAL()
    private let lock = NSLock()
    private var mainCalls = 0
    private var values: [AudioObjectID: (Float32, UInt32)] = [42: (0.65, 1), 43: (0.3, 0), 44: (0.2, 0)]
    private var defaultID: AudioObjectID = 42
    private var listeners: [String: Listener] = [:]
    private var written: [Write] = []
    private var volumeReads = 0
    private var noVolume = false
    let delay: TimeInterval = 0.06

    func pause() {
        lock.lock()
        if Thread.isMainThread { mainCalls += 1 }
        lock.unlock()
        Thread.sleep(forTimeInterval: delay)
    }
    func read(_ device: AudioObjectID, selector: AudioObjectPropertySelector,
              into data: UnsafeMutableRawPointer) -> OSStatus {
        lock.lock()
        if selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume { volumeReads += 1 }
        lock.unlock()
        pause()
        lock.lock(); defer { lock.unlock() }
        if selector == kAudioHardwarePropertyDefaultOutputDevice {
            data.assumingMemoryBound(to: AudioObjectID.self).pointee = defaultID
        } else if selector == kAudioDevicePropertyMute {
            data.assumingMemoryBound(to: UInt32.self).pointee = values[device]?.1 ?? 0
        } else {
            if noVolume { return kAudioHardwareUnknownPropertyError }
            guard let value = values[device]?.0 else { return kAudioHardwareUnknownPropertyError }
            data.assumingMemoryBound(to: Float32.self).pointee = value
        }
        return noErr
    }
    func write(_ device: AudioObjectID, data: UnsafeRawPointer) -> OSStatus {
        pause()
        let value = data.assumingMemoryBound(to: Float32.self).pointee
        lock.lock()
        values[device]?.0 = value
        written.append(Write(device: device, volume: value))
        lock.unlock()
        return noErr
    }
    func listen(_ device: AudioObjectID, selector: AudioObjectPropertySelector,
                queue: DispatchQueue?, block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        pause()
        lock.lock(); listeners["\(device):\(selector)"] = Listener(queue: queue, block: block); lock.unlock()
        return noErr
    }
    func remove(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> OSStatus {
        pause()
        lock.lock(); listeners["\(device):\(selector)"] = nil; lock.unlock()
        return noErr
    }
    func mainCallCount() -> Int { lock.lock(); defer { lock.unlock() }; return mainCalls }
    func writes() -> [Write] { lock.lock(); defer { lock.unlock() }; return written }
    func volumeReadCount() -> Int { lock.lock(); defer { lock.unlock() }; return volumeReads }
    func omitVolume(_ omit: Bool) { lock.lock(); noVolume = omit; lock.unlock() }
    func listenerCount() -> Int { lock.lock(); defer { lock.unlock() }; return listeners.count }
    func hasListeners(_ device: AudioObjectID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listeners["\(device):\(kAudioDevicePropertyMute)"] != nil
    }
    func mute(_ device: AudioObjectID, _ value: Bool) {
        lock.lock(); values[device]?.1 = value ? 1 : 0; lock.unlock()
        fire(device, selector: kAudioDevicePropertyMute)
    }
    func route(_ device: AudioObjectID) {
        lock.lock(); defaultID = device; lock.unlock()
        fire(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
    }
    func fire(_ device: AudioObjectID, selector: AudioObjectPropertySelector) {
        lock.lock(); let listener = listeners["\(device):\(selector)"]; lock.unlock()
        guard let listener else { return }
        let invoke: @Sendable () -> Void = {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            listener.block(1, &address)
        }
        if let queue = listener.queue { queue.async(execute: invoke) } else { invoke() }
    }
}

@discardableResult
func AudioObjectGetPropertyData(_ device: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutableRawPointer) -> OSStatus {
    FakeHAL.shared.read(device, selector: address.pointee.mSelector, into: data)
}
@discardableResult
func AudioObjectSetPropertyData(_ device: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UInt32,
    _ data: UnsafeRawPointer) -> OSStatus { FakeHAL.shared.write(device, data: data) }
func AudioObjectHasProperty(_ device: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>) -> Bool { true }
@discardableResult
func AudioObjectAddPropertyListenerBlock(_ device: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ queue: DispatchQueue?,
    _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    FakeHAL.shared.listen(device, selector: address.pointee.mSelector, queue: queue, block: block)
}
@discardableResult
func AudioObjectRemovePropertyListenerBlock(_ device: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ queue: DispatchQueue?,
    _ block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
    FakeHAL.shared.remove(device, selector: address.pointee.mSelector)
}

private enum Failure: Error { case assertion(String) }
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.assertion(message) }
}
private func measure(_ action: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    action()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Double] = []
    func append(_ value: Double) { lock.lock(); events.append(value); lock.unlock() }
    func values() -> [Double] { lock.lock(); defer { lock.unlock() }; return events }
}
@MainActor private func waitUntil(_ message: String, _ test: () -> Bool) async throws {
    let until = ContinuousClock.now.advanced(by: .seconds(4))
    while !test() {
        try expect(ContinuousClock.now < until, "timeout: \(message)")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@main struct VolumeRegression {
    @MainActor static func main() async throws {
        var observer: SystemVolumeObserver?
        let creation = measure { observer = SystemVolumeObserver() }
        let read = measure { _ = observer?.current() }
        let write = measure { observer?.setVolume(.nan) }
        FileHandle.standardOutput.write(Data((String(format: "Observer init %.1f ms, current %.1f ms, setVolume %.1f ms", creation, read, write) + "\n").utf8))
        let events = Changes()
        let start = measure { observer?.start(onChange: { value, _ in events.append(value) }) }
        try expect(max(creation, read, write, start) < 30, "observer must not wait on HAL in its caller")
        try expect(observer?.current() == nil, "initial cache stays unknown until actual read")
        try await waitUntil("muted initial snapshot") { events.values().last == 0 }
        try expect(observer?.current() == 0, "initial mute uses effective zero")
        FakeHAL.shared.mute(42, false)
        try await waitUntil("unmute scalar") { abs((observer?.current() ?? -1) - 0.65) < 0.001 }

        // Keep the worker occupied with a real property read while slider input
        // arrives. This checks that the old read cannot erase the latest intent.
        FakeHAL.shared.fire(42, selector: kAudioDevicePropertyMute)
        let burst = measure {
            for value in 1...80 { observer?.setVolume(Double(value) / 100) }
        }
        try expect(burst < 30 && abs((observer?.current() ?? -1) - 0.8) < 0.001,
                   "slider updates return immediately with latest optimistic cache")
        try await waitUntil("latest slider write") { FakeHAL.shared.writes().last?.volume == Float32(0.8) }
        try await waitUntil("latest slider callback") { events.values().last.map { abs($0 - 0.8) < 0.001 } == true }
        try expect(FakeHAL.shared.writes().count <= 2, "slider burst coalesces queued HAL writes")

        FakeHAL.shared.route(43)
        try await waitUntil("new route publication") { events.values().last.map { abs($0 - 0.3) < 0.001 } == true }
        try await waitUntil("new route listeners") { FakeHAL.shared.hasListeners(43) }
        try expect(!FakeHAL.shared.hasListeners(42), "old route listeners are removed")
        let beforeFailure = events.values().count
        FakeHAL.shared.omitVolume(true)
        FakeHAL.shared.fire(43, selector: kAudioDevicePropertyMute)
        try await waitUntil("transient scalar error refresh") { events.values().count > beforeFailure }
        try expect(abs((observer?.current() ?? -1) - 0.3) < 0.001,
                   "transient scalar read failure preserves the last successful scalar")
        FakeHAL.shared.route(44)
        try await waitUntil("unsupported new route fallback") { events.values().last == 0.5 }
        FakeHAL.shared.omitVolume(false)
        FakeHAL.shared.route(43)
        try await waitUntil("restored route scalar") { events.values().last.map { abs($0 - 0.3) < 0.001 } == true }
        observer?.setVolume(0.91)
        try await waitUntil("new route write") {
            FakeHAL.shared.writes().last == FakeHAL.Write(device: 43, volume: Float32(0.91))
        }
        FakeHAL.shared.mute(43, true)
        try await waitUntil("new route mute") { observer?.current() == 0 }
        weak var released = observer
        let cleanup = measure { observer = nil }
        try expect(cleanup < 30, "listener cleanup must not block release caller")
        try await waitUntil("observer deallocation") { released == nil }
        released = nil
        try await waitUntil("listener cleanup") { FakeHAL.shared.listenerCount() == 0 }
        try expect(FakeHAL.shared.mainCallCount() == 0, "no HAL calls on the main thread")
        print(String(format: "Slider burst %.1f ms, release %.1f ms, HAL writes %d", burst, cleanup, FakeHAL.shared.writes().count))

        // Force slider input into the middle of startup's slow scalar read.
        // The stale initial scalar must never be published over the new intent.
        FakeHAL.shared.mute(43, false)
        let startingReads = FakeHAL.shared.volumeReadCount()
        let startupEvents = Changes()
        observer = SystemVolumeObserver()
        observer?.start(onChange: { value, _ in startupEvents.append(value) })
        try await waitUntil("startup read began") { FakeHAL.shared.volumeReadCount() > startingReads }
        observer?.setVolume(0.77)
        try await waitUntil("startup pending intent") {
            startupEvents.values().last.map { abs($0 - 0.77) < 0.001 } == true
        }
        try expect(startupEvents.values().allSatisfy { abs($0 - 0.77) < 0.001 },
                   "slow initial read cannot publish old scalar over new slider intent")
        observer = nil
        try await waitUntil("second cleanup") { FakeHAL.shared.listenerCount() == 0 }

        // Some output routes have mute but no writable volume scalar.
        FakeHAL.shared.omitVolume(true)
        FakeHAL.shared.mute(43, true)
        let fallbackEvents = Changes()
        observer = SystemVolumeObserver()
        observer?.start(onChange: { value, _ in fallbackEvents.append(value) })
        try await waitUntil("fixed volume mute") { fallbackEvents.values().last == 0 }
        FakeHAL.shared.mute(43, false)
        try await waitUntil("fixed volume fallback") { fallbackEvents.values().last == 0.5 }
        observer = nil
        try await waitUntil("third cleanup") { FakeHAL.shared.listenerCount() == 0 }
        _ = observer
        print("PASS: system-volume caller responsiveness, initial mute, startup/latest intent, route changes, unavailable scalar fallback and async cleanup with slow fake HAL")
    }
}
