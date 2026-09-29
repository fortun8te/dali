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
// We never close it except on a real teardown (or when the path now names a
// DIFFERENT inode — a recreated FIFO — where the old fd feeds a pipe nobody
// reads). Result: OwnTone never sees EOF.
//
// When the pipe is momentarily full (reader busy) data is BUFFERED and retried,
// never dropped in normal operation. The in-process backlog is bounded only so a
// stuck reader cannot grow it without limit — hitting that bound is a FAULT, and
// is counted loudly (see droppedBytes / dropEvents below), not shrugged off.
//
// THREADING: all state is confined to `queue` except the telemetry snapshot,
// which lives behind a Mutex so any thread can read it without queue.sync.

import Foundation
import Synchronization

public final class FIFOWriter: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "beam.fifo.write", qos: .userInitiated)
    // Backlog as a byte array plus a read offset: consuming from the front is
    // O(1) (the old Data.removeFirst memmoved the whole backlog per 8 KB write).
    private var buf = [UInt8]()
    private var readOff = 0
    private var retryScheduled = false
    private var fdIdentity: (dev: dev_t, ino: ino_t)?
    private var nextOpenNs: UInt64 = 0
    private var nextIdentityCheckNs: UInt64 = 0
    private var openFailures = 0
    private var warnedNotFifo = false

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

    private struct Stats {
        var droppedBytes = 0
        var dropEvents = 0
        var lastDropUnixMs = 0.0
        var hasDroppedAudio = false
        var writtenBytes = 0
        var peakPending = 0
        var pending = 0
        var eagainCount = 0
        var lastWriteUnixMs = 0.0
    }
    private let stats = Mutex(Stats())

    public var droppedBytes: Int { stats.withLock { $0.droppedBytes } }
    /// Number of distinct overflow events (a burst is one event, not one per byte).
    /// Any value > 0 means the reader stopped consuming for >8s: a real fault.
    public var dropEvents: Int { stats.withLock { $0.dropEvents } }
    /// Unix ms of the most recent drop, 0 if audio has never been discarded.
    public var lastDropUnixMs: Double { stats.withLock { $0.lastDropUnixMs } }
    /// Sticky alarm flag: once true it stays true for the life of this writer, so
    /// a drop can never scroll out of a sampled telemetry window unnoticed.
    public var hasDroppedAudio: Bool { stats.withLock { $0.hasDroppedAudio } }
    public var writtenBytes: Int { stats.withLock { $0.writtenBytes } }
    public var peakPending: Int { stats.withLock { $0.peakPending } }
    /// Backlog not yet accepted by the kernel pipe (snapshot; never blocks).
    public var pendingBytes: Int { stats.withLock { $0.pending } }
    public var eagainCount: Int { stats.withLock { $0.eagainCount } }    // times the pipe was full (backpressure)
    public var lastWriteUnixMs: Double { stats.withLock { $0.lastWriteUnixMs } }  // when the pipe last accepted bytes

    public init(path: String) {
        self.path = path
        signal(SIGPIPE, SIG_IGN)
    }

    private static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

    private var pendingCount: Int { buf.count - readOff }

    private func closeFD() {
        if fd >= 0 { close(fd) }
        fd = -1
        fdIdentity = nil
    }

    private func ensureOpen() -> Bool {
        if fd >= 0 { return true }
        let now = Self.nowNs()
        if now < nextOpenNs { return false }
        // The FIFO is created by whoever launches the engine; before that (or if
        // it was deleted) open() fails instantly with ENOENT. Back off instead of
        // spinning the queue at 1 kHz on a path that does not exist yet.
        var st = stat()
        guard stat(path, &st) == 0 else { failOpen(now); return false }
        guard (st.st_mode & S_IFMT) == S_IFIFO else {
            // A stale REGULAR file at the pipe path would happily accept O_RDWR
            // and swallow the audio forever. Refuse.
            if !warnedNotFifo {
                warnedNotFifo = true
                FileHandle.standardError.write(Data("FIFOWriter: \(path) is not a FIFO; not writing\n".utf8))
            }
            failOpen(now); return false
        }
        // O_RDWR keeps the pipe permanently non-empty of readers AND writers, so
        // OwnTone never gets an EOF. O_RDWR on a FIFO also never blocks on open.
        let f = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard f >= 0 else { failOpen(now); return false }
        _ = fcntl(f, F_SETNOSIGPIPE, 1)
        fd = f
        fdIdentity = (st.st_dev, st.st_ino)
        openFailures = 0
        warnedNotFifo = false
        nextIdentityCheckNs = now + 1_000_000_000
        return true
    }

    private func failOpen(_ now: UInt64) {
        openFailures += 1
        // 20ms .. 500ms
        let ms = min(500, 20 << min(openFailures - 1, 5))
        nextOpenNs = now + UInt64(ms) * 1_000_000
    }

    /// If the path now names a different inode than our fd (FIFO deleted and
    /// recreated), our fd feeds a pipe nobody reads. Drop it and reopen.
    private func checkIdentity() {
        let now = Self.nowNs()
        guard fd >= 0, now >= nextIdentityCheckNs else { return }
        nextIdentityCheckNs = now + 1_000_000_000
        var st = stat()
        if stat(path, &st) != 0 || st.st_dev != fdIdentity?.dev || st.st_ino != fdIdentity?.ino {
            closeFD()
            nextOpenNs = 0
        }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            data.withUnsafeBytes { buf.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            if pendingCount > Self.maxPending {
                // We are past 8s of backlog: the reader is not merely applying
                // back-pressure, it is gone. Bound memory by dropping oldest,
                // frame-aligned, in one batch (avoids repeated O(n) trims and
                // never splits a stereo sample) — and RAISE THE ALARM. This path
                // is a fault report, not a routine housekeeping step.
                var overflow = pendingCount - Self.maxPending
                overflow -= overflow % Self.frame
                if overflow > 0 {
                    readOff += overflow
                    let (total, events) = stats.withLock { s -> (Int, Int) in
                        s.droppedBytes += overflow
                        s.dropEvents += 1
                        s.hasDroppedAudio = true
                        s.lastDropUnixMs = Date().timeIntervalSince1970 * 1000
                        return (s.droppedBytes, s.dropEvents)
                    }
                    FileHandle.standardError.write(Data(
                        "FIFOWriter FAULT: reader stalled >8s, discarded \(overflow) B of live audio (total \(total) B over \(events) events)\n".utf8))
                }
            }
            let p = pendingCount
            stats.withLock { $0.peakPending = max($0.peakPending, p) }
            flush()
        }
    }

    private func compactIfNeeded() {
        if readOff == buf.count {
            buf.removeAll(keepingCapacity: true)
            readOff = 0
        } else if readOff >= 65_536 && readOff * 2 >= buf.count {
            buf.removeSubrange(0..<readOff)
            readOff = 0
        }
    }

    /// Runs on `queue`. Writes as much pending data as the pipe accepts.
    /// On EAGAIN (pipe full) it retries soon. It NEVER closes the fd on EPIPE:
    /// closing is what caused the zero-writer EOF. A transient with no reader is
    /// impossible because we hold an O_RDWR fd ourselves.
    private func flush() {
        defer {
            compactIfNeeded()
            let p = pendingCount
            stats.withLock { $0.pending = p }
        }
        guard pendingCount > 0 else { return }
        checkIdentity()
        guard ensureOpen() else { scheduleRetry(afterMs: 5); return }

        var wrote = 0
        while pendingCount > 0 {
            let want = min(pendingCount, Self.writeChunk)
            let n: Int = buf.withUnsafeBytes { raw in
                Foundation.write(fd, raw.baseAddress! + readOff, want)
            }
            if n > 0 {
                readOff += n
                wrote += n
                continue
            }
            let err = n < 0 ? errno : EAGAIN
            if err == EINTR { continue }
            if wrote > 0 {
                let now = Date().timeIntervalSince1970 * 1000
                stats.withLock { $0.writtenBytes += wrote; $0.lastWriteUnixMs = now }
                wrote = 0
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                // Pipe full (reader busy): keep the fd, retry promptly.
                stats.withLock { $0.eagainCount += 1 }
                scheduleRetry(afterMs: 1)
            } else {
                // Not backpressure (EBADF/EIO/ENXIO...): the fd is unusable.
                // Reopen with backoff. EPIPE cannot happen on an O_RDWR fd.
                closeFD()
                scheduleRetry(afterMs: 20)
            }
            return
        }
        if wrote > 0 {
            let now = Date().timeIntervalSince1970 * 1000
            stats.withLock { $0.writtenBytes += wrote; $0.lastWriteUnixMs = now }
        }
    }

    private func scheduleRetry(afterMs ms: Int) {
        guard !retryScheduled else { return }
        retryScheduled = true
        // Tight 1ms poll while the pipe is full: it drains 176400 B/s, so 1ms
        // frees ~176 bytes. Polling 1000x/s keeps `pending` flat instead of the
        // old 5ms (200x/s) poll that let a backpressure burst climb toward
        // maxPending and drop.
        queue.asyncAfter(deadline: .now() + .milliseconds(ms)) { [self] in
            retryScheduled = false
            flush()
        }
    }

    public func closePipe() {
        queue.sync {
            buf.removeAll()
            readOff = 0
            stats.withLock { $0.pending = 0 }
            closeFD()
        }
    }

    deinit { if fd >= 0 { close(fd) } }
}
