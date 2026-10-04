// Bounded live PCM transport to OwnTone. Admission copies into fixed storage on
// the producer, never into dispatched closures. One queue owns the descriptor
// and its retry chain. Closing a writer is permanent.
import Foundation
import Synchronization

public final class FIFOWriter: @unchecked Sendable {
    // OwnTone can deliberately pause input at its ~2.18s buffer ceiling. Allow
    // 320ms more scheduling slack, but never retain >2.5s of additional PCM or
    // replay audio older than 2.5s after a stopped/absent reader resumes. Drops
    // remain faults, not normal clock correction. The engine buffer is separate.
    public static let maximumPendingBytes = 441_000
    public static let maximumAudioAge: TimeInterval = 2.5
    private static let frame = 4
    // <= POSIX's minimum PIPE_BUF: writes are all-or-nothing, so frame alignment
    // survives a partial pipe fill on either macOS or Linux.
    private static let writeChunk = 512
    private let path: String
    private let queue: DispatchQueue
    private let nowNs: @Sendable () -> UInt64
    private let ageLimitNs: UInt64
    private let state: Mutex<State>

    private struct State {
        var bytes: [UInt8]
        var ages: [UInt64]
        var first = 0
        var frames = 0
        var draining = false
        var closed = false
        var droppedBytes = 0, dropEvents = 0, writtenBytes = 0, peakPending = 0, eagain = 0
        var lastDropUnixMs = 0.0, lastWriteUnixMs = 0.0
        var rejectedBytes = 0
        var generation = 0
        var supersededBytes = 0
        var capacity: Int { ages.count }
        var pending: Int { frames * FIFOWriter.frame }

        mutating func discard(_ count: Int, fault: Bool) {
            guard count > 0 else { return }
            first = (first + count) % capacity
            frames -= count
            if fault { recordDrop(count * FIFOWriter.frame) }
        }
        mutating func recordDrop(_ count: Int) {
            guard count > 0 else { return }
            droppedBytes += count; dropEvents += 1
            lastDropUnixMs = Date().timeIntervalSince1970 * 1000
        }
        mutating func expire(now: UInt64, ageLimit: UInt64) {
            var expired = 0
            while expired < frames {
                let age = ages[(first + expired) % capacity]
                guard now >= age, now - age > ageLimit else { break }
                expired += 1
            }
            discard(expired, fault: true)
        }
    }
    // Descriptor state belongs exclusively to queue. All open/write operations
    // also hold state's lock, so closePipe cannot race an open or a write.
    private var fd: Int32 = -1
    private var fdIdentity: (dev: dev_t, ino: ino_t)?
    private var nextOpenNs: UInt64 = 0, nextIdentityCheckNs: UInt64 = 0
    private var openFailures = 0

    public convenience init(path: String) {
        self.init(path: path, capacityBytes: Self.maximumPendingBytes,
                  maximumAge: Self.maximumAudioAge,
                  queue: DispatchQueue(label: "beam.fifo.write", qos: .userInitiated),
                  now: { clock_gettime_nsec_np(CLOCK_MONOTONIC) })
    }
    // Internal clock/queue injection keeps slow-reader/close tests deterministic.
    init(path: String, capacityBytes: Int, maximumAge: TimeInterval,
         queue: DispatchQueue, now: @escaping @Sendable () -> UInt64) {
        precondition(capacityBytes >= Self.frame && capacityBytes % Self.frame == 0)
        precondition(maximumAge.isFinite && maximumAge > 0 && maximumAge < 60)
        self.path = path; self.queue = queue; nowNs = now
        ageLimitNs = UInt64(maximumAge * 1_000_000_000)
        state = Mutex(State(bytes: [UInt8](repeating: 0, count: capacityBytes),
                            ages: [UInt64](repeating: 0, count: capacityBytes / Self.frame)))
        signal(SIGPIPE, SIG_IGN)
    }
    public var droppedBytes: Int { state.withLock { $0.droppedBytes } }
    public var dropEvents: Int { state.withLock { $0.dropEvents } }
    public var lastDropUnixMs: Double { state.withLock { $0.lastDropUnixMs } }
    public var hasDroppedAudio: Bool { droppedBytes > 0 }
    public var writtenBytes: Int { state.withLock { $0.writtenBytes } }
    public var peakPending: Int { state.withLock { $0.peakPending } }
    public var pendingBytes: Int { state.withLock { $0.pending } }
    public var eagainCount: Int { state.withLock { $0.eagain } }
    public var lastWriteUnixMs: Double { state.withLock { $0.lastWriteUnixMs } }
    public var isClosed: Bool { state.withLock { $0.closed } }
    public var rejectedBytes: Int { state.withLock { $0.rejectedBytes } }

    public var supersededBytes: Int { state.withLock { $0.supersededBytes } }
    // A tap replacement preserves the descriptor but drops queued PCM from its
    // old source. Kernel/OwnTone buffers already accepted before this boundary
    // are outside this writer's ownership and cannot safely be retracted.
    public func beginGeneration(_ generation: Int) {
        state.withLock { s in
            guard !s.closed, s.generation != generation else { return }
            s.generation = generation
            s.supersededBytes += s.pending
            s.frames = 0
        }
    }

    public func write(_ data: Data, generation: Int? = nil) {
        guard !data.isEmpty else { return }
        let schedule = state.withLock { s -> Bool in
            guard !s.closed, generation == nil || generation == s.generation else { s.rejectedBytes += data.count; return false }
            let now = nowNs()
            s.expire(now: now, ageLimit: ageLimitNs)
            let inputFrames = data.count / Self.frame
            let keep = min(inputFrames, s.capacity)
            let skip = inputFrames - keep
            let overflow = max(0, s.frames + keep - s.capacity)
            s.discard(overflow, fault: true)
            s.recordDrop(skip * Self.frame + data.count % Self.frame)
            data.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { return }
                let start = (s.first + s.frames) % s.capacity
                let firstCount = min(keep, s.capacity - start)
                s.bytes.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress! + start * Self.frame, src + skip * Self.frame, firstCount * Self.frame)
                    if firstCount < keep {
                        memcpy(dst.baseAddress!, src + (skip + firstCount) * Self.frame, (keep - firstCount) * Self.frame)
                    }
                }
                for i in 0..<keep { s.ages[(start + i) % s.capacity] = now }
            }
            s.frames += keep
            s.peakPending = max(s.peakPending, s.pending)
            guard s.frames > 0, !s.draining else { return false }
            s.draining = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    private func closeFD() {
        if fd >= 0 { close(fd) }
        fd = -1; fdIdentity = nil
    }
    private func ensureOpen(now: UInt64) -> Bool {
        if fd >= 0, now >= nextIdentityCheckNs {
            nextIdentityCheckNs = now + 1_000_000_000
            var st = stat()
            if stat(path, &st) != 0 || st.st_dev != fdIdentity?.dev || st.st_ino != fdIdentity?.ino {
                closeFD(); nextOpenNs = 0
            }
        }
        if fd >= 0 { return true }
        guard now >= nextOpenNs else { return false }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFIFO else { failOpen(now); return false }
        // O_RDWR holds the writer throughout tap replacement: OwnTone never
        // receives an accidental zero-writer EOF during a capture rebuild.
        let opened = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard opened >= 0 else { failOpen(now); return false }
        var actual = stat()
        guard fstat(opened, &actual) == 0, (actual.st_mode & S_IFMT) == S_IFIFO else {
            close(opened); failOpen(now); return false
        }
        _ = fcntl(opened, F_SETNOSIGPIPE, 1)
        fd = opened; fdIdentity = (actual.st_dev, actual.st_ino)
        openFailures = 0; nextIdentityCheckNs = now + 1_000_000_000
        return true
    }
    private func failOpen(_ now: UInt64) {
        openFailures += 1
        nextOpenNs = now + UInt64(min(500, 20 << min(openFailures - 1, 5))) * 1_000_000
    }

    private enum DrainStep { case done, again(Int), more }
    private func drain() {
        // Yield after bounded work even with an infinitely fast reader/producer.
        // There is always only one scheduled drain or retry, independent of the
        // number of producer writes.
        for _ in 0..<64 {
            let step = state.withLock { s -> DrainStep in
                guard !s.closed else { s.draining = false; closeFD(); return .done }
                let now = nowNs()
                s.expire(now: now, ageLimit: ageLimitNs)
                guard s.frames > 0 else { s.draining = false; return .done }
                guard ensureOpen(now: now) else { return .again(20) }
                let amount = min(s.pending, Self.writeChunk, (s.capacity - s.first) * Self.frame)
                let n = s.bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress! + s.first * Self.frame, amount) }
                if n > 0 {
                    // Atomic FIFO chunks cannot split a PCM frame.
                    guard n % Self.frame == 0 else { closeFD(); s.discard(s.frames, fault: true); return .again(20) }
                    s.discard(n / Self.frame, fault: false)
                    s.writtenBytes += n; s.lastWriteUnixMs = Date().timeIntervalSince1970 * 1000
                    return .more
                }
                if n < 0 && errno == EINTR { return .more }
                if n == 0 || errno == EAGAIN || errno == EWOULDBLOCK { s.eagain += 1; return .again(1) }
                closeFD(); failOpen(now); return .again(20)
            }
            switch step {
            case .done: return
            case .again(let ms):
                queue.asyncAfter(deadline: .now() + .milliseconds(ms)) { [self] in drain() }
                return
            case .more: continue
            }
        }
        queue.async { [self] in drain() }
    }

    public func closePipe() {
        let shouldClose = state.withLock { s -> Bool in
            guard !s.closed else { return false }
            s.closed = true; s.frames = 0
            return true
        }
        // No queue.sync, descriptor join or retry wait on the caller/UI.
        if shouldClose { queue.async { [self] in closeFD() } }
    }
    func waitForDrainForTesting() { queue.sync {} }
    deinit { if fd >= 0 { close(fd) } }
}
