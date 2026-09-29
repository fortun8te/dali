// Lock-free single-producer / single-consumer byte ring: the hand-off between
// the Core Audio IO thread and everything else.
//
// The IOProc must never block, allocate, take a lock or message an ObjC object,
// so it does exactly one thing: memcpy the tap's samples in here and return. A
// dedicated (non-realtime) thread drains it, converts, resamples and writes the
// FIFO. Nothing on this path can stall the HAL, so a stalled FIFO reader can no
// longer back up into the audio callback and drop buffers inside the driver.
//
// Correctness rests on three rules:
//   * `head` (total bytes ever written) is stored ONLY by the producer,
//     `tail` (total bytes ever consumed) ONLY by the consumer.
//   * The producer publishes head with RELEASE after the bytes are copied; the
//     consumer loads head with ACQUIRE before reading them (and symmetrically
//     for tail), so payload reads can never overtake the index that guards them.
//   * Indices are monotonically increasing 64-bit counters; the slot is
//     `index & mask` (capacity is a power of two), and `head &- tail` is the
//     fill level. There is no separate "empty vs full" ambiguity and wraparound
//     of the counters themselves is harmless (wrapping arithmetic).
//
// When the ring is full the PRODUCER drops the new record (it may not touch
// `tail`); the caller counts it. Records are published whole, so the consumer
// never sees a torn record.

import Foundation
import Synchronization

final class AudioRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutableRawPointer
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    /// `capacity` is rounded up to the next power of two.
    init(capacity requested: Int) {
        var c = 1 << 12
        while c < requested { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = UnsafeMutableRawPointer.allocate(byteCount: c, alignment: 64)
        memset(storage, 0, c)
    }

    deinit { storage.deallocate() }

    // MARK: producer (IO thread)

    /// Bytes the producer may still write. Realtime-safe.
    @inline(__always)
    func freeBytes() -> Int {
        capacity - (head.load(ordering: .relaxed) &- tail.load(ordering: .acquiring))
    }

    /// Copy `count` bytes to `offset` bytes past the (unpublished) head, wrapping.
    /// The caller must have checked freeBytes() covers offset + count.
    @inline(__always)
    func copyIn(_ src: UnsafeRawPointer, count: Int, at offset: Int) {
        guard count > 0 else { return }
        let start = (head.load(ordering: .relaxed) &+ offset) & mask
        let first = min(count, capacity - start)
        memcpy(storage + start, src, first)
        if first < count { memcpy(storage, src + first, count - first) }
    }

    /// Publish `n` bytes previously placed with copyIn.
    @inline(__always)
    func commit(_ n: Int) {
        head.store(head.load(ordering: .relaxed) &+ n, ordering: .releasing)
    }

    // MARK: consumer

    @inline(__always)
    func readableBytes() -> Int {
        head.load(ordering: .acquiring) &- tail.load(ordering: .relaxed)
    }

    /// Copy `count` bytes starting `offset` bytes past the tail, wrapping.
    @inline(__always)
    func copyOut(_ dst: UnsafeMutableRawPointer, count: Int, at offset: Int) {
        guard count > 0 else { return }
        let start = (tail.load(ordering: .relaxed) &+ offset) & mask
        let first = min(count, capacity - start)
        memcpy(dst, storage + start, first)
        if first < count { memcpy(dst + first, storage, count - first) }
    }

    /// Consume `n` bytes.
    @inline(__always)
    func release(_ n: Int) {
        tail.store(tail.load(ordering: .relaxed) &+ n, ordering: .releasing)
    }
}
