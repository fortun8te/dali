import AVFoundation
import Foundation
import ObjectiveC

/// The private AirPlay routing surface the Apple-managed sender depends on.
/// Everything here is resolved at runtime; checking support never creates a
/// context, renderer or route, and never invokes a private selector.
public enum AppleRouteAPI {
    public struct Requirement: Equatable, Sendable {
        public let className: String
        public let selector: String
        public let isClassMethod: Bool
    }

    public static let requirements: [Requirement] = [
        .init(className: "AVOutputContext", selector: "outputContextForID:", isClassMethod: true),
        .init(className: "AVOutputContext", selector: "outputDevices", isClassMethod: false),
        .init(className: "AVSampleBufferAudioRenderer", selector: "setOutputContext:", isClassMethod: false),
    ]

    /// Requirements the running macOS does not provide. Empty means supported.
    public static func missing(
        has: (Requirement) -> Bool = runtimeHas
    ) -> [Requirement] {
        requirements.filter { !has($0) }
    }

    /// The output context the speaker picker and the renderer must share, as
    /// Airlift does: the default shared context, else the iTunes audio context.
    /// This context is system-shared, not DALI-owned; choosing speakers on it
    /// may also move the Mac's own output.
    public static func sharedContextID() -> String? {
        guard missing().isEmpty, let cls = NSClassFromString("AVOutputContext") as? NSObject.Type else { return nil }
        for name in ["defaultSharedOutputContext", "iTunesAudioContext"] {
            let selector = NSSelectorFromString(name)
            guard cls.responds(to: selector),
                  let context = cls.perform(selector)?.takeUnretainedValue() as? NSObject else { continue }
            for key in ["ID", "contextID"] {
                if let id = property(context, key) as? String, !id.isEmpty { return id }
            }
        }
        return nil
    }

    /// Display names of the speakers currently in the context. Read-only.
    public static func speakerNames(contextID: String) -> [String] {
        guard missing().isEmpty, let cls = NSClassFromString("AVOutputContext") as? NSObject.Type,
              let context = cls.perform(NSSelectorFromString("outputContextForID:"), with: contextID)?
                  .takeUnretainedValue() as? NSObject,
              let devices = property(context, "outputDevices") as? [NSObject] else { return [] }
        return devices.map { (property($0, "deviceName") as? String) ?? String(describing: $0) }
    }

    /// Key-value read that returns nil instead of raising for an unknown key
    /// (an Objective-C exception would crash Swift).
    static func property(_ object: NSObject, _ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    /// Take every speaker out of the route, which also lets go of the AirPlay clock
    /// ports Apple's AirPlay holds while speakers are connected. Needs no device objects.
    @discardableResult
    public static func clearSpeakers(contextID: String) -> Bool {
        guard missing().isEmpty, let cls = NSClassFromString("AVOutputContext") as? NSObject.Type,
              let context = cls.perform(NSSelectorFromString("outputContextForID:"), with: contextID)?
                  .takeUnretainedValue() as? NSObject else { return false }
        let selector = NSSelectorFromString("setOutputDevices:")
        guard context.responds(to: selector) else { return false }
        _ = context.perform(selector, with: [NSObject]() as NSArray)
        return true
    }

    /// Set each named speaker's AirPlay volume (0...1). Returns how many were set.
    /// Speakers in the route that are not named keep their volume.
    @discardableResult
    public static func setSpeakerVolumes(contextID: String, volumes: [String: Float]) -> Int {
        guard missing().isEmpty, let cls = NSClassFromString("AVOutputContext") as? NSObject.Type,
              let context = cls.perform(NSSelectorFromString("outputContextForID:"), with: contextID)?
                  .takeUnretainedValue() as? NSObject,
              let devices = property(context, "outputDevices") as? [NSObject] else { return 0 }
        typealias SetVolume = @convention(c) (AnyObject, Selector, Float) -> Void
        var applied = 0
        for device in devices {
            guard let name = property(device, "deviceName") as? String, let value = volumes[name] else { continue }
            for selectorName in ["setDeviceVolume:", "setVolume:"] {
                let selector = NSSelectorFromString(selectorName)
                guard device.responds(to: selector),
                      let method = class_getInstanceMethod(type(of: device), selector),
                      // Only call it as (id, SEL, float) -> void; anything else would corrupt the stack.
                      let encoding = method_getTypeEncoding(method),
                      String(cString: encoding).hasPrefix("v") , String(cString: encoding).contains("f") else { continue }
                let call = unsafeBitCast(method_getImplementation(method), to: SetVolume.self)
                call(device, selector, min(max(value, 0), 1))
                applied += 1
                break
            }
        }
        return applied
    }

    public static func runtimeHas(_ requirement: Requirement) -> Bool {
        guard let cls = NSClassFromString(requirement.className) else { return false }
        let selector = NSSelectorFromString(requirement.selector)
        let method = requirement.isClassMethod
            ? class_getClassMethod(cls, selector)
            : class_getInstanceMethod(cls, selector)
        return method != nil
    }
}
