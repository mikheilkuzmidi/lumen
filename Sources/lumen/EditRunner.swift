import Foundation
import LumenCore
import LumenRender

enum EditRunner {
    static func run(photo: URL, instruction: String, options: EditOptions, models: EditModels,
                    output: URL, trace: URL?, line: @Sendable (String) -> Void) async throws -> EditTrace {
        try Task.checkCancellation()
        let format = try PhotoOutput.format(for: output)
        try PhotoOutput.validate(photo: photo, output: output, trace: trace)
        let started = Date()
        var result = EditTrace(instruction: instruction, backend: options.backend, modelIDs: models.ids)
        do {
            let document = try PhotoDocument(contentsOf: photo)
            result = await run(host: document, instruction: instruction, options: options, models: models, line: line)
            if Task.isCancelled { throw LumenError.cancelled }
            try await document.export(to: output, format: format)
            result.exported = true
        } catch {
            result.failure = Task.isCancelled || error is CancellationError
                ? LumenError.cancelled.localizedDescription : error.localizedDescription
        }
        result.totalTime = max(0, Date().timeIntervalSince(started))
        if let trace { try result.write(to: trace) }
        return result
    }

    static func run(host: any EditHost, instruction: String, options: EditOptions, models: EditModels,
                    line: @Sendable (String) -> Void) async -> EditTrace {
        let started = Date()
        let agent = EditAgent(planner: models.planner, segmenter: models.segmenter, generator: models.generator,
                              host: host, configuration: options.agentConfiguration)
        var progress = EditProgress(instruction: instruction, backend: options.backend, models: models.ids,
                                    configuration: options.agentConfiguration)
        var lines = EventLines()
        do {
            try await withTaskCancellationHandler {
                for try await event in agent.run(instruction, area: options.area) {
                    try Task.checkCancellation()
                    progress.accept(event)
                    if let text = lines.accept(event) { line(text) }
                }
                try Task.checkCancellation()
            } onCancel: { Task { await agent.cancel() } }
        } catch {
            progress.trace.failure = Task.isCancelled || error is CancellationError
                ? LumenError.cancelled.localizedDescription : error.localizedDescription
        }
        progress.trace.totalTime = max(0, Date().timeIntervalSince(started))
        return progress.trace
    }
}

enum PhotoOutput {
    static func format(for url: URL) throws -> EncodedImage.Format {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "png": .png
        default: throw CLIError("Unsupported output extension. Use .jpg, .jpeg or .png.")
        }
    }

    static func validate(photo: URL, output: URL, trace: URL?) throws {
        let original = photo.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let result = output.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard original != result else { throw CLIError("The output must be a different file from the original photo.") }
        if let trace {
            let trace = trace.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            guard trace != original, trace != result else {
                throw CLIError("The trace must be a different file from the photo and the output.")
            }
        }
    }
}
