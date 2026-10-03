import Foundation
struct RoomSpeaker { var enabled = true; var relVolume: Double; var gain: Double = 1 }
final class Probe {
 var roomMutedByCut = false; var playerMode = false; var systemVolume = 1.0; var volumeLimit = 40.0
 enum Source { case system, app, spotify }; var source = Source.system
    func effectiveVolume(_ s: RoomSpeaker) -> Int {
        guard !roomMutedByCut else { return 0 }   // video stopped: silence everything now
        guard s.enabled else { return 0 }   // muted but still in the group (sync)
        let base: Double
        if playerMode {
            // Player model: the engine sources the audio, so the Mac's own volume
            // is irrelevant. Each speaker's slider IS its absolute AirPlay volume.
            base = s.relVolume
        } else {
            switch source {
            // Map the Mac's full 0...100% master range across the room's safe
            // 0...volumeLimit range. The old formula hit the limit at only 20%
            // Mac volume (then a second 15% cap flattened it again), so most
            // volume-key presses appeared to do nothing.
            case .system:
                // The Mac's slider is linear but AirPlay volume is a dB scale, and
                // the Bluesound front sits at about -53 dB for engine volume 31
                // (-60 dB at 19): below roughly Mac 30% the front was simply
                // inaudible and the room "played nothing". A gentle curve lifts the
                // low end (Mac 18% -> 30, 31% -> 44, 68% -> 76) and leaves 0 and
                // 100% where they were.
                let curved = pow(min(max(systemVolume, 0), 1), 0.7)
                base = s.relVolume * curved * (volumeLimit / 100)
            case .app:    base = s.relVolume
            case .spotify: base = s.relVolume
            }
        }
        // Calibration gain balances devices of different efficiency.
        let raw = min(base * s.gain, 100)
        let limited = min(raw, volumeLimit)
        // Int(NaN) traps. min() propagates a NaN from a bad Mac-volume read or a
        // corrupt stored value, so refuse it here rather than at every caller.
        guard limited.isFinite else { return 0 }
        return Int(max(limited, 0).rounded())
    }

}
let p = Probe()
let front = RoomSpeaker(relVolume:50)
let back = RoomSpeaker(relVolume:40)
let full = p.effectiveVolume(front) - p.effectiveVolume(back)
p.systemVolume = 0.25
let low = p.effectiveVolume(front) - p.effectiveVolume(back)
print("Actual V1 function: master100 front-back=\(full), master25 front-back=\(low)")
if full != low { print("FAIL: receiver calibration changes with master"); exit(1) }
