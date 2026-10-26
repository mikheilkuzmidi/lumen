import Foundation

/// Edits a whole library: looks at every photo, flags misfires, applies auto and straightening, gives low-scoring
/// photos a closer look, and plans an instruction across the library, asking the person what is theirs to decide.
/// Each photo's edit runs through its own `EditAgent`.
public actor BatchAgent {
    private let host: any LibraryHost
    private let reviewer: (any BatchPlanner)?
    private let planner: any Planner
    private let segmenter: any Segmenter
    private let generator: any Generator
    private let configuration: AgentConfiguration

    /// Without a reviewer the agent works from measurements alone and cannot plan an instruction.
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
        AsyncThrowingStream { $0.finish(throwing: LumenError.notBuilt("Batch editing")) }
    }

    /// Answers a question the agent asked; `answer` is one of its options' text.
    public func answer(_ question: String, with answer: String) {}

    /// Lets a plan-first run go ahead.
    public func approve() {}

    public func cancel() {}
}
