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
    /// False for compatible providers whose bills are outside Lumen. Token usage is still reported.
    public var recordsCost: Bool

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.meta.ai/v1")!, planningModel: String = "muse-spark-1.3",
                segmentationModel: String = "sam-3.1", imageModel: String = "muse-image-1.0", timeout: TimeInterval = 180, recordsCost: Bool = true) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.planningModel = planningModel
        self.segmentationModel = segmentationModel
        self.imageModel = imageModel
        self.timeout = timeout
        self.recordsCost = recordsCost
    }

    /// The user's own key, from META_API_KEY. Lumen Studio keeps it in the Keychain instead.
    public static func fromEnvironment() throws -> MetaConfiguration {
        guard let key = ProcessInfo.processInfo.environment["META_API_KEY"], !key.isEmpty else { throw LumenError.missingKey }
        return MetaConfiguration(apiKey: key)
    }
}

/// Muse Spark plans an instruction into steps and judges the result.
public struct MetaPlanner: Planner, PhotoCostEstimating {
    public var estimatedCostPerPhoto: Double { MetaPricing.photoCost(includingPlanning: configuration.recordsCost) }
    public let configuration: MetaConfiguration
    public let transport: any MetaTransport
    public var modelID: String { configuration.planningModel }

    public init(configuration: MetaConfiguration, transport: any MetaTransport = RetryingMetaTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func plan(_ request: PlanRequest) async throws -> EditPlan {
        do {
            let context = PlanContext(instruction: request.instruction, area: request.area, regions: request.regions,
                                      done: request.done, layers: request.layers, history: request.history)
            // What stays the same goes first (the rules, then the photo) so Meta's prompt cache can serve it again
            // at its cached-input price; the instruction and what was done, which change, come last.
            return try await answer(EditPlan.self, prompt: Self.planPrompt,
                                    content: [.image(request.image), .text(try context.text())],
                                    name: "edit_plan", schema: EditPlan.jsonSchema())
        } catch { throw MetaHTTP.error(error) }
    }

    public func critique(_ request: CritiqueRequest) async throws -> Critique {
        do {
            var context = PlanContext(instruction: request.instruction, area: nil, regions: request.regions,
                                      done: request.done, layers: request.layers, history: request.history)
            if !request.measurements.isEmpty { context.measurements = request.measurements.map(Measured.init) }
            // The rules and the Before photo stay the same through a run's revisions: they go first, for the cache.
            // Close-ups follow the whole photos, each region's Before first, so what stays the same through a run comes first.
            var content: [ChatContentPart] = [.text("Before"), .image(request.before), .text("After"), .image(request.after)]
            for closeUp in request.closeUps {
                content += [.text("Close-up of \(closeUp.region), before"), .image(closeUp.before),
                            .text("Close-up of \(closeUp.region), after"), .image(closeUp.after)]
                if !closeUp.lostDetail.isEmpty {
                    content.append(.text("Fine detail lost in the close-up of \(closeUp.region), as shares of the close-up from its "
                                         + "top-left: " + closeUp.lostDetail.map(Self.place).joined(separator: "; ") + "."))
                }
            }
            content.append(.text(try context.text()))
            return try await answer(Critique.self, prompt: Self.critiquePrompt, content: content,
                                    name: "critique", schema: Critique.jsonSchema())
        } catch { throw MetaHTTP.error(error) }
    }

    private func answer<Answer: Decodable>(_ type: Answer.Type, prompt: String, content: [ChatContentPart],
                                           name: String, schema: Data) async throws -> Answer {
        let builder = ChatCompletionRequestBuilder(baseURL: configuration.baseURL, apiKey: configuration.apiKey,
                                                   model: modelID, timeout: configuration.timeout)
        let request = try builder.request(systemPrompt: prompt, content: content, schemaName: name, schema: schema)
        let (data, response) = try await transport.data(for: request)
        try MetaHTTP.validate(response, data: data)
        return try ChatCompletionRequestBuilder.decode(type, from: data, model: modelID, recordsCost: configuration.recordsCost)
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
    see, such as "jacket", "sky", "sofa" or "red gate", without possessives or long descriptions; when
    there are several, give a point on the one you mean and a box around it.
    Adjustment values: exposure in stops, usually between -1 and 1; the others in percent, usually 10 to 40
    either way for a visible but natural change. Temperature warms or cools the light; vibrance and
    saturation strengthen colours already there, so they make a blue sky bluer. highlightWarmth and
    shadowWarmth warm (positive) or cool the highlights and the shadows on their own, as a colour grade.
    Golden-hour light is low and warm: highlightWarmth 50 to 80, shadowWarmth 15 to 30, temperature 10 to 20,
    tint +5 to +10, highlights -10 to -25, a little exposure, and little or no vibrance. Its sky is soft, not
    deep blue: select a strong blue sky and lower its saturation 20 to 40, and the warm grade reaches it. Never
    warm a blue sky on its own: it turns teal. Low sun also comes from one side: select a gradient with no
    concept, from the side the light comes from in this photo (where the sky is brightest, or the side of the
    subject that is lit) about two thirds of the way across, such as from the left edge (x 0) or the right edge
    (x 1) at the height of the brightest sky, and give it exposure +0.25 to +0.45 and highlightWarmth 30 to 50,
    so the light falls off across the frame. Low sun also casts long shadows: for each subject whose base
    touches ground you can see (a person's feet, a car's wheels, a tree's trunk), select it with a shadowTip,
    the point where the top of its shadow lands on the ground, away from the light and from the same side as
    the gradient's light; with light from one side, about two to three times the subject's height across the
    frame at about the height of its base, and with light from behind the subject, toward the bottom of the
    photo. The tip lands on the ground the subject stands on, never on a wall, rail or object in front of it,
    so keep the shadow shorter there. Several people can share one selection: each casts its own shadow.
    Adjust that region exposure -1.6 to -2.0, highlights -30 and temperature -15: shade on sunlit ground is two
    stops or more darker than the light beside it, or it is lost in the grass's or sand's own texture. Skip a subject whose base is out of the photo; use null for shadowTip otherwise.
    A gradient region is light falling across the photo: full at from, none at to and beyond. Alone it is the
    region; with a concept, what is found fades along it, such as the sky nearest the sun. Use null for gradient
    otherwise.
    A regenerate prompt describes only the region as it should look (its material, colour and finish) and
    asks to keep its shape, folds, shadows and the scene's light. To change a colour, say the change outright,
    from what to what: "Recolour the light grey T-shirt to a deep royal blue instead of light grey, keeping
    its knit texture and folds". Never ask to keep the colour or pattern being changed: the image model can
    then leave it as it was. To fix a redraw that went wrong, regenerate the same region id again with a
    better prompt, because Lumen replaces the earlier redraw from this run; if the colour did not change,
    name the new colour more strongly and the old one it replaces. Do not select the object again for that. Remove is only for taking something out of
    the photo, never for changing how it looks.
    Return only the JSON described by the supplied schema.
    """
    static let planPrompt = editingRules + """

    Plan the fewest steps needed to meet the instruction in the supplied photo. The plan must contain every
    step that makes the change: selecting a region changes nothing by itself, so follow each select with the
    adjust, regenerate or remove that uses it.
    """
    static let critiquePrompt = editingRules + """

    Compare the labelled Before and After photos against the instruction, using Before as the photo
    at the start of this instruction. The layers list includes earlier layers and those applied during
    this run; reuse their regions and revert a layer by id when needed. The history lists earlier
    instructions, oldest first: read "that", "less", "more" and "undo" against the latest of them. Undoing
    takes off only that latest instruction's change, so Before already shows it and After should look as
    the photo did before it; never take off earlier changes for an undo.
    Close-ups of each region redrawn in this run, before and after, may follow the whole photos. Check in them
    that the redraw kept the shape, edges and detail of what is in and beside the region: a smeared wheel, a
    melted edge or a changed neighbouring object is a visible flaw, to be redrawn again.
    A close-up may name places that kept little of their fine detail. Look at each in the close-up: a smeared
    or blurred part, such as a headlight or a wheel gone soft, is a visible flaw to redraw again, unless the
    instruction asked for a smoother material there.
    Judge the look the words ask for, not only its direction: golden hour is warm, low light from one side
    with golden highlights, so a photo that is only evenly warmer than before has not met it.
    Measurements give each region changed in this run, and the rest of the photo, before and after: CIELAB
    lightness (0 black, 100 white), chroma (0 grey, 30 and above vivid), hue in degrees and a colour name of
    the colour most of it has, with the change between them (under 3 is hard to see), and the lightness of its
    brightest and darkest tenth. Read them with the photos:
    - A change the instruction asks for, even "a little", must be visible: a region it names that changed by
      less than 3, with its brightest and darkest tenth each moving less than 3 too, has not met it; ask for a
      clearly stronger step. Lights at night or a dark subject's shadows show in the brightest or darkest
      tenth, not the middle colour.
    - A colour the instruction names must be the region's colour now, by its name: black is lightness under
      about 15 with chroma under 10, so charcoal, dark grey or dark teal is not black; white is lightness over
      about 88 with chroma under 10. If the colour is short of it, redraw again, naming the new colour more
      strongly.
    - The rest of the photo should change only as much as the instruction asks for the whole photo.
    Answer satisfied true or false and explain briefly in notes. Be satisfied when the instruction is
    visibly met and the photo still looks natural; ask for more only for a clear gap or a visible flaw.
    If satisfied, give no further steps. Otherwise give only the next steps needed, without repeating
    changes already achieved.
    """

    /// "x 0.27 to 0.33, y 0.50 to 0.53 kept 15%".
    static func place(_ lost: LostDetail) -> String {
        let format = { (value: Double) in String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let rect = lost.rect
        return "x \(format(rect.x)) to \(format(rect.x + rect.width)), y \(format(rect.y)) to \(format(rect.y + rect.height)) "
            + "kept \(Int((lost.kept * 100).rounded()))%"
    }

    private struct PlanContext: Encodable {
        var instruction: String
        var area: NormalizedRect?
        var regions: [RegionInfo]
        var done: [String]
        var layers: [LayerInfo]
        var history: [String] = []
        var measurements: [Measured]?

        func text() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    /// A region's colour before and after, in whole numbers.
    private struct Measured: Encodable {
        struct Colour: Encodable {
            var lightness: Int
            var chroma: Int
            var hue: Int
            var colour: String
            var brightest: Int?
            var darkest: Int?

            init(_ measurement: ColourMeasurement) {
                lightness = Int(measurement.lightness.rounded())
                chroma = Int(measurement.chroma.rounded())
                hue = Int(measurement.hue.rounded()) % 360
                colour = measurement.name
                brightest = measurement.brightest.map { Int($0.rounded()) }
                darkest = measurement.darkest.map { Int($0.rounded()) }
            }
        }

        var region: String
        var before: Colour
        var after: Colour
        var change: Double

        init(_ change: RegionChange) {
            region = change.region
            before = Colour(change.before)
            after = Colour(change.after)
            self.change = (change.change * 10).rounded() / 10
        }
    }
}
