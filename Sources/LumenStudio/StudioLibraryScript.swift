import Foundation
import LumenCore

/// A library edit with the choices needed for an unattended run.
struct StudioLibraryScript: Decodable, Sendable {
    struct Options: Decodable, Sendable {
        var auto = true
        var straighten = LibraryStraighten.ask
        var flagMisfires = true
        var qualityThreshold = 0.5
        var concurrency = 3
        var maxModelCalls: Int?

        private enum CodingKeys: String, CodingKey { case auto, straighten, flagMisfires, qualityThreshold, concurrency, maxModelCalls }
        init() {}
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            auto = try values.decodeIfPresent(Bool.self, forKey: .auto) ?? true
            flagMisfires = try values.decodeIfPresent(Bool.self, forKey: .flagMisfires) ?? true
            qualityThreshold = try values.decodeIfPresent(Double.self, forKey: .qualityThreshold) ?? 0.5
            concurrency = try values.decodeIfPresent(Int.self, forKey: .concurrency) ?? 3
            maxModelCalls = try values.decodeIfPresent(Int.self, forKey: .maxModelCalls)
            if let enabled = try? values.decode(Bool.self, forKey: .straighten) { straighten = enabled ? .yes : .no }
            else { straighten = try values.decodeIfPresent(LibraryStraighten.self, forKey: .straighten) ?? .ask }
        }
    }

    let folder: String
    let instruction: String?
    let mode: BatchMode
    let options: Options
    let answers: [String: String]
    let backend: StudioScript.Backend
    let output: String?
    let approve: Bool
    let window: StudioScript.Window

    private enum CodingKeys: String, CodingKey { case folder, instruction, mode, options, answers, backend, output, approve, window }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folder = try values.decode(String.self, forKey: .folder)
        instruction = try values.decodeIfPresent(String.self, forKey: .instruction)
        mode = try values.decodeIfPresent(BatchMode.self, forKey: .mode) ?? .askWhenUnsure
        options = try values.decodeIfPresent(Options.self, forKey: .options) ?? Options()
        answers = try values.decodeIfPresent([String: String].self, forKey: .answers) ?? [:]
        backend = try values.decodeIfPresent(StudioScript.Backend.self, forKey: .backend) ?? .meta
        output = try values.decodeIfPresent(String.self, forKey: .output)
        approve = try values.decodeIfPresent(Bool.self, forKey: .approve) ?? true
        window = try values.decodeIfPresent(StudioScript.Window.self, forKey: .window) ?? StudioScript.Window(width: 1440, height: 900)
    }

    static func parse(_ data: Data) throws -> Self {
        let script: Self
        do { script = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw StudioScriptError.message("Couldn't read the library script: \(error.localizedDescription)") }
        guard !script.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              script.output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
            throw StudioScriptError.message("The library script needs a folder path and a nonempty output path when supplied.")
        }
        guard script.options.qualityThreshold.isFinite, (0...1).contains(script.options.qualityThreshold),
              (1...32).contains(script.options.concurrency), script.options.maxModelCalls.map({ $0 >= 0 }) ?? true else {
            throw StudioScriptError.message("Use qualityThreshold from 0 to 1, concurrency from 1 to 32, and a nonnegative maxModelCalls.")
        }
        guard script.window.width.isFinite, script.window.height.isFinite,
              (980...8192).contains(script.window.width), (680...8192).contains(script.window.height) else {
            throw StudioScriptError.message("The window must be at least 980 × 680 and at most 8192 × 8192 points.")
        }
        return script
    }

    var batchOptions: BatchOptions {
        BatchOptions(mode: mode, instruction: instruction, auto: options.auto, straighten: options.straighten.value,
                     flagMisfires: options.flagMisfires, qualityThreshold: options.qualityThreshold,
                     concurrency: options.concurrency, maxModelCalls: options.maxModelCalls)
    }

    func folderURL(relativeTo script: URL) -> URL { resolve(folder, relativeTo: script) }
    func outputURL(relativeTo script: URL) -> URL? { output.map { resolve($0, relativeTo: script) } }
    private func resolve(_ path: String, relativeTo script: URL) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: script.deletingLastPathComponent()).standardizedFileURL
    }
}

enum LibrarySnapshot: Int, CaseIterable, Sendable {
    case opened = 1, reviewed, question, plan, editing, finished, photo
    var filename: String {
        let name: String = switch self {
        case .opened: "opened"
        case .reviewed: "reviewed"
        case .question: "question"
        case .plan: "plan"
        case .editing: "editing"
        case .finished: "finished"
        case .photo: "photo-opened"
        }
        return "\(rawValue)-\(name).png"
    }
}

/// Pauses the library's event presentation for captures and scripted answers.
@MainActor
struct StudioLibraryScriptRunner {
    let model: StudioLibraryModel
    let photoModel: StudioModel
    let script: StudioLibraryScript
    let scriptURL: URL
    let output: URL

    func run(using models: StudioModels? = nil,
             capture: @MainActor (LibrarySnapshot) async throws -> Void) async throws {
        var cancelledPlan = false
        do {
            model.backends.choose(script.backend, remembering: false)
            try await model.openFolder(script.folderURL(relativeTo: scriptURL), output: script.outputURL(relativeTo: scriptURL))
            model.instruction = script.instruction ?? ""
            model.mode = script.mode
            model.auto = script.options.auto
            model.straighten = script.options.straighten
            model.flagMisfires = script.options.flagMisfires
            model.qualityThreshold = script.options.qualityThreshold
            try await capture(.opened)
            guard model.backends.selection == script.backend else {
                throw StudioScriptError.message(model.backends.issue ?? "The requested planner couldn't be loaded.")
            }
            var captured: Set<LibrarySnapshot> = []
            var reviewed = 0
            func take(_ snapshot: LibrarySnapshot) async throws {
                if captured.insert(snapshot).inserted { try await capture(snapshot) }
            }
            try await model.runLibrary(using: models, options: script.batchOptions, allowKeychainInteraction: false) { event in
                switch event {
                case .reviewed:
                    reviewed += 1
                    if reviewed == model.total { try await take(.reviewed) }
                case .question(let question):
                    try await take(.question)
                    let answer = script.answers[question.id] ?? question.options[question.recommended]
                    guard question.options.contains(answer) else { throw StudioScriptError.message("The answer for \(question.id) must be one of its options.") }
                    await model.answer(answer)
                case .answered: try await take(.question)
                case .awaitingApproval:
                    try await take(.plan)
                    if script.approve { await model.approve() }
                    else { cancelledPlan = true; model.stop() }
                case .planned:
                    if script.mode != .planFirst { try await take(.plan) }
                case .editStarted, .autoApplied, .straightened: try await take(.editing)
                default: break
                }
            }
            guard model.summary != nil else { throw StudioScriptError.message("The library ended without a finished event.") }
            try await take(.finished)
            if let photo = model.photos.first(where: { model.states[$0]?.badges.contains(.edited) == true }) ?? model.photos.first {
                try await model.openPhoto(photo, in: photoModel)
                try await take(.photo)
            }
            try writeResults()
            await model.backends.shutdown()
        } catch {
            await model.backends.shutdown()
            try? writeResults()
            if cancelledPlan, error as? LumenError == .cancelled { return }
            throw error
        }
    }

    private func writeResults() throws {
        try model.timelineText.write(to: output.appendingPathComponent("timeline.txt"), atomically: true, encoding: .utf8)
        if let summary = model.summary {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: output.appendingPathComponent("summary.json"), options: .atomic)
        }
    }
}
