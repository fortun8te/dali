// Tracks whether captured audio has been effectively silent.
// Pure math, unit-tested. Threshold -60 dBFS by default.

import Foundation

public struct SilenceDetector {
    public let thresholdDB: Double
    private(set) public var silentSeconds: Double = 0

    public init(thresholdDB: Double = -60) {
        self.thresholdDB = thresholdDB
    }

    /// Feed RMS level of a chunk plus its duration; returns total silent seconds.
    @discardableResult
    public mutating func feed(rmsDB: Double, duration: Double) -> Double {
        if rmsDB < thresholdDB {
            silentSeconds += duration
        } else {
            silentSeconds = 0
        }
        return silentSeconds
    }

    /// RMS in dBFS of interleaved Int16 samples.
    public static func rmsDB(int16Samples: UnsafePointer<Int16>, count: Int) -> Double {
        guard count > 0 else { return -120 }
        var acc: Double = 0
        for i in 0..<count {
            let v = Double(int16Samples[i]) / 32768.0
            acc += v * v
        }
        let rms = (acc / Double(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }
}
