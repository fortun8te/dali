import Foundation

/// Picks the AirPlay buffer for the Wi-Fi link the Mac has right now.
///
/// The buffer is also the time a speaker has to get a lost packet sent again. Four
/// weeks of engine logs show 500 ms is plenty on a healthy link (the Sonos' median
/// retransmit requests were 0), but on a weak link, or on the crowded 2.4 GHz band,
/// packets are lost often enough that the extra time keeps the repairs from arriving
/// late. A wired Mac, or a strong 5 GHz link, keeps the short buffer, so sound and
/// volume stay as quick as possible.
///
/// A speaker that keeps losing packets whatever the signal (a busy Mac, a crowded room)
/// also gets the longer buffer: `PacketLossMonitor` notices it and the longer buffer is
/// remembered for a day (`lossMemorySeconds`).
public enum BufferPolicy {
    /// How long a sustained loss keeps the longer buffer.
    public static let lossMemorySeconds: TimeInterval = 24 * 3600
    public static let healthyMs = RoomDelayPolicy.automaticStartBufferMs   // 500
    public static let weakLinkMs = 800
    /// At or below this the 5 GHz link is marginal for steady streaming.
    public static let weakRSSI = -67

    /// - Parameters:
    ///   - rssi: Wi-Fi signal in dBm, nil or 0 when the Mac is not on Wi-Fi.
    ///   - is24GHz: the Wi-Fi is on the 2.4 GHz band.
    ///   - lossRaisedUntil: when a sustained packet loss last raised the buffer, until then.
    public static func startBufferMs(rssi: Int?, is24GHz: Bool,
                                     lossRaisedUntil: Date? = nil, now: Date = Date()) -> Int {
        if let lossRaisedUntil, lossRaisedUntil > now { return weakLinkMs }
        guard let rssi, rssi != 0 else { return healthyMs }   // wired or unknown
        if is24GHz || rssi <= weakRSSI { return weakLinkMs }
        return healthyMs
    }
}
