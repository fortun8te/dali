import Foundation
import CoreAudio

/// Read-only source eligibility, never proof that a tap delivered PCM. Called
/// on a dedicated background queue, outside capture/publication locks.
public enum AudioSourceActivity {
    public struct ProcessOutput: Sendable {
        public let pid: pid_t?
        public let isRunningOutput: Bool?
        public init(pid: pid_t?, isRunningOutput: Bool?) {
            self.pid = pid; self.isRunningOutput = isRunningOutput
        }
    }

    public static func classify(_ processes: [ProcessOutput], source: ProcessTap.Source,
                                ownPID: pid_t) -> Bool? {
        var unknown = false
        for process in processes {
            guard let pid = process.pid else { unknown = true; continue }
            switch source {
            case .system:
                // Our own tap aggregate can be output-active while every
                // actual source is idle. It cannot establish source demand.
                if pid == ownPID { continue }
            case .process(let selectedPID):
                if pid != selectedPID { continue }
            }
            if process.isRunningOutput == true { return true }
            if process.isRunningOutput == nil { unknown = true }
        }
        return unknown ? nil : false
    }

    public static func isOutputActive(source: ProcessTap.Source) -> Bool? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count <= 4096 else { return nil }
        if count == 0 { return false }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return nil }

        func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
            var property = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var result: UInt32 = 0
            var bytes = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, &result) == noErr,
                  bytes == MemoryLayout<UInt32>.size else { return nil }
            return result
        }
        var processes = [ProcessOutput]()
        let ownPID = getpid()
        for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
            let pid = value(object, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) }
            if source == .system, pid == ownPID { continue }
            if case .process(let selectedPID) = source, let pid, pid != selectedPID { continue }
            let running = value(object, kAudioProcessPropertyIsRunningOutput).map { $0 != 0 }
            processes.append(ProcessOutput(pid: pid, isRunningOutput: running))
        }
        return classify(processes, source: source, ownPID: ownPID)
    }
}
