import Foundation

/// One 30-second delivery report the engine writes for a speaker.
public struct DeliveryReport: Equatable, Sendable {
    public let device: String
    public let streaming: Bool
    public let sent: Int
    public let resendRequests: Int
    public let resendPackets: Int
    /// Resends the engine did not send: too late to help, duplicates, or over its own cap.
    public let resendSuppressed: Int
    public let sendErrors: Int

    public init(device: String, streaming: Bool = true, sent: Int, resendRequests: Int,
                resendPackets: Int, resendSuppressed: Int, sendErrors: Int) {
        self.device = device; self.streaming = streaming; self.sent = sent
        self.resendRequests = resendRequests; self.resendPackets = resendPackets
        self.resendSuppressed = resendSuppressed; self.sendErrors = sendErrors
    }

    /// Reads a line such as
    /// `... AI event=delivery_health device='MICHAEL D' sent_30s=3858 resend_req=104
    /// resend_pkts=100 resend_supp=4 send_err=0 feedback_age_s=20 state=streaming`.
    public static func parse(_ line: String) -> DeliveryReport? {
        guard line.contains("AI event=delivery_health") else { return nil }
        func number(_ key: String) -> Int? {
            guard let found = line.range(of: key + "=") else { return nil }
            return Int(line[found.upperBound...].prefix { $0.isNumber })
        }
        guard let open = line.range(of: "device='"),
              let close = line[open.upperBound...].firstIndex(of: "'"),
              let sent = number("sent_30s"), let requests = number("resend_req"),
              let packets = number("resend_pkts"), let suppressed = number("resend_supp"),
              let errors = number("send_err") else { return nil }
        return DeliveryReport(device: String(line[open.upperBound..<close]),
                              streaming: line.contains("state=streaming"),
                              sent: sent, resendRequests: requests, resendPackets: packets,
                              resendSuppressed: suppressed, sendErrors: errors)
    }
}

/// Decides when a speaker's packet loss is bad enough, for long enough, to need the
/// longer buffer.
///
/// A healthy window asks for about 0.1 to 0.6 % of its packets again (2 to 24 of ~3,760)
/// and the engine repairs them. A bad window asks for 2.4 % or more, or has resends the
/// engine could not send in time, or a failed send. One bad window is weather; two within
/// ten minutes (a severe one counts twice) is a pattern worth a longer buffer.
public struct PacketLossMonitor: Sendable {
    public static let badRequests = 90
    public static let badSuppressed = 20
    public static let severeRequests = 250
    public static let severeSuppressed = 40
    public static let patternSeconds: TimeInterval = 600
    public static let badWindowsNeeded = 2

    private var bad: [Date] = []

    public init() {}

    /// 0 healthy, 1 bad, 2 severe. A report from a speaker that is not streaming counts as 0.
    public static func weight(of report: DeliveryReport) -> Int {
        guard report.streaming else { return 0 }
        if report.resendRequests >= severeRequests || report.resendSuppressed >= severeSuppressed { return 2 }
        if report.resendRequests >= badRequests || report.resendSuppressed >= badSuppressed
            || report.sendErrors >= 1 { return 1 }
        return 0
    }

    /// Records a report; true once the pattern is there.
    public mutating func record(_ report: DeliveryReport, at now: Date) -> Bool {
        bad.removeAll { now.timeIntervalSince($0) > Self.patternSeconds }
        for _ in 0..<Self.weight(of: report) { bad.append(now) }
        return bad.count >= Self.badWindowsNeeded
    }

    public mutating func reset() { bad.removeAll() }
}
