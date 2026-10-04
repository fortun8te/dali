import Foundation

public struct RoomVolumeSpeaker: Equatable, Sendable {
    public var id: String
    public var slider: Double
    public var gain: Double
    public var enabled: Bool

    public init(id: String, slider: Double, gain: Double = 1, enabled: Bool = true) {
        self.id = id; self.slider = slider; self.gain = gain; self.enabled = enabled
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
            let gain = bounded(speaker.gain, fallback: 1, lower: 0.25, upper: 4)
            let base = curve.map { slider * $0 * (ceiling / 100) } ?? slider
            // V1 applies both caps before rounding, including fractional ceilings.
            let limited = min(min(base * gain, 100), ceiling)
            hardware[speaker.id] = silent || !speaker.enabled ? 0 : Int(max(limited, 0).rounded())
        }
        return RoomVolumePlan(hardware: hardware, pcmGain: silent ? 0 : 1)
    }

    private static func bounded(_ value: Double, fallback: Double,
                                lower: Double, upper: Double) -> Double {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }
}
