import Foundation
import LumenCore

/// How to reach the Meta Model API, and which models answer.
public struct MetaConfiguration: Sendable {
    public var apiKey: String
    public var baseURL: URL
    public var planningModel: String
    public var segmentationModel: String
    public var imageModel: String
    public var timeout: TimeInterval

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.meta.ai/v1")!, planningModel: String = "muse-spark-1.3",
                segmentationModel: String = "sam-3.1", imageModel: String = "muse-image-1.0", timeout: TimeInterval = 180) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.planningModel = planningModel
        self.segmentationModel = segmentationModel
        self.imageModel = imageModel
        self.timeout = timeout
    }

    /// The user's own key, from META_API_KEY. Lumen Studio keeps it in the Keychain instead.
    public static func fromEnvironment() throws -> MetaConfiguration {
        guard let key = ProcessInfo.processInfo.environment["META_API_KEY"], !key.isEmpty else { throw LumenError.missingKey }
        return MetaConfiguration(apiKey: key)
    }
}

/// Muse Spark plans an instruction into steps and judges the result.
public struct MetaPlanner: Planner {
    public let configuration: MetaConfiguration
    public let transport: any MetaTransport
    public var modelID: String { configuration.planningModel }

    public init(configuration: MetaConfiguration, transport: any MetaTransport = URLSessionMetaTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func plan(_ request: PlanRequest) async throws -> EditPlan {
        do {
            let context = PlanContext(instruction: request.instruction, area: request.area, regions: request.regions,
                                      done: request.done, layers: request.layers, history: request.history)
            return try await answer(EditPlan.self, prompt: Self.planPrompt,
                                    content: [.text(try context.text()), .image(request.image)],
                                    name: "edit_plan", schema: EditPlan.jsonSchema())
        } catch { throw MetaHTTP.error(error) }
    }

    public func critique(_ request: CritiqueRequest) async throws -> Critique {
        do {
            let context = PlanContext(instruction: request.instruction, area: nil, regions: request.regions,
                                      done: request.done, layers: request.layers)
            return try await answer(Critique.self, prompt: Self.critiquePrompt,
                                    content: [.text(try context.text()), .text("Before"), .image(request.before),
                                              .text("After"), .image(request.after)],
                                    name: "critique", schema: Critique.jsonSchema())
        } catch { throw MetaHTTP.error(error) }
    }

    private func answer<Answer: Decodable>(_ type: Answer.Type, prompt: String, content: [ChatContentPart],
                                           name: String, schema: Data) async throws -> Answer {
        let builder = ChatCompletionRequestBuilder(baseURL: configuration.baseURL, apiKey: configuration.apiKey,
                                                   model: modelID, timeout: configuration.timeout)
        let request = try builder.request(systemPrompt: prompt, content: content, schemaName: name, schema: schema)
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        try MetaHTTP.validate(response, data: data)
        return try ChatCompletionRequestBuilder.decode(type, from: data)
    }

    static let editingRules = """
    Lumen is a careful photo editor. Keep edits natural and conservative unless the user asks otherwise.
    For tonal or colour changes to one part, use its known region or select it, then adjust that region.
    Use regenerate only to change what something is or looks like, including a coat's colour or material
    or an object's appearance.
    Use remove to take something out. When a user area is given, stay inside it and put that boundary in
    the select box. Coordinates are normalised from the top-left. Region ids are short lowercase words.
    Earlier instructions are in history, oldest first; the current instruction is a follow-up to that edit.
    The regions list contains selections you can reuse by id without selecting again. Select a new region
    only when the instruction is about something not selected before. Consider the steps already done.
    The layers list is in application order, oldest first, with each layer's id, label, kind and region.
    For "less" or "more" of a change, apply a smaller adjustment to the same region in the needed direction.
    For example, after darkening the sky, "a bit less" means a small positive exposure adjustment on sky.
    For "undo that" or "go back", revert the matching latest layer using its exact layer id.
    Revert takes off an applied layer; remove takes an object out of the photo.
    Finish when the instruction is met.
    A select concept is what the segmentation model searches for: one short singular noun phrase it can
    see, such as "jacket", "sky", "sofa" or "red gate", without possessives or long descriptions; use a
    box to say which one when there are several.
    Adjustment values: exposure in stops, usually between -1 and 1; the others in percent, usually 10 to 40
    either way for a visible but natural change.
    A regenerate prompt describes only the region as it should look (its material, colour and finish) and
    asks to keep its shape, folds, shadows and the scene's light. To improve a redraw, regenerate the same
    region again with a better prompt; remove is only for taking something out of the photo, never for
    changing how it looks.
    Return only the JSON described by the supplied schema.
    """
    static let planPrompt = editingRules + "\nPlan the fewest steps needed to meet the instruction in the supplied photo."
    static let critiquePrompt = editingRules + """

    Compare the labelled Before and After photos against the instruction, using Before as the photo
    at the start of this instruction. The layers list includes earlier layers and those applied during
    this run; reuse their regions and revert a layer by id when needed.
    Answer satisfied true or false and explain briefly in notes. Be satisfied when the instruction is
    visibly met and the photo still looks natural; ask for more only for a clear gap or a visible flaw.
    If satisfied, give no further steps. Otherwise give only the next steps needed, without repeating
    changes already achieved.
    """

    private struct PlanContext: Encodable {
        var instruction: String
        var area: NormalizedRect?
        var regions: [RegionInfo]
        var done: [String]
        var layers: [LayerInfo]
        var history: [String] = []

        func text() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
}
