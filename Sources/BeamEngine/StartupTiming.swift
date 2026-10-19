import Foundation
import Darwin

/// Launch-to-ready measurement. The debug log stamps lines with the time of day
/// only and V2 wrote no launch marker, so how long a launch took could only be
/// pieced together from three different logs (and the date guessed). These
/// helpers let the app say it directly.
public enum StartupTiming {
    /// When the kernel created process `pid`, or nil if it cannot be read.
    public static func processStart(pid: Int32 = getpid()) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Whole milliseconds from `start` to `end`, never negative.
    public static func milliseconds(from start: Date, to end: Date = Date()) -> Int {
        let ms = end.timeIntervalSince(start) * 1000
        guard ms.isFinite, ms > 0 else { return 0 }
        return Int(min(ms, Double(Int.max / 2)).rounded())
    }

    /// "3.4 s", or "850 ms" under a second: short enough to read in a log line.
    public static func label(milliseconds ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}
