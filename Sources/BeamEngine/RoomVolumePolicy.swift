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

/// Receiver calibration is a reference setting, not a value multiplied by every
/// Mac volume event. Captured system audio receives the same quadratic PCM
/// attenuation on both channels, independent of speaker settings, so changing
/// the master cannot change the receiver settings or the calibrated difference.
public enum RoomVolumePolicy {
    public static func plan(speakers: [RoomVolumeSpeaker], ceiling: Double,
                            systemMaster: Double? = nil, muted: Bool = false) -> RoomVolumePlan {
        let ceiling = floor(bounded(ceiling, fallback: 40, lower: 1, upper: 100))
        let refs = speakers.map { speaker -> (String, Double) in
            let slider = bounded(speaker.slider, fallback: 0, lower: 0, upper: 100)
            let gain = bounded(speaker.gain, fallback: 1, lower: 0.25, upper: 4)
            return (speaker.id, slider * gain * (systemMaster == nil ? 1 : ceiling / 100))
        }
        // Preserve each saved V1 full-master reference, capped once. The
        // shared PCM master removes moving clipping; recalibrating a partner
        // when one slider changes would undo the user's saved balance.
        var hardware: [String: Int] = [:]
        for (id, value) in refs {
            hardware[id] = Int(min(ceiling, max(0, value)).rounded())
        }
        // Muting one member must not recalibrate or turn up its partner.
        for speaker in speakers where !speaker.enabled { hardware[speaker.id] = 0 }
        var pcmGain = 1.0
        if let systemMaster {
            let master = bounded(systemMaster, fallback: 0, lower: 0, upper: 1)
            pcmGain = softwareGain(master: master)
            if master == 0 { hardware = hardware.mapValues { _ in 0 } }
        }
        if muted { hardware = hardware.mapValues { _ in 0 }; pcmGain = 0 }
        return RoomVolumePlan(hardware: hardware, pcmGain: pcmGain)
    }

    public static func softwareGain(master: Double) -> Double {
        guard master.isFinite, master > 0 else { return 0 }
        let master = min(master, 1)
        // Low Mac settings must stay quiet at every receiver calibration.
        return master * master
    }

    private static func bounded(_ value: Double, fallback: Double,
                                lower: Double, upper: Double) -> Double {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }
}
