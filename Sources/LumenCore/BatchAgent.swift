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
        current = run
        runID = id
        let task = Task {
            await run.execute { await self.didFinish(id) }
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

    public func cancel() {
        task?.cancel()
        if let current { Task { await current.cancel() } }
    }

    private func didFinish(_ id: UUID) {
        guard runID == id else { return }
        current = nil
        task = nil
        runID = nil
    }
}
