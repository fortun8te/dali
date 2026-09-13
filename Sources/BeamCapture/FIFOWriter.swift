// Writer for the OwnTone FIFO pipe.
//
// CRITICAL DESIGN (root cause of the "both speakers stop, must reconnect" bug):
// a FIFO delivers EOF to its reader the instant it has ZERO writers. OwnTone
// treats that EOF as end-of-stream and tears down every AirPlay output at once,
// with no auto-reconnect. The old writer closed its fd on EPIPE and reopened
// lazily, so any transient with no writer (or the ~100ms gap on a tap rebuild)
// produced an EOF and dropped both speakers.
//
// Fix: open the pipe ONCE as O_RDWR | O_NONBLOCK and hold it for the whole
// session. O_RDWR means the kernel always counts us as both a reader and a
// writer, so the pipe can never reach zero readers OR zero writers no matter
// what OwnTone does. We never read from it; OwnTone gets all the audio we write.
// We never close it except on a real teardown. Result: OwnTone never sees EOF.
//
// When the pipe is momentarily full (reader busy) data is BUFFERED and retried,
// never dropped in normal operation. The in-process backlog is bounded only so a
// stuck reader cannot grow it without limit — hitting that bound is a FAULT, and
// is counted loudly (see droppedBytes / dropEvents below), not shrugged off.

import Foundation

public final class FIFOWriter {
    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "beam.fifo.write")
    private var pending = Data()
    private var retryScheduled = false

    // Backpressure is DESIGNED here, not accidental: OwnTone deliberately stops
    // reading once its own input buffer is ~2.18s deep, so a multi-second backlog
    // on our side is the system working as intended. It must be BUFFERED — every
    // dropped byte splices an audible click into live audio.
    //
    // This cap therefore exists only to bound memory against a reader that has
    // genuinely died. 8s of headroom sits comfortably above OwnTone's ~2.18s
    // threshold plus start-up prebuffer, so normal operation never reaches it.
    // A NONZERO droppedBytes/dropEvents IS A REAL FAULT — a stuck or dead reader —
    // never routine trimming. Treat any nonzero value in telemetry as a bug to
    // chase, not as noise to filter out.
    private static let maxPending = 1_411_200 // 8.0s at 176_400 B/s
    private static let frame = 4              // s16le stereo: 2ch * 2 bytes
    // MEASURED on macOS: a FIFO opened O_RDWR|O_NONBLOCK holds exactly 8192 bytes
    // = 0.046s of s16le/44100/stereo. That is the whole pipe. (The old comment
    // here claimed 64KB "BIG_PIPE_SIZE" and used a 16384 chunk — i.e. a chunk
    // twice the size of the entire pipe, so every write partially failed.)
    // Linux is 64 KiB by default and growable via F_SETPIPE_SZ; macOS has neither,
    // which is why this whole design is far more fragile here than on Linux:
    // 46ms of kernel slack means we live or die on our own retry loop.
    private static let writeChunk = 8_192

    public private(set) var droppedBytes: Int = 0
    /// Number of distinct overflow events (a burst is one event, not one per byte).
    /// Any value > 0 means the reader stopped consuming for >8s: a real fault.
    public private(set) var dropEvents: Int = 0
    /// Unix ms of the most recent drop, 0 if audio has never been discarded.
    public private(set) var lastDropUnixMs: Double = 0
    /// Sticky alarm flag: once true it stays true for the life of this writer, so
    /// a drop can never scroll out of a sampled telemetry window unnoticed.
    public private(set) var hasDroppedAudio = false
    public private(set) var writtenBytes: Int = 0
    public private(set) var peakPending: Int = 0
    /// Read on the writer queue so retries and telemetry share the same state.
    public var pendingBytes: Int { queue.sync { pending.count } }
    public private(set) var eagainCount: Int = 0    // times the pipe was full (backpressure)
    public private(set) var lastWriteUnixMs: Double = 0  // when the pipe last accepted bytes

    public init(path: String) {
        self.path = path
        signal(SIGPIPE, SIG_IGN)
    }

    private func ensureOpen() -> Bool {
        if fd >= 0 { return true }
        // O_RDWR keeps the pipe permanently non-empty of readers AND writers, so
        // OwnTone never gets an EOF. O_RDWR on a FIFO also never blocks on open.
        fd = open(path, O_RDWR | O_NONBLOCK)
        return fd >= 0
    }

    public func write(_ data: Data) {
        queue.async { [self] in
            pending.append(data)
            if pending.count > Self.maxPending {
                // We are past 8s of backlog: the reader is not merely applying
                // back-pressure, it is gone. Bound memory by dropping oldest,
                // frame-aligned, in one batch (avoids repeated O(n) trims and
                // never splits a stereo sample) — and RAISE THE ALARM. This path
                // is a fault report, not a routine housekeeping step.
                var overflow = pending.count - Self.maxPending
                overflow -= overflow % Self.frame
                if overflow > 0 {
                    pending.removeFirst(overflow)
                    droppedBytes += overflow
                    dropEvents += 1
                    hasDroppedAudio = true
                    lastDropUnixMs = Date().timeIntervalSince1970 * 1000
                    FileHandle.standardError.write(Data(
                        "FIFOWriter FAULT: reader stalled >8s, discarded \(overflow) B of live audio (total \(droppedBytes) B over \(dropEvents) events)\n".utf8))
                }
            }
            peakPending = max(peakPending, pending.count)
            flush()
        }
    }

    /// Runs on `queue`. Writes as much pending data as the pipe accepts.
    /// On EAGAIN (pipe full) it retries soon. It NEVER closes the fd on EPIPE:
    /// closing is what caused the zero-writer EOF. A transient with no reader is
    /// impossible because we hold an O_RDWR fd ourselves.
    private func flush() {
        guard !pending.isEmpty else { return }
        guard ensureOpen() else { scheduleRetry(); return }

        while !pending.isEmpty {
            let n: Int = pending.withUnsafeBytes { raw in
                Foundation.write(fd, raw.baseAddress, min(raw.count, Self.writeChunk))
            }
            if n > 0 {
                pending.removeFirst(n)
                writtenBytes += n
                lastWriteUnixMs = Date().timeIntervalSince1970 * 1000
            } else {
                // EAGAIN (pipe full) or a transient error: keep the fd open and
                // retry promptly. Do NOT close on EPIPE.
                eagainCount += 1
                scheduleRetry()
                return
            }
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        // Tight 1ms poll: the pipe drains 176400 B/s, so 1ms frees ~176 bytes.
        // Polling 1000x/s keeps `pending` flat instead of the old 5ms (200x/s)
        // poll that let a backpressure burst climb toward maxPending and drop.
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
            retryScheduled = false
            flush()
        }
    }

    public func closePipe() {
        queue.sync {
            pending.removeAll()
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    deinit { if fd >= 0 { close(fd) } }
}
