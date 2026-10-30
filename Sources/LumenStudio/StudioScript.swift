import Foundation
import LumenCore

/// A photo edit and window size to run without interaction.
struct StudioScript: Decodable, Sendable {
    enum Backend: String, Decodable, CaseIterable, Sendable {
        case meta, glimmer
        case sparkOpen = "spark-open"
    }

    struct Window: Decodable, Equatable, Sendable {
        let width: Double
        let height: Double
    }

    let photo: String
    let area: NormalizedRect?
    let instruction: String
    let backend: Backend
    let window: Window

    static func parse(_ data: Data) throws -> StudioScript {
        let script: StudioScript
        do { script = try JSONDecoder().decode(StudioScript.self, from: data) }
        catch { throw StudioScriptError.message("Couldn't read the Studio script: \(error.localizedDescription)") }
        guard !script.photo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioScriptError.message("The script needs a photo path.")
        }
        guard !script.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioScriptError.message("The script needs an instruction.")
        }
        guard script.window.width.isFinite, script.window.height.isFinite,
              (980...8192).contains(script.window.width), (680...8192).contains(script.window.height) else {
            throw StudioScriptError.message("The window must be at least 980 × 680 and at most 8192 × 8192 points.")
        }
        if let area = script.area {
            guard [area.x, area.y, area.width, area.height].allSatisfy(\.isFinite),
                  area.x >= 0, area.y >= 0, area.width > 0, area.height > 0,
                  area.x + area.width <= 1, area.y + area.height <= 1 else {
                throw StudioScriptError.message("The area must be a positive rectangle inside the photo, in coordinates from 0 to 1.")
            }
        }
        return script
    }

    func photoURL(relativeTo scriptURL: URL) -> URL {
        URL(fileURLWithPath: (photo as NSString).expandingTildeInPath,
            relativeTo: scriptURL.deletingLastPathComponent()).standardizedFileURL
    }
}

struct StudioScriptArguments: Equatable {
    enum Kind: Equatable { case photo, library }
    let script: URL
    let output: URL
    let kind: Kind

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard ["--script", "--library-script", "--out"].contains(flag), values[flag] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw StudioScriptError.message(Self.usage)
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard (values["--script"] == nil) != (values["--library-script"] == nil),
              let script = values["--script"] ?? values["--library-script"], !script.isEmpty,
              let output = values["--out"], !output.isEmpty else {
            throw StudioScriptError.message(Self.usage)
        }
        self.script = URL(fileURLWithPath: (script as NSString).expandingTildeInPath).standardizedFileURL
        self.output = URL(fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        kind = values["--library-script"] == nil ? .photo : .library
    }

    static let usage = "Usage: LumenStudio (--script <file.json> | --library-script <library.json>) --out <folder>"

    /// Finds the error destination even when another argument is invalid.
    static func errorOutput(in arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count,
              !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--") else { return nil }
        return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }
}

enum StudioScriptError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

/// Stable filenames for the first occurrence of each edit milestone.
enum StudioSnapshot: Int, CaseIterable, Sendable {
    case opened = 1, area, planned, selected, redrawn, finished, compare, layers, failed

    var filename: String {
        let name: String = switch self {
        case .opened: "opened"
        case .area: "area"
        case .planned: "planned"
        case .selected: "selected"
        case .redrawn: "redrawn"
        case .finished: "finished"
        case .compare: "compare"
        case .layers: "layers"
        case .failed: "failed"
        }
        return "\(rawValue)-\(name).png"
    }
}

struct StudioSnapshots {
    private var captured: Set<StudioSnapshot> = []

    mutating func take(for event: AgentEvent) -> StudioSnapshot? {
        let snapshot: StudioSnapshot
        switch event {
        case .planned: snapshot = .planned
        case .selected: snapshot = .selected
        case .applied(let layer):
            guard case .patch = layer.content else { return nil }
            snapshot = .redrawn
        case .finished: snapshot = .finished
        default: return nil
        }
        return captured.insert(snapshot).inserted ? snapshot : nil
    }
}

/// Drives the window's model and pauses event delivery while each milestone is captured.
@MainActor
struct StudioScriptRunner {
    let model: StudioModel
    let script: StudioScript
    let scriptURL: URL
    let output: URL

    func run(using models: StudioModels? = nil,
             capture: @MainActor (StudioSnapshot) async throws -> Void) async throws {
        do {
            model.backends.choose(script.backend, remembering: false)
            try await model.openPhoto(script.photoURL(relativeTo: scriptURL))
            model.prompt = script.instruction
            try await capture(.opened)
            model.area = script.area
            if script.area != nil { try await capture(.area) }
            var snapshots = StudioSnapshots()
            var finished = false
            if model.backends.selection != script.backend {
                throw StudioScriptError.message(model.backends.issue ?? "The requested planner couldn't be loaded.")
            }
            try await model.runEdit(using: models, allowKeychainInteraction: false) { event in
                if case .trace(let trace) = event, trace.kind == .failure {
                    throw StudioScriptError.message(trace.detail)
                }
                if let snapshot = snapshots.take(for: event) {
                    if snapshot == .finished { finished = true }
                    else { try await capture(snapshot) }
                }
            }
            if let issue = model.issue { throw StudioScriptError.message(issue) }
            guard finished else { throw StudioScriptError.message("The edit ended without a finished event.") }
            try await capture(.finished)
            model.compare = true
            try await capture(.compare)
            model.compare = false
            model.sidebar = .layers
            try await capture(.layers)
            try writeTimeline()
            try await model.exportPhoto(to: output.appendingPathComponent("result.jpg"))
            await model.backends.shutdown()
        } catch {
            await model.backends.shutdown()
            model.issue = error.localizedDescription
            try? writeTimeline()
            // The window as it shows the failure, which the script stopped at.
            try? await capture(.failed)
            throw error
        }
    }

    private func writeTimeline() throws {
        try model.timelineText.write(to: output.appendingPathComponent("timeline.txt"), atomically: true, encoding: .utf8)
    }
}
