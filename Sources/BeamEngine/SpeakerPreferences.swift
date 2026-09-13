import Foundation

/// Preference reads never overwrite a room which was configured by an earlier
/// app version. In particular, a fresh install has no preselected speakers.
public struct SpeakerPreferences {
    public let frontName: String
    public let backName: String
    public let volumeLimit: Double
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        frontName = defaults.string(forKey: "dali.frontName") ?? ""
        backName = defaults.string(forKey: "dali.backName") ?? ""
        volumeLimit = Self.bounded(defaults.object(forKey: "dali.volumeLimit") as? Double,
                                   fallback: 40, range: 1...100)
    }

    public func enabled(name: String, primary: Bool) -> Bool {
        defaults.object(forKey: "dali.on.\(name)") as? Bool ?? primary
    }

    public func volume(name: String) -> Double {
        Self.bounded(defaults.object(forKey: "dali.vol.\(name)") as? Double,
                     fallback: 50, range: 0...100)
    }

    public func gain(name: String) -> Double {
        Self.bounded(defaults.object(forKey: "dali.gain.\(name)") as? Double,
                     fallback: 1, range: 0.25...4)
    }

    /// Keep selected speakers visible across app relaunches even when discovery
    /// has not found them yet. A missing speaker must not make the room look healthy.
    public var rememberedNames: Set<String> {
        let prefix = "dali.on."
        var names = Set([frontName, backName].filter { !$0.isEmpty })
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(prefix) && (value as? Bool) == true {
            let name = String(key.dropFirst(prefix.count))
            if !name.isEmpty { names.insert(name) }
        }
        return names
    }

    private static func bounded(_ value: Double?, fallback: Double,
                                range: ClosedRange<Double>) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Once a speaker joins a playing room, switching it off means mute. Removing
/// an AirPlay member can reset the clock of every other speaker in the group.
/// Names survive an engine output-ID change after a network interruption.
public struct SpeakerSessionMembership {
    private var names: Set<String> = []

    public init() {}

    public mutating func retain(_ name: String) { names.insert(name) }
    public mutating func reset() { names.removeAll() }

    public func contains(name: String, enabled: Bool, primary: Bool) -> Bool {
        primary || enabled || names.contains(name)
    }
}
