import Foundation

/// A captured level waits for the room's presentation time. `at` is the audio
/// capture time, not the later UI poll time; this keeps queue and analysis work
/// from adding a second delay to the picture.
public struct RoomLevelSample {
    public let at: Date
    public let level: Double
    public let bass: Double
    public let treble: Double
    public let beats: Int
    public let beatAt: Date?

    public init(at: Date, level: Double, bass: Double, treble: Double,
                beats: Int, beatAt: Date?) {
        self.at = at
        self.level = level
        self.bass = bass
        self.treble = treble
        self.beats = beats
        self.beatAt = beatAt
    }
}

public struct RoomLevelTimeline {
    private var samples: [RoomLevelSample] = []

    public init() {}

    /// Absolute ceiling, independent of any poll: a producer that keeps appending
    /// while nothing drains the line (UI paused, view hidden) must not grow
    /// without bound. Well above the ~125 samples RoomDelayPolicy's longest delay
    /// needs at 30 Hz, and it only drops the oldest.
    private static let hardCapacity = 1_024

    public mutating func append(_ sample: RoomLevelSample) {
        samples.append(sample)
        if samples.count > Self.hardCapacity {
            samples.removeFirst(samples.count - Self.hardCapacity)
        }
    }

    public mutating func latestDue(at now: Date, delay: TimeInterval) -> RoomLevelSample? {
        // A NaN/infinite delay (a corrupt calibration read) must not reach the
        // Int conversion below: Int(.nan) and Int(.infinity) trap.
        let delay = delay.isFinite ? min(max(delay, 0), 3_600) : 0
        let due = now.addingTimeInterval(-delay)
        var dueCount = 0
        while dueCount < samples.count, samples[dueCount].at <= due { dueCount += 1 }
        let newest = dueCount > 0 ? samples[dueCount - 1] : nil
        if dueCount > 0 { samples.removeFirst(dueCount) }
        // RoomDelayPolicy permits up to 3.6 seconds. At 30 Hz, a fixed 60
        // samples would erase the start of a delayed beat before it was due.
        let capacity = min(Self.hardCapacity, max(60, Int(ceil((delay + 0.5) * 30))))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        return newest
    }

    public mutating func clear() { samples.removeAll(keepingCapacity: true) }
}
