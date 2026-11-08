import Foundation

public struct RoomVolumeSpeaker: Equatable, Sendable {
    public var id: String
    public var slider: Double
    public var gain: Double
    public var enabled: Bool
    /// The speaker's one loudness mode: a curve over the Mac master volume plus a
    /// single balance trim in percent (-30...30) that shifts the whole curve. When
    /// set, the saved fixed `gain` is ignored (it stays saved, untouched).
    public var curve: SpeakerLevelCurve?
    public var trim: Double

    public init(id: String, slider: Double, gain: Double = 1, enabled: Bool = true,
                curve: SpeakerLevelCurve? = nil, trim: Double = 0) {
        self.id = id; self.slider = slider; self.gain = gain; self.enabled = enabled
        self.curve = curve; self.trim = trim
    }
}

public struct RoomVolumePlan: Equatable, Sendable {
    public let hardware: [String: Int]
    public let pcmGain: Double
}

/// The Mac volume drives each speaker's own volume command, in equal steps.
///
/// Both receivers take DALI's command as their own volume percentage (measured 2 Nov
/// 2026: command 42 -> Powernode 43 %, command 47 -> Sonos 47 %), and the Powernode is
/// close to even in dB across that scale (22 % = -49.8 dB, 43 % = -35.1 dB, about
/// 0.7 dB per percent). So a command that rises evenly with the Mac volume gives every
/// one of the 16 volume keys the same change, about 3 dB at a 70 limit.
///
/// The earlier V1 curve (master^0.7) and the shared quiet-end PCM fade made the first
/// key a ~10 dB jump, the top keys about 2 dB, and the quiet end change in two
/// pieces a room delay apart. Both are gone: the captured audio stays at unity unless
/// the room is muted.
public enum RoomVolumePolicy {
    /// Exponent of the Mac master in the receiver command. 1 = even steps.
    public static let masterExponent = 1.0

    public static func plan(speakers: [RoomVolumeSpeaker], ceiling: Double,
                            systemMaster: Double? = nil, muted: Bool = false) -> RoomVolumePlan {
        let ceiling = bounded(ceiling, fallback: 40, lower: 1, upper: 100)
        let master = systemMaster.map { bounded($0, fallback: 0, lower: 0, upper: 1) }
        let silent = muted || master == 0
        let curve = master.map { pow($0, masterExponent) }
        var hardware: [String: Int] = [:]
        for speaker in speakers {
            let slider = bounded(speaker.slider, fallback: 0, lower: 0, upper: 100)
            let gain = effectiveGain(for: speaker, systemMaster: master)
            let base = curve.map { slider * $0 * (ceiling / 100) } ?? slider
            // V1 applies both caps before rounding, including fractional ceilings.
            let limited = min(min(base * gain, 100), ceiling)
            hardware[speaker.id] = silent || !speaker.enabled ? 0 : Int(max(limited, 0).rounded())
        }
        // Loudness lives in the receiver commands alone, so a volume key is one change.
        return RoomVolumePlan(hardware: hardware, pcmGain: silent ? 0 : 1)
    }

    public static let trimRange: ClosedRange<Double> = -30...30

    /// The multiplier actually applied to a speaker at this Mac master volume
    /// (0...1; nil when the Mac volume is not driving the room, where the curve's
    /// settled top value applies). A speaker with a level curve is the curve times
    /// (1 + trim/100); everything else keeps its fixed saved gain.
    public static func effectiveGain(for speaker: RoomVolumeSpeaker, systemMaster: Double?) -> Double {
        let raw: Double
        if let curve = speaker.curve {
            let master = systemMaster.map { bounded($0, fallback: 0, lower: 0, upper: 1) } ?? 1
            let trim = bounded(speaker.trim, fallback: 0, lower: trimRange.lowerBound, upper: trimRange.upperBound)
            raw = curve.gain(atMaster: master) * (1 + trim / 100)
        } else {
            raw = speaker.gain
        }
        return bounded(raw, fallback: 1, lower: 0.25, upper: 4)
    }

    private static func bounded(_ value: Double, fallback: Double,
                                lower: Double, upper: Double) -> Double {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }
}
