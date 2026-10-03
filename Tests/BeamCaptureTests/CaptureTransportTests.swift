import XCTest
import AVFoundation
import Synchronization
@testable import BeamCapture

final class CaptureTransportTests: XCTestCase {
    private func fixture() throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.pipe").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        return (dir, path)
    }
    func testBoundedAdmissionKeepsNewestFramesBeforeDrainRuns() throws {
        let (dir, path) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.fifo.gated")
        queue.suspend()
        let writer = FIFOWriter(path: path, capacityBytes: 4096, maximumAge: 2.5, queue: queue, now: { 1_000_000_000 })
        writer.write(Data(repeating: 1, count: 1024))
        writer.write(Data(repeating: 2, count: 8192))
        XCTAssertEqual(writer.pendingBytes, 4096)
        XCTAssertEqual(writer.peakPending, 4096)
        XCTAssertEqual(writer.droppedBytes, 5120)
        queue.resume(); writer.waitForDrainForTesting()
        let reader = open(path, O_RDONLY | O_NONBLOCK); defer { close(reader); writer.closePipe() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        XCTAssertEqual(read(reader, &bytes, bytes.count), 4096)
        XCTAssertTrue(bytes.allSatisfy { $0 == 2 })
    }
    func testExpiredAudioIsNotReplayedEvenWhenSourceHasPaused() throws {
        let (dir, path) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Mutex<UInt64>(1_000_000_000)
        let queue = DispatchQueue(label: "test.fifo.expiry")
        queue.suspend()
        let writer = FIFOWriter(path: path, capacityBytes: 4096, maximumAge: 2.5, queue: queue, now: { clock.withLock { $0 } })
        writer.write(Data(repeating: 1, count: 1024))
        clock.withLock { $0 = 4_000_000_000 }
        queue.resume(); writer.waitForDrainForTesting()
        XCTAssertEqual(writer.pendingBytes, 0)
        XCTAssertEqual(writer.writtenBytes, 0)
        XCTAssertEqual(writer.droppedBytes, 1024)
        XCTAssertTrue(writer.hasDroppedAudio)
        writer.closePipe()
    }
    func testConcurrentProducerBurstAndCloseRetainOnlyFixedStorage() {
        let queue = DispatchQueue(label: "test.fifo.burst")
        queue.suspend()
        let writer = FIFOWriter(path: "/missing/dali-test.pipe", capacityBytes: 4096,
                                maximumAge: 2.5, queue: queue, now: { 1_000_000_000 })
        let block = Data(repeating: 1, count: 4096)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in writer.write(block) }
        XCTAssertEqual(writer.pendingBytes, 4096)
        XCTAssertEqual(writer.peakPending, 4096)
        XCTAssertEqual(writer.droppedBytes, 99 * 4096)
        writer.closePipe()
        writer.write(block)
        XCTAssertTrue(writer.isClosed)
        XCTAssertEqual(writer.rejectedBytes, 4096)
        XCTAssertEqual(writer.pendingBytes, 0)
        queue.resume(); writer.waitForDrainForTesting()
        XCTAssertEqual(writer.writtenBytes, 0)
    }
    func testTapGenerationDropsOldPendingPCMAndRejectsLateWrites() throws {
        let (dir, path) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.fifo.generations")
        queue.suspend()
        let writer = FIFOWriter(path: path, capacityBytes: 4096, maximumAge: 2.5, queue: queue, now: { 1_000_000_000 })
        writer.beginGeneration(1)
        writer.write(Data(repeating: 1, count: 1024), generation: 1)
        writer.beginGeneration(2)
        writer.write(Data(repeating: 9, count: 1024), generation: 1)
        writer.write(Data(repeating: 2, count: 1024), generation: 2)
        XCTAssertEqual(writer.pendingBytes, 1024)
        XCTAssertEqual(writer.supersededBytes, 1024)
        XCTAssertEqual(writer.rejectedBytes, 1024)
        queue.resume(); writer.waitForDrainForTesting()
        let reader = open(path, O_RDONLY | O_NONBLOCK); defer { close(reader); writer.closePipe() }
        var bytes = [UInt8](repeating: 0, count: 1024)
        XCTAssertEqual(read(reader, &bytes, bytes.count), 1024)
        XCTAssertTrue(bytes.allSatisfy { $0 == 2 })
    }

    func testIncompleteStereoFrameIsRejectedWithoutMisalignment() throws {
        let (dir, path) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let writer = FIFOWriter(path: path); defer { writer.closePipe() }
        writer.write(Data([1, 2, 3, 4, 5, 6]))
        writer.waitForDrainForTesting()
        XCTAssertEqual(writer.writtenBytes, 4)
        XCTAssertEqual(writer.droppedBytes, 2)
    }
    func testConsumerCancellationDoesNotDrainOldRecordsOrWaitForHandler() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let context = TapContext(ring: AudioRing(capacity: 65536), bufferCount: 2, channelsPerBuffer: 1)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        pcm.frameLength = 512
        for channel in 0..<2 { for frame in 0..<512 { pcm.floatChannelData![channel][frame] = 0.5 } }
        context.deliver(pcm.audioBufferList)
        context.deliver(pcm.audioBufferList)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let consumer = TapConsumer(context: context, format: format) { _ in
            calls.withLock { $0 += 1 }; entered.signal(); release.wait()
        }
        consumer.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let begin = DispatchTime.now().uptimeNanoseconds
        consumer.requestStop()
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - begin, 100_000_000)
        release.signal()
        XCTAssertTrue(consumer.waitForCompletion(timeout: 1))
        XCTAssertEqual(calls.withLock { $0 }, 1, "Cancellation must be checked inside the record drain loop")
    }
    func testConsumerDiscardsOldTimestampedRecord() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let context = TapContext(ring: AudioRing(capacity: 65536), bufferCount: 2, channelsPerBuffer: 1)
        let ring = context.ring
        var frames: UInt32 = 4, ancient: UInt64 = 0
        ring.copyIn(&frames, count: 4, at: 0); ring.copyIn(&ancient, count: 8, at: 4)
        let samples = [Float](repeating: 0.5, count: 8)
        samples.withUnsafeBytes { ring.copyIn($0.baseAddress!, count: 32, at: 12) }
        ring.commit(44)
        let calls = Mutex(0)
        let consumer = TapConsumer(context: context, format: format) { _ in calls.withLock { $0 += 1 } }
        consumer.start()
        let deadline = Date().addingTimeInterval(1)
        while context.staleRecords.load(ordering: .relaxed) == 0, Date() < deadline { usleep(1000) }
        consumer.requestStop()
        XCTAssertTrue(consumer.waitForCompletion(timeout: 1))
        XCTAssertEqual(context.staleRecords.load(ordering: .relaxed), 1)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    private func scale(_ ramp: inout PCMVolumeRamp, gain: Double, frames: Int = 1000) -> [Float] {
        var samples = [Float](repeating: 0.5, count: frames * 2)
        samples.withUnsafeMutableBufferPointer { ramp.apply(to: $0, channels: 2, sampleRate: 44100, gain: gain) }
        return samples
    }
    func testVolumeUnityIsBitExactAndZeroStartsSilent() {
        var unity = PCMVolumeRamp()
        XCTAssertTrue(scale(&unity, gain: 1).allSatisfy { $0 == 0.5 })
        var muted = PCMVolumeRamp(initialGain: 0)
        XCTAssertTrue(scale(&muted, gain: 0).allSatisfy { $0 == 0 })
        var invalid = PCMVolumeRamp(initialGain: .nan)
        XCTAssertTrue(scale(&invalid, gain: .nan).allSatisfy { $0 == 0 })
    }
    func testVolumeRampHasSharedGainContinuousFramesAndExactMute() {
        var ramp = PCMVolumeRamp()
        let samples = scale(&ramp, gain: 0)
        XCTAssertGreaterThan(samples[0], 0)
        XCTAssertLessThan(samples[0], 0.5)
        for frame in 0..<1000 {
            XCTAssertEqual(samples[frame * 2], samples[frame * 2 + 1])
            if frame > 0 {
                XCTAssertLessThanOrEqual(samples[frame * 2], samples[(frame - 1) * 2])
                XCTAssertLessThanOrEqual(abs(samples[frame * 2] - samples[(frame - 1) * 2]), 0.001)
            }
        }
        XCTAssertEqual(ramp.applied, 0)
        XCTAssertTrue(samples.suffix(600).allSatisfy { $0 == 0 })
        XCTAssertTrue(scale(&ramp, gain: .infinity).allSatisfy { $0 == 0 }, "Invalid updates must retain mute")
        let rising = scale(&ramp, gain: 9)
        XCTAssertEqual(ramp.applied, 1)
        XCTAssertEqual(rising.last, 0.5)
        let falling = scale(&ramp, gain: -9)
        XCTAssertEqual(ramp.applied, 0)
        XCTAssertEqual(falling.last, 0)
    }
    func testConverterMutesBeforeDitherAndTracksSourceBeforeGain() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        pcm.frameLength = 1024
        for channel in 0..<2 { for frame in 0..<1024 { pcm.floatChannelData![channel][frame] = 0.5 } }
        let converter = try XCTUnwrap(FormatConverter(from: format, initialGain: 0))
        let data = try XCTUnwrap(converter.convert(pcm, masterGain: 0))
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
        XCTAssertFalse(converter.outputWasSilent, "User mute must not masquerade as missing source audio")
        let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true)!
        XCTAssertFalse(converter.accepts(interleaved), "Layout changes require a new converter even at the same rate")
    }

    func testConverterSignalMetricsDistinguishQuietGainMuteAndSourceSilence() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        pcm.frameLength = 1024
        func fill(_ value: Float) {
            for channel in 0..<2 { for frame in 0..<1024 { pcm.floatChannelData![channel][frame] = value } }
        }
        fill(0.5)
        let gain = 0.09219786555579713 // reported silent session's desired gain
        let quiet = try XCTUnwrap(FormatConverter(from: format, initialGain: gain))
        let data = try XCTUnwrap(quiet.convert(pcm, masterGain: gain))
        XCTAssertEqual(quiet.signalSampleCount, data.count / 2)
        XCTAssertEqual(quiet.sourceMeanSquare, 0.25, accuracy: 0.000001)
        XCTAssertEqual(quiet.outputMeanSquare, 0.25 * gain * gain, accuracy: 0.00001)
        XCTAssertGreaterThan(quiet.outputMeanSquare, 0, "Desired gain alone does not prove outgoing signal")
        let muted = try XCTUnwrap(FormatConverter(from: format, initialGain: 0))
        _ = try XCTUnwrap(muted.convert(pcm, masterGain: 0))
        XCTAssertEqual(muted.sourceMeanSquare, 0.25, accuracy: 0.000001)
        XCTAssertEqual(muted.outputMeanSquare, 0)
        XCTAssertFalse(muted.outputWasSilent)
        fill(0)
        let silent = try XCTUnwrap(FormatConverter(from: format))
        _ = try XCTUnwrap(silent.convert(pcm))
        XCTAssertEqual(silent.sourceMeanSquare, 0)
        XCTAssertEqual(silent.outputMeanSquare, 0)
        XCTAssertTrue(silent.outputWasSilent)
        fill(.nan)
        let invalid = try XCTUnwrap(FormatConverter(from: format))
        let invalidData = try XCTUnwrap(invalid.convert(pcm))
        XCTAssertTrue(invalidData.allSatisfy { $0 == 0 })
        XCTAssertEqual(invalid.sourceMeanSquare, 0)
        XCTAssertEqual(invalid.outputMeanSquare, 0)
        XCTAssertTrue(invalid.outputWasSilent, "Invalid samples cannot establish real source audio")
        pcm.frameLength = 0
        XCTAssertNil(quiet.convert(pcm))
        XCTAssertEqual(quiet.signalSampleCount, 0, "Failed conversion cannot reuse a previous signal measurement")
    }
}
