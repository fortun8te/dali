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

/// Preserve V1's receiver master curve. Captured PCM stays at unity for positive
/// master settings; zero and explicit cuts also silence PCM for safe admission.
public enum RoomVolumePolicy {
    public static func plan(speakers: [RoomVolumeSpeaker], ceiling: Double,
                            systemMaster: Double? = nil, muted: Bool = false) -> RoomVolumePlan {
        let ceiling = bounded(ceiling, fallback: 40, lower: 1, upper: 100)
        let master = systemMaster.map { bounded($0, fallback: 0, lower: 0, upper: 1) }
        let silent = muted || master == 0
        let curve = master.map { pow($0, 0.7) }
        var hardware: [String: Int] = [:]
        for speaker in speakers {
            let slider = bounded(speaker.slider, fallback: 0, lower: 0, upper: 100)
            let gain = effectiveGain(for: speaker, systemMaster: master)
            let base = curve.map { slider * $0 * (ceiling / 100) } ?? slider
            // V1 applies both caps before rounding, including fractional ceilings.
            let limited = min(min(base * gain, 100), ceiling)
            hardware[speaker.id] = silent || !speaker.enabled ? 0 : Int(max(limited, 0).rounded())
        }
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
