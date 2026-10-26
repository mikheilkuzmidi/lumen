import Foundation

/// Keeps concurrent photos from spending the same remaining calls.
actor BatchCalls {
    private let limit: Int?
    private(set) var count = 0
    private var started = 0
    private var reservations: [UUID: Int] = [:]
    private var attempts: [UUID: [Bool]] = [:]
    private var stopped = false

    init(limit: Int?) { self.limit = limit.map { max(0, $0) } }

    func reserve(_ estimate: Int) -> UUID? {
        guard !stopped else { return nil }
        if let limit, estimate > limit - started - reservations.values.reduce(0, +) {
            stopped = true
            return nil
        }
        let id = UUID()
        reservations[id] = estimate
        return id
    }

    func release(_ id: UUID) {
        reservations[id] = nil
        attempts[id] = nil
    }

    func begin(reservation: UUID? = nil) throws {
        try Task.checkCancellation()
        guard (reservation != nil || !stopped), limit.map({ started < $0 }) ?? true else {
            stopped = true
            if let reservation { attempts[reservation, default: []].append(false) }
            throw BatchCallLimit()
        }
        started += 1
        if let reservation { attempts[reservation, default: []].append(true) }
        else { count += 1 }
        if let reservation, let remaining = reservations[reservation] {
            reservations[reservation] = max(0, remaining - 1)
        }
    }

    /// Counts model traces and leaves refused attempts out of the call total.
    func record(_ trace: TraceEvent, reservation: UUID) -> TraceEvent {
        guard trace.model != nil else { return trace }
        var trace = trace
        if attempts[reservation]?.isEmpty == false, attempts[reservation]?.removeFirst() == true {
            count += 1
        } else {
            trace.model = nil
        }
        return trace
    }
}

struct BatchCallLimit: Error, LocalizedError {
    var errorDescription: String? { "Model call limit reached." }
}

/// Checks the call limit before a photo's planner can call a model.
struct BatchPhotoPlanner: Planner {
    let base: any Planner
    let calls: BatchCalls
    let reservation: UUID
    var modelID: String { base.modelID }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        try await calls.begin(reservation: reservation)
        return try await base.plan(request)
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        try await calls.begin(reservation: reservation)
        return try await base.critique(request)
    }
}

struct BatchPhotoSegmenter: Segmenter {
    let base: any Segmenter
    let calls: BatchCalls
    let reservation: UUID
    var modelID: String { base.modelID }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        try await calls.begin(reservation: reservation)
        return try await base.segment(request)
    }
}

struct BatchPhotoGenerator: Generator {
    let base: any Generator
    let calls: BatchCalls
    let reservation: UUID
    var modelID: String { base.modelID }

    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        try await calls.begin(reservation: reservation)
        return try await base.generate(request)
    }
}

/// Visits only a bounded number of photos or review groups at a time.
func batchForEach<Value: Sendable>(_ values: [Value], limit: Int,
                                  operation: @escaping @Sendable (Value) async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var next = 0
        for _ in 0..<min(max(1, limit), values.count) {
            try Task.checkCancellation()
            let value = values[next]
            group.addTask { try await operation(value) }
            next += 1
        }
        while try await group.next() != nil {
            try Task.checkCancellation()
            if next < values.count {
                let value = values[next]
                group.addTask { try await operation(value) }
                next += 1
            }
        }
    }
}
