import Foundation
#if canImport(BeamCapture)
import BeamCapture
#endif

/// Progress-derived fill is an estimate. Only the existing bounded, one-sided
/// refill policy can act on it; there is no bidirectional rate integrator.
struct RoomTimingController {
    struct Sample {
        var dt: Double
        var written: Int
        var pending: Int
        var produced: Int
        var silence: Int
        var dropped: Int
        var discontinuity: Bool
        var converterChanged: Bool
        var maximumGapMs: Double
        var player: String?
        var progressMs: Int?
        var queryMs: Int
        var controlBusy: Bool
    }
    struct Result {
        var fill: Double?
        var hold: String
        var ratio: Double
        var event: RefillController.Event?
    }
    private(set) var refill = RefillController()
    private(set) var hold = "startup"
    private var anchor: (progress: Int, written: Int, fill: Double)?
    private var previousWritten: Int?
    private var smoothedFill: Double?
    private var carryFill: Double?
    private var jumpStrikes = 0
    private var stoppedStrikes = 0
    private var controlHoldSec = 15.0

    mutating func reset() {
        self = RoomTimingController()
    }

    mutating func update(_ sample: Sample, target: Double) -> Result {
        let dt = sample.dt.isFinite ? min(max(sample.dt, 0.001), 10) : 1
        let target = target.isFinite ? min(max(target, 0.1), 3) : 0.7
        let writtenBackwards = previousWritten.map { sample.written < $0 } ?? false
        previousWritten = sample.written
        let hard = sample.discontinuity || sample.dropped > 0 || writtenBackwards
        if hard { anchor = nil; smoothedFill = nil; carryFill = nil; jumpStrikes = 0 }
        var reason = ""
        if hard { reason = "capture_reset" }
        else if sample.player == nil || sample.progressMs == nil { reason = "unknown_progress" }
        else if sample.player != "play" {
            reason = "not_playing"
            stoppedStrikes += 1
            if stoppedStrikes >= 3 { anchor = nil; smoothedFill = nil; carryFill = nil }
        } else if sample.queryMs > 250 { reason = "slow_query" }
        else if sample.converterChanged { reason = "converter" }
        else if sample.maximumGapMs > 120 { reason = "capture_gap" }
        else if Double(sample.pending) / 176_400 > 0.25 { reason = "backpressure" }
        else if Double(sample.silence) > 0.25 * Double(max(sample.produced, 1)) { reason = "silence" }
        if sample.player == "play" { stoppedStrikes = 0 }
        if sample.controlBusy { controlHoldSec = 15 }
        controlHoldSec = max(0, controlHoldSec - dt)

        var fill: Double?
        if reason.isEmpty, let progress = sample.progressMs {
            if let anchor {
                let estimate = anchor.fill + Double(sample.written - anchor.written) / 176_400
                    - Double(progress - anchor.progress) / 1000
                if let previous = smoothedFill, abs(estimate - previous) > 0.5 {
                    reason = "progress_jump"; jumpStrikes += 1
                    if jumpStrikes >= 3 {
                        carryFill = min(max(previous, -1), 3)
                        self.anchor = nil; smoothedFill = nil; jumpStrikes = 0
                    }
                } else {
                    jumpStrikes = 0
                    let previous = smoothedFill ?? estimate
                    smoothedFill = previous + (1 - exp(-dt / 20)) * (estimate - previous)
                    fill = smoothedFill
                }
            } else {
                anchor = (progress, sample.written, carryFill ?? target)
                carryFill = nil; reason = "new_anchor"
            }
        }
        if reason.isEmpty, controlHoldSec > 0 { reason = "control_settle" }
        hold = reason.isEmpty ? "refill:\(refill.label)" : reason
        let event = refill.update(dt: dt, target: target, fillSlow: fill,
                                  holdReason: reason, hard: hard)
        return Result(fill: fill, hold: hold, ratio: 1 - refill.eps, event: event)
    }
}
