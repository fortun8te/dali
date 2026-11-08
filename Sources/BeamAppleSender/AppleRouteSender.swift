import AVFoundation
import CoreMedia
import Foundation

/// Opt-in sender that plays DALI's captured audio through Apple's own AirPlay
/// group (an `AVSampleBufferAudioRenderer` attached to a selected output context).
///
/// Fails closed: `start` throws, and nothing is rendered, unless the private routing
/// API is present, the named context resolves, and that context holds at least one
/// speaker. A missing route never falls back to the default Mac output.
///
/// Timing is Apple's. This type does not use the OwnTone FIFO or drift correction,
/// and the 700 ms OwnTone delay estimate must not be reused for it.
public final class AppleRouteSender: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case unsupported([AppleRouteAPI.Requirement])
        case contextUnavailable(String)
        case noSpeakersInContext(String)
        case notStarted
    }

    public struct Stats: Equatable, Sendable {
        public var enqueued = 0
        public var droppedNotReady = 0
        public var droppedBadBuffer = 0
        public var rendererFailures = 0
        /// Times the timeline started over after the Mac had been quiet.
        public var restarts = 0
    }

    private let lock = NSLock()
    private var renderer: AVSampleBufferAudioRenderer?
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var bridge = PCMBridge()
    private var started = false
    private var lastEnqueue: UInt64 = 0
    private var stats = Stats()

    public init() {}

    public var snapshot: Stats { lock.withLock { stats } }
    public var isStarted: Bool { lock.withLock { started } }

    /// Attach a fresh renderer to the output context with `contextID`.
    public func start(contextID: String) throws {
        let missing = AppleRouteAPI.missing()
        guard missing.isEmpty else { throw Failure.unsupported(missing) }
        guard let contextClass = NSClassFromString("AVOutputContext") as? NSObject.Type,
              let context = contextClass.perform(NSSelectorFromString("outputContextForID:"),
                                                 with: contextID)?.takeUnretainedValue() as? NSObject
        else { throw Failure.contextUnavailable(contextID) }
        let devices = AppleRouteAPI.property(context, "outputDevices") as? [Any] ?? []
        guard !devices.isEmpty else { throw Failure.noSpeakersInContext(contextID) }

        let renderer = AVSampleBufferAudioRenderer()
        _ = renderer.perform(NSSelectorFromString("setOutputContext:"), with: context)
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        lock.withLock {
            self.renderer = renderer
            self.synchronizer = synchronizer
            bridge = PCMBridge()
            stats = Stats()
            started = true
        }
    }

    /// Called from the tap's non-realtime drain thread. Never blocks on the renderer.
    public func enqueue(_ pcm: AVAudioPCMBuffer) throws {
        try lock.withLock {
            guard started, let renderer, let synchronizer else { throw Failure.notStarted }
            if renderer.status == .failed {
                stats.rendererFailures += 1
                return
            }
            guard renderer.isReadyForMoreMediaData else {
                stats.droppedNotReady += 1
                return
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if stats.enqueued > 0,
               TimelinePolicy.needsRestart(gapSeconds: Double(now &- lastEnqueue) / 1_000_000_000) {
                // The Mac was quiet and the renderer's clock kept going: start a new timeline.
                renderer.flush()
                bridge = PCMBridge()
                stats.restarts += 1
                stats.enqueued = 0
            }
            let packet: CMSampleBuffer
            do { packet = try bridge.packet(pcm) } catch {
                stats.droppedBadBuffer += 1
                throw error
            }
            if stats.enqueued == 0 {
                synchronizer.setRate(1, time: CMSampleBufferGetPresentationTimeStamp(packet))
            }
            renderer.enqueue(packet)
            stats.enqueued += 1
            lastEnqueue = now
        }
    }

    /// One line about the renderer, for the log: its state, clock rate and position.
    public var diagnostics: String {
        lock.withLock {
            guard let renderer, let synchronizer else { return "not started" }
            return "renderer=\(renderer.status.rawValue) ready=\(renderer.isReadyForMoreMediaData) " +
                "rate=\(synchronizer.rate) clock=\(String(format: "%.2f", synchronizer.currentTime().seconds))s " +
                "volume=\(renderer.volume) muted=\(renderer.isMuted)"
        }
    }

    /// Stop rendering and drop the route. The next `start` begins a new timeline.
    public func stop() {
        lock.withLock {
            synchronizer?.setRate(0, time: .invalid)
            renderer?.flush()
            renderer = nil
            synchronizer = nil
            started = false
        }
    }
}
