import Foundation

/// Owns a room's startup transaction and its teardown barrier. UI code supplies
/// hardware operations, but cannot accidentally run a second startup or let an
/// old reply revive a stopped room.
@MainActor
public final class RoomSessionController {
    public struct Speaker: Equatable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public struct Plan: Equatable, Sendable {
        public let speakers: [Speaker]
        /// Spotify owns its pipe writer, so it must not use the capture reset.
        public let allowsCaptureReset: Bool
        public init(speakers: [Speaker], allowsCaptureReset: Bool = true) {
            self.speakers = speakers
            self.allowsCaptureReset = allowsCaptureReset
        }
        public var ids: [String] { speakers.map(\.id) }
    }

    public struct Result: Equatable, Sendable {
        public let plan: Plan
        public let missing: Set<String>
        public var readyIDs: Set<String> { Set(plan.ids).subtracting(missing) }
    }

    public enum State: Equatable, Sendable { case idle, starting, streaming, stopping, failed }
    public enum Failure: LocalizedError, Equatable, Sendable {
        case noSpeakers, notPlaying, noSpeakersReady(Set<String>)
        public var errorDescription: String? {
            switch self {
            case .noSpeakers: "Choose at least one available speaker."
            case .notPlaying: "The room did not start playing. Is any audio playing on the Mac?"
            case .noSpeakersReady: "The room's speakers did not connect."
            }
        }
    }
    public enum Event: Equatable, Sendable {
        case reset(Set<String>)
        case reassert(attempt: Int, missing: Set<String>)
        case hardRejoin(Set<String>)
    }

    /// Passed to operations with their own awaits, such as Spotify setup or tap
    /// construction. Check again before any mutation following those awaits.
    @MainActor
    public struct Context {
        private let current: @MainActor () -> Bool
        fileprivate init(current: @escaping @MainActor () -> Bool) { self.current = current }
        public func isCurrent() -> Bool { current() }
        public func check() throws { if !isCurrent() { throw CancellationError() } }
    }

    @MainActor
    public struct Dependencies {
        public var prepare: @MainActor (Context) async throws -> Plan
        public var isCurrent: @MainActor () -> Bool
        public var settle: @MainActor (Context) async throws -> Void
        public var setOutputs: @MainActor ([String]) async throws -> Void
        public var setSelected: @MainActor (String, Bool) async throws -> Void
        public var outputs: @MainActor () async throws -> [Output]
        public var silenceOutputs: @MainActor ([String]) async throws -> Void
        public var startCapture: @MainActor (Context) async throws -> Void
        public var stopCapture: @MainActor () -> Void
        public var stopPlayback: @MainActor () async throws -> Void
        public var setResumePlayback: @MainActor (Bool) async -> Void
        public var isPlaying: @MainActor () async throws -> Bool
        public var rescan: @MainActor () async throws -> Void
        public var pipeTrackURI: @MainActor () async throws -> String?
        public var playPipe: @MainActor (String) async throws -> Void
        public var didTearDown: @MainActor () -> Void
        public var event: @MainActor (Event) -> Void

        public init(
            prepare: @escaping @MainActor (Context) async throws -> Plan,
            isCurrent: @escaping @MainActor () -> Bool = { true },
            settle: @escaping @MainActor (Context) async throws -> Void,
            setOutputs: @escaping @MainActor ([String]) async throws -> Void,
            setSelected: @escaping @MainActor (String, Bool) async throws -> Void,
            outputs: @escaping @MainActor () async throws -> [Output],
            silenceOutputs: @escaping @MainActor ([String]) async throws -> Void,
            startCapture: @escaping @MainActor (Context) async throws -> Void,
            stopCapture: @escaping @MainActor () -> Void,
            stopPlayback: @escaping @MainActor () async throws -> Void,
            setResumePlayback: @escaping @MainActor (Bool) async -> Void,
            isPlaying: @escaping @MainActor () async throws -> Bool,
            rescan: @escaping @MainActor () async throws -> Void,
            pipeTrackURI: @escaping @MainActor () async throws -> String?,
            playPipe: @escaping @MainActor (String) async throws -> Void,
            didTearDown: @escaping @MainActor () -> Void = {},
            event: @escaping @MainActor (Event) -> Void = { _ in }
        ) {
            self.prepare = prepare; self.isCurrent = isCurrent; self.settle = settle
            self.setOutputs = setOutputs; self.setSelected = setSelected; self.outputs = outputs
            self.silenceOutputs = silenceOutputs; self.startCapture = startCapture
            self.stopCapture = stopCapture; self.stopPlayback = stopPlayback
            self.setResumePlayback = setResumePlayback; self.isPlaying = isPlaying
            self.rescan = rescan; self.pipeTrackURI = pipeTrackURI; self.playPipe = playPipe
            self.didTearDown = didTearDown; self.event = event
        }
    }

    public struct Timing: Sendable {
        public var readinessPoll: TimeInterval = 0.25
        public var initialReadiness: TimeInterval = 6
        public var explicitFailureGrace: TimeInterval = 1.5
        public var resetReadiness: TimeInterval = 8
        public var firstReassertReadiness: TimeInterval = 8
        public var secondReassertReadiness: TimeInterval = 10
        public var reassertBackoff: TimeInterval = 2
        public var hardRejoinBackoff: TimeInterval = 1.5
        public var hardRejoinReadiness: TimeInterval = 10
        public var playbackPoll: TimeInterval = 0.5
        public init() {}
    }

    public private(set) var state: State = .idle
    private var generation = 0
    private var startupTask: Task<Result?, any Error>?
    private var cleanupTask: Task<Void, Never>?
    private var activeDependencies: Dependencies?
    private var activeResult: Result?
    private let timing: Timing
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    public init(timing: Timing = Timing(),
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        self.timing = timing; self.now = now; self.sleep = sleep
    }

    /// Concurrent callers share the same startup and completion. A start after
    /// stop waits for the old request to drain and cleanup to finish first.
    /// nil means the transaction was superseded and must not change UI state.
    public func start(using dependencies: Dependencies) async throws -> Result? {
        if state == .streaming { return activeResult }
        // A facade task can be scheduled before Stop and reach this method
        // after the replacement request. It must neither claim the lane nor
        // join a current startup using its obsolete admission context.
        guard !Task.isCancelled, dependencies.isCurrent() else { return nil }
        if state == .starting, let task = startupTask { return try await task.value }
        generation += 1
        let epoch = generation
        let previousCleanup = cleanupTask
        state = .starting
        activeDependencies = dependencies
        activeResult = nil
        let context = Context { [weak self] in
            guard let self else { return false }
            return self.generation == epoch && self.state == .starting &&
                !Task.isCancelled && dependencies.isCurrent()
        }
        let task = Task { [weak self] () throws -> Result? in
            guard let self else { return nil }
            await previousCleanup?.value
            do {
                try context.check()
                let result = try await self.run(dependencies, context: context)
                try context.check()
                self.activeResult = result
                self.state = .streaming
                return result
            } catch {
                // Stop owns teardown after it invalidates this generation.
                guard self.generation == epoch else { return nil }
                dependencies.stopCapture()
                dependencies.didTearDown()
                try? await dependencies.stopPlayback()
                // A replacement start cannot run until this task is drained.
                guard self.generation == epoch else { return nil }
                await dependencies.setResumePlayback(false)
                guard self.generation == epoch else { return nil }
                self.activeDependencies = nil
                if error is CancellationError || !dependencies.isCurrent() {
                    self.state = .idle
                    return nil
                }
                self.state = .failed
                throw error
            }
        }
        startupTask = task
        do {
            let result = try await task.value
            if generation == epoch { startupTask = nil }
            return result
        } catch {
            if generation == epoch { startupTask = nil }
            throw error
        }
    }

    /// Invalidation and capture stop happen synchronously. Network teardown is
    /// independent of caller cancellation and drains a late startup reply first.
    @discardableResult
    public func invalidateAndStop() -> Task<Void, Never> {
        if state == .stopping, let task = cleanupTask { return task }
        generation += 1
        let epoch = generation
        let oldStart = startupTask
        let priorCleanup = cleanupTask
        let dependencies = activeDependencies
        startupTask = nil; activeResult = nil; activeDependencies = nil
        state = .stopping
        oldStart?.cancel()
        dependencies?.stopCapture()
        dependencies?.didTearDown()
        let task = Task { [weak self] in
            await priorCleanup?.value
            _ = await oldStart?.result
            // A tap creation that was already in flight also has to be closed.
            dependencies?.stopCapture()
            try? await dependencies?.stopPlayback()
            await dependencies?.setResumePlayback(false)
            if let self, self.generation == epoch {
                self.state = .idle
                self.cleanupTask = nil
            }
        }
        cleanupTask = task
        return task
    }

    private func run(_ dependencies: Dependencies, context: Context) async throws -> Result {
        let plan = try await dependencies.prepare(context)
        try context.check()
        guard !plan.ids.isEmpty else { throw Failure.noSpeakers }
        try await dependencies.settle(context)
        try context.check()
        // Selecting before stopping can tear down the newly selected AP2 group.
        try? await dependencies.stopPlayback()
        try context.check()
        try await dependencies.setOutputs(plan.ids)
        try context.check()
        try await dependencies.silenceOutputs(plan.ids)
        try context.check()
        try await dependencies.startCapture(context)
        try context.check()
        await dependencies.setResumePlayback(true)
        try context.check()
        try await ensurePlaying(dependencies, context: context)
        let missing = try await activate(plan, dependencies: dependencies, context: context)
        try context.check()
        guard missing.count < Set(plan.ids).count else { throw Failure.noSpeakersReady(missing) }
        // Connected receivers can outlive a stopped pipe player. Confirm the
        // playback half of readiness again after all group recovery operations.
        try await ensurePlaying(dependencies, context: context)
        try context.check()
        return Result(plan: plan, missing: missing)
    }

    private func ensurePlaying(_ dependencies: Dependencies, context: Context) async throws {
        if try await waitForPlayback(dependencies, context: context, attempts: 8) { return }
        try? await dependencies.rescan()
        try context.check()
        var uri: String?
        for _ in 0..<6 {
            try context.check()
            uri = try? await dependencies.pipeTrackURI()
            try context.check()
            if uri != nil { break }
            try await sleep(timing.playbackPoll)
            try context.check()
        }
        if let uri {
            // Pipe autostart may win this race, making manual play return 500.
            try? await dependencies.playPipe(uri)
            try context.check()
        }
        guard try await waitForPlayback(dependencies, context: context, attempts: 6) else {
            throw Failure.notPlaying
        }
    }

    private func waitForPlayback(_ dependencies: Dependencies, context: Context,
                                 attempts: Int) async throws -> Bool {
        for _ in 0..<attempts {
            try context.check()
            let playing = (try? await dependencies.isPlaying()) ?? false
            try context.check()
            if playing { return true }
            try await sleep(timing.playbackPoll)
            try context.check()
        }
        return false
    }

    private func activate(_ plan: Plan, dependencies: Dependencies,
                          context: Context) async throws -> Set<String> {
        let all = Set(plan.ids)
        var missing = try await missingOutputs(all, timeout: timing.initialReadiness,
                                              failFast: true, dependencies: dependencies, context: context)
        var recovery = RoomStartupRecovery()
        if plan.allowsCaptureReset {
            let outputs = try? await dependencies.outputs()
            try context.check()
            if let outputs, recovery.claimReset(ids: all, missing: missing, outputs: outputs) {
                dependencies.event(.reset(missing))
                dependencies.stopCapture()
                try context.check()
                try await dependencies.stopPlayback()
                try context.check()
                dependencies.didTearDown()
                try await dependencies.settle(context)
                try context.check()
                try await dependencies.setOutputs(plan.ids)
                try context.check()
                try await dependencies.startCapture(context)
                try context.check()
                // The reset stopped the pipe player too. AP2 connected-only
                // state is not evidence that pipe autostart resumed playback.
                try await ensurePlaying(dependencies, context: context)
                missing = try await missingOutputs(all, timeout: timing.resetReadiness,
                                                  dependencies: dependencies, context: context)
            }
        }
        for (index, timeout) in [timing.firstReassertReadiness, timing.secondReassertReadiness].enumerated() {
            guard !missing.isEmpty else { break }
            dependencies.event(.reassert(attempt: index + 1, missing: missing))
            if index > 0 {
                try await sleep(timing.reassertBackoff)
                try context.check()
            }
            try? await dependencies.setOutputs(plan.ids)
            try context.check()
            // Group selection can disconnect its formerly ready partner.
            missing = try await missingOutputs(all, timeout: timeout,
                                              dependencies: dependencies, context: context)
        }
        if !missing.isEmpty {
            dependencies.event(.hardRejoin(missing))
            for speaker in plan.speakers where missing.contains(speaker.id) {
                try context.check()
                try? await dependencies.setSelected(speaker.id, false)
                try context.check()
            }
            try await sleep(timing.hardRejoinBackoff)
            try context.check()
            try? await dependencies.setOutputs(plan.ids)
            try context.check()
            missing = try await missingOutputs(all, timeout: timing.hardRejoinReadiness,
                                              dependencies: dependencies, context: context)
        }
        return missing
    }

    private func missingOutputs(_ ids: Set<String>, timeout: TimeInterval, failFast: Bool = false,
                                dependencies: Dependencies, context: Context) async throws -> Set<String> {
        let began = now()
        let deadline = began + max(0, timeout)
        var missing = ids
        while now() < deadline {
            try context.check()
            let outputs = try? await dependencies.outputs()
            try context.check()
            // HTTP time consumes the budget. A reply arriving after the deadline
            // cannot establish readiness, even if every output now says ready.
            guard now() < deadline else { break }
            if let outputs {
                missing = ids.subtracting(outputs.filter(\.isSessionReady).map(\.id))
                if missing.isEmpty { return [] }
                if failFast, now() - began >= timing.explicitFailureGrace {
                    var proof = RoomStartupRecovery()
                    if proof.claimReset(ids: ids, missing: missing, outputs: outputs) { return missing }
                }
            }
            try await sleep(min(max(0.01, timing.readinessPoll), max(0, deadline - now())))
            try context.check()
        }
        return missing
    }
}
