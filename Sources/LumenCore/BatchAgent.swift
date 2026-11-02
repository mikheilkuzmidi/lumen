import Foundation

/// Edits a whole library, with a base pass, a closer look and an instruction planned across its photos.
/// Each photo's edit runs through its own `EditAgent`.
public actor BatchAgent {
    private let host: any LibraryHost
    private let reviewer: (any BatchPlanner)?
    private let planner: any Planner
    private let segmenter: any Segmenter
    private let generator: any Generator
    private let configuration: AgentConfiguration
    private var current: BatchRun?
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var earlyAnswers: [String: String] = [:]
    private var earlyApproval = false
    private var cancellationRequested = false
    private var lastSnapshot: BatchSnapshot?

    /// Without a reviewer, quality is the mean of sharpness, exposure balance (1 − |2 × exposure − 1|),
    /// and unclipped coverage (1 − clipped shadows − clipped highlights), each clamped to 0...1.
    public init(host: any LibraryHost, reviewer: (any BatchPlanner)?, planner: any Planner, segmenter: any Segmenter,
                generator: any Generator, configuration: AgentConfiguration = AgentConfiguration()) {
        self.host = host
        self.reviewer = reviewer
        self.planner = planner
        self.segmenter = segmenter
        self.generator = generator
        self.configuration = configuration
    }

    public func run(_ options: BatchOptions) -> AsyncThrowingStream<BatchEvent, Error> {
        guard current == nil else {
            return AsyncThrowingStream { $0.finish(throwing: LumenError.invalidResponse("A batch is already running.")) }
        }
        let (stream, events) = AsyncThrowingStream<BatchEvent, Error>.makeStream()
        let id = UUID()
        let run = BatchRun(host: host, reviewer: reviewer, planner: planner, segmenter: segmenter, generator: generator,
                           configuration: configuration, options: options, events: events,
                           answers: earlyAnswers, approved: earlyApproval)
        earlyAnswers.removeAll()
        earlyApproval = false
        cancellationRequested = false
        lastSnapshot = nil
        current = run
        runID = id
        let task = Task {
            await run.execute { snapshot in await self.didFinish(id, snapshot: snapshot) }
        }
        self.task = task
        events.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                task.cancel()
                Task { await run.cancel() }
            }
        }
        return stream
    }

    /// Answers a question the agent asked; `answer` is one of its options' text.
    public func answer(_ question: String, with answer: String) {
        if let current {
            Task { await current.answer(question, with: answer) }
        } else {
            earlyAnswers[question] = answer
        }
    }

    /// Lets a plan-first run go ahead.
    public func approve() {
        if let current {
            Task { await current.approve() }
        } else {
            earlyApproval = true
        }
    }

    /// Validates the edited draft and recalculates its estimates without approving or changing any photo.
    public func previewApproval(_ approval: BatchApproval) async throws -> BatchPlan {
        guard !cancellationRequested else { throw LumenError.cancelled }
        guard let current else { throw BatchApprovalError.noPendingPlan }
        return try await current.previewApproval(approval)
    }

    /// Approves exactly one pending draft. The host must cancel and replan if its source photos changed.
    @discardableResult
    public func approve(_ approval: BatchApproval) async throws -> BatchPlan {
        guard !cancellationRequested else { throw LumenError.cancelled }
        guard let current else { throw BatchApprovalError.noPendingPlan }
        return try await current.approve(approval)
    }

    public func cancel() {
        cancellationRequested = true
        task?.cancel()
        if let current { Task { await current.cancel() } }
    }

    /// Current progress, or the final retained progress after a successful, failed or cancelled run.
    public func snapshot() async -> BatchSnapshot? {
        if let current { return await current.snapshot(cancelled: cancellationRequested) }
        return lastSnapshot
    }

    /// Stops the run and waits for its model and host operations to unwind before returning its final progress.
    public func cancelAndWait() async -> BatchSnapshot? {
        if let current, let task {
            cancel()
            await task.value
            // A different run may have started while this caller was waiting. Return the run we stopped.
            return await current.snapshot()
        }
        return lastSnapshot
    }

    private func didFinish(_ id: UUID, snapshot: BatchSnapshot) {
        guard runID == id else { return }
        lastSnapshot = snapshot
        current = nil
        task = nil
        runID = nil
    }
}
