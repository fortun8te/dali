import Foundation

/// The bundled engine's nominal presentation delay, shared by video and the
/// room animation. This is a scheduling estimate, not a microphone measurement.
public enum RoomDelayPolicy {
    // Keep these in step with the bundled airplay.c. This fork sends audio with
    // start_buffer_ms - 50 ms lead, while SETUP advertises latencyMin = 11025
    // samples at 44100 Hz (250 ms). The difference is 200 ms, not another full
    // receiver buffer added to start_buffer_ms.
    public static let schedulingLatencyMs = 50.0
    public static let receiverLatencyMs = 250.0

    public static func seconds(startBufferMs: Int, trimMs: Double) -> Double {
        let buffer = Double(min(max(startBufferMs, 500), 3000))
        let trim = trimMs.isFinite ? min(max(trimMs, -400), 400) : 0
        let milliseconds = buffer - schedulingLatencyMs + receiverLatencyMs + trim
        return min(max(milliseconds / 1000, 0.1), 4)
    }
}
