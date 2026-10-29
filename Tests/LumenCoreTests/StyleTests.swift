import Foundation
import Testing
@testable import LumenCore

/// People restyled from a catalogue: a face, head or body redrawn alone, its outline free to move but measured, and
/// effects graded over the photo, the person or what is behind them.
@Suite("Person styles", .timeLimit(.minutes(1)))
struct StyleTests {
    /// A 40 × 40 standing person filling the photo: a head 10 wide (rows 0–5), shoulders across the whole width (rows
    /// 6–13), a waist `waist` wide (rows 14–27) and legs 20 wide (rows 28–39).
    static func person(waist: Int = 24) -> MaskData {
        func width(_ row: Int) -> Int {
            switch row {
            case 0..<6: 10
            case 6..<14: 40
            case 14..<28: waist
            default: 20
            }
        }
        return MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            let x = i % 40, w = width(i / 40)
            return x >= (40 - w) / 2 && x < (40 - w) / 2 + w ? 255 : 0
        })
    }

    static func segment(_ mask: MaskData, _ label: String = "person") -> Segment {
        Segment(label: label, box: mask.boundingBox!, mask: mask)
    }

    @Test func theCatalogueHasTenStylesAndItsEffectsStayInRange() {
        #expect(PersonStyle.all.count >= 10 && StyleEffect.all.count >= 4)
        #expect(Set(PersonStyle.all.map(\.id)).count == PersonStyle.all.count)
        for effect in StyleEffect.all {
            for part in effect.parts {
                for (key, value) in part.values { #expect(key.range.contains(value), "\(effect.id) \(key)") }
            }
        }
        #expect(PersonStyle.named("athletic")?.adultsOnly == true && PersonStyle.named("shades")?.adultsOnly == false)
        #expect(PersonStyle.named("gigachad")?.effect == "monoDrama")
        #expect(PersonStyle.all.allSatisfy { !$0.example.isEmpty } && StyleEffect.all.allSatisfy { !$0.example.isEmpty },
                "an instruction for every style and effect, for Studio's menu")
    }

    @Test func aPromptNamesThePartThePlaceAndWhatStays() {
        let athletic = PersonStyle.named("athletic")!
        let asked = athletic.prompt(person: "person", place: "in the centre")
        #expect(asked.contains("V-shaped torso") && asked.contains("about 10% broader") && asked.contains("Change only the body of the person in the centre"))
        #expect(asked.contains("Keep their face, pose and clothes") && asked.contains("continue the background"))
        #expect(!asked.contains("slightly"), "said outright: asked for slightly broader shoulders, Muse Image changed nothing")
        #expect(athletic.prompt(person: "person", place: "on the left", firmer: .subtler).contains("subtler"))
        #expect(PersonStyle.named("chad")!.prompt(person: "person", place: "on the left").contains("Change only the face of the person on the left"))
    }

    @Test func aBodysShouldersAndWaistAreMeasured() throws {
        let body = try #require(ShapeMeasure.body(Self.person()))
        #expect(body.shoulders == 40 && body.waist == 24)
        let changes = try #require(ShapeMeasure.change(.body, before: Self.person(), after: Self.person(waist: 22)))
        #expect(changes.map(\.name) == ["shoulders", "waist"])
        #expect(abs(changes[0].change) < 0.001 && abs(changes[1].change - (22.0 / 24 - 1)) < 0.001)
        // A face: cheeks 20 wide, a jaw 12 wide at 80% down, then 15 wide.
        func face(jaw: Int) -> MaskData {
            MaskData(size: PixelSize(width: 30, height: 30), coverage: (0..<900).map { i in
                let x = i % 30, y = i / 30, w = y < 20 ? 20 : jaw
                return x >= (30 - w) / 2 && x < (30 - w) / 2 + w ? 255 : 0
            })
        }
        let jaw = try #require(ShapeMeasure.change(.face, before: face(jaw: 12), after: face(jaw: 15)))
        #expect(abs(jaw[0].change - 0.25) < 0.001)
        #expect(EditAgent.shapeNote(changes, limits: ShapeLimits(least: 0.02, most: 0.12, measures: "")) ==
                "Shape: shoulders +0%, waist −8% (a believable change is 2% to 12%).")
    }

    @Test func thePlanCheckKeepsOnlyCatalogueStylesWithAPerson() {
        let select = EditStep.select(Selection(id: "person", concept: "person"))
        let checked = EditPlan(summary: "Styles", steps: [
            select,
            .style(StyleStep(region: "person", style: "chad", effect: "none")),
            .style(StyleStep(region: "person", style: "elf", effect: "vintage")),
            .style(StyleStep(region: nil, style: "athletic")),
            .style(StyleStep(region: nil, style: "none", effect: "neonNight")),
            .style(StyleStep(region: nil, effect: "mainCharacter")),
            .style(StyleStep(region: "person", style: "none", effect: "none")),
        ]).checked()
        #expect(checked.plan.steps == [
            select,
            .style(StyleStep(region: "person", style: "chad")),
            .style(StyleStep(region: "person", effect: "vintage")),
            .style(StyleStep(effect: "neonNight")),
        ])
        #expect(checked.notes.contains { $0.contains("unknown style \"elf\"") })
        #expect(checked.notes.filter { $0.contains("no person to restyle") }.count == 2)
        #expect(checked.notes.contains { $0.contains("no style or effect") })
    }

    @Test func aStyleStepIsAFlatObjectInJSON() throws {
        let step = EditStep.style(StyleStep(region: "person", style: "gigachad", effect: "monoDrama"))
        let data = try JSONEncoder().encode(step)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "style" && object["style"] as? String == "gigachad")
        #expect(try JSONDecoder().decode(EditStep.self, from: data) == step)
        let schema = String(decoding: EditPlan.jsonSchema(), as: UTF8.self)
        #expect(schema.contains("\"gigachad\"") && schema.contains("\"mainCharacter\""))
    }

    /// The athletic redraw first narrowed the waist by a third, too far to believe: it is asked for once more, subtler,
    /// and the believable one is kept. Its mask reaches past the person and is soft, so the new outline can show.
    @Test func aBodyChangedTooFarIsRedrawnSubtlerAndTheCriticIsToldHowFar() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Athletic", steps: [
            .select(Selection(id: "person", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "person", style: "athletic")),
        ]))
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.person(waist: 16))],
                                                 [Self.segment(Self.person(waist: 22))]])
        let generator = StyleGenerator(), host = StyleHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        for try await _ in agent.run("Make my body athletic") {}
        let prompts = await generator.prompts
        #expect(prompts.count == 2)
        #expect(prompts.first?.contains("V-shaped torso") == true && prompts.last?.contains("subtler") == true)
        let done = try #require(await planner.critiqued.first)
        #expect(done.contains("Person: Athletic build"))
        #expect(done.contains("Shape: shoulders +0%, waist −8% (a believable change is 2% to 15%)."), "\(done)")
        let mask = try #require(await host.patchMasks.first)
        #expect(mask[6, 20] > 0, "reaches past the waist, where the outline may move in or out")
        #expect(mask.coverage.contains { $0 > 0 && $0 < 255 }, "with a soft edge")
    }

    /// Where the host can move pixels, an athletic build is a warp by exactly the amount, with no redraw: Muse Image
    /// changed a body by a percent or two, or not at all.
    @Test func anAthleticBuildIsAWarpWhereTheHostCanMovePixels() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Athletic", steps: [
            .select(Selection(id: "person", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "person", style: "athletic")),
        ]))
        let generator = StyleGenerator(), host = ReshapingHost()
        let agent = EditAgent(planner: planner, segmenter: StyleSegmenter(answers: [[Self.segment(Self.person())]]),
                              generator: generator, host: host)
        var applied: [Layer] = []
        for try await event in agent.run("Make my body athletic") {
            if case .applied(let layer) = event { applied.append(layer) }
        }
        #expect(await generator.prompts.isEmpty, "no redraw")
        #expect(await host.asked == [0.1, -0.1])
        #expect(applied.map(\.label) == ["Person: Athletic build"])
        let done = try #require(await planner.critiqued.first)
        #expect(done.contains("Shape: shoulders +10%, waist −10% (a believable change is 2% to 15%)."), "\(done)")
    }

    /// Muse Image redrew a bluish phone photo's face warmer than the photo, which showed as a seam down the neck. A face
    /// whose colour drifted is drawn once more, told so, and the closer one is kept.
    @Test func aFaceRedrawnInAnotherToneIsDrawnAgainInThePhotosOwn() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Chad", steps: [
            .select(Selection(id: "man", concept: "face", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "chad")),
        ]))
        let face = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (10..<30).contains(i % 40) && (5..<35).contains(i / 40) ? 255 : 0
        })
        let segmenter = StyleSegmenter(answers: [[Self.segment(face, "face")], [Self.segment(face, "face")], [Self.segment(face, "face")]])
        let generator = NumberedGenerator(), host = TonedHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        for try await _ in agent.run("Give him a chad face") {}
        let prompts = await generator.prompts
        #expect(prompts.count == 2 && prompts[1].contains("came out a different tone"))
        let placed = await host.placed
        #expect(placed == [Data([2])], "the second, in the photo's own tone: \(placed.map { Array($0) })")
    }

    /// Where the host can, the drifted face gets the photo's cast back from its pixels, with no second redraw.
    @Test func aFaceInAnotherToneIsMatchedWhereTheHostCan() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Beard", steps: [
            .select(Selection(id: "man", concept: "face", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "beard")),
        ]))
        let face = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (10..<30).contains(i % 40) && (5..<35).contains(i / 40) ? 255 : 0
        })
        let generator = NumberedGenerator(), host = MatchingHost()
        let agent = EditAgent(planner: planner, segmenter: StyleSegmenter(answers: [[Self.segment(face, "face")], [Self.segment(face, "face")]]),
                              generator: generator, host: host)
        for try await _ in agent.run("Give him a beard") {}
        #expect(await generator.prompts.count == 1)
        #expect(await host.placed == [Data([9])], "the matched redraw")
    }

    /// A gym-built body is reshaped first and then redrawn for its muscles; when the image model declines the redraw,
    /// the new shape stays and the critic is told.
    @Test func aGymBuiltBodyKeepsItsWarpWhenTheRedrawIsDeclined() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Gym-built", steps: [
            .select(Selection(id: "person", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "person", style: "muscular")),
        ]))
        let host = ReshapingHost()
        let agent = EditAgent(planner: planner, segmenter: StyleSegmenter(answers: [[Self.segment(Self.person())]]),
                              generator: DecliningGenerator(), host: host)
        var applied: [Layer] = []
        for try await event in agent.run("Make him look gym-built") {
            if case .applied(let layer) = event { applied.append(layer) }
        }
        #expect(await host.asked == [0.12, -0.04])
        #expect(applied.map(\.label) == ["Person: Gym-built"])
        let done = try #require(await planner.critiqued.first)
        #expect(done.contains { $0.contains("didn't work") && $0.contains("the reshaped build stays") }, "\(done)")
    }

    /// Over loose clothes the muscle redraw came back with a waist far wider and smeared, where the reshape alone was
    /// clean: a redraw that isn't believable on a reshaped body is left out, and the critic told why.
    @Test func anUnbelievableRedrawOnAReshapedBodyIsLeftOut() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Gym-built", steps: [
            .select(Selection(id: "person", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "person", style: "muscular")),
        ]))
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.person(waist: 40))],
                                                 [Self.segment(Self.person(waist: 36))]])
        let generator = StyleGenerator()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: ReshapingHost())
        var applied: [Layer] = []
        for try await event in agent.run("Make him look gym-built") {
            if case .applied(let layer) = event { applied.append(layer) }
        }
        #expect(await generator.prompts.count == 2, "asked once more, subtler, first")
        #expect(applied.map(\.label) == ["Person: Gym-built"], "only the reshape")
        let done = try #require(await planner.critiqued.first)
        #expect(done.contains { $0.contains("was left out, as its shape went past a believable change; the reshaped build stays") }, "\(done)")
        #expect(done.contains("Shape: shoulders +12%, waist −4% (a believable change is 3% to 20%)."), "the reshape's own numbers")
    }

    @Test func aFaceStyleFindsTheFaceInsideThePerson() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Chad", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "chad")),
        ]))
        let face = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (15..<25).contains(i % 40) && (1..<6).contains(i / 40) ? 255 : 0
        })
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(face, "face")], [Self.segment(face, "face")]])
        let generator = StyleGenerator()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: StyleHost())
        for try await _ in agent.run("Give him a chad face") {}
        let requests = await segmenter.requests
        #expect(requests.count >= 2 && requests[1].concept == "face" && requests[1].box == nil)
        #expect(await generator.prompts.first?.contains("Change only the face of the person") == true)
    }

    /// Main character dims and calms what is behind the person, lifts the person and grades the photo; the same
    /// effect asked for again is not laid on twice.
    @Test func anEffectGradesBehindThePersonAndIsNotLaidOnTwice() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Main character", steps: [
            .select(Selection(id: "person", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "person", effect: "mainCharacter")),
            .style(StyleStep(region: "person", effect: "mainCharacter")),
        ]))
        let host = StyleHost()
        let agent = EditAgent(planner: planner, segmenter: StyleSegmenter(answers: [[Self.segment(Self.person())]]),
                              generator: StyleGenerator(), host: host)
        var applied: [Layer] = []
        for try await event in agent.run("Make it a main character shot") {
            if case .applied(let layer) = event { applied.append(layer) }
        }
        #expect(applied.map(\.label) == ["Behind person: Main character", "Person: Main character", "Photo: Main character"])
        let masks = applied.map { layer -> AssetID? in
            if case .adjustment(_, let mask) = layer.content { return mask }
            return nil
        }
        #expect(masks[0] != nil && masks[1] != nil && masks[2] == nil)
        if let id = masks[0], case .mask(let behind) = await agent.assets.get(id) {
            #expect(behind == Self.person().inverted())
        } else {
            Issue.record("no mask behind the person")
        }
    }
}

private actor StylePlanner: Planner {
    let modelID = "muse-spark-1.3"
    private let answer: EditPlan
    private(set) var critiqued: [[String]] = []
    init(plan: EditPlan) { answer = plan }
    func plan(_ request: PlanRequest) async throws -> EditPlan { answer }
    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiqued.append(request.done)
        return Critique(satisfied: true, notes: "Done.")
    }
}

private actor StyleSegmenter: Segmenter {
    let modelID = "sam-3.1"
    private var answers: [[Segment]]
    private(set) var requests: [SegmentRequest] = []
    init(answers: [[Segment]]) { self.answers = answers }
    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        return answers.isEmpty ? [] : answers.removeFirst()
    }
}

private actor StyleGenerator: Generator {
    let modelID = "muse-image-1.0"
    private(set) var prompts: [String] = []
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        prompts.append(request.prompt)
        return request.image
    }
}

/// A 40 × 40 photo whose crops are the size they cover, keeping each patch's mask.
private actor StyleHost: EditHost {
    private(set) var patchMasks: [MaskData] = []
    func size() async -> PixelSize { PixelSize(width: 40, height: 40) }
    func render(maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: 40, height: 40))
    }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: max(1, Int((region.width * 40).rounded())),
                                                                   height: max(1, Int((region.height * 40).rounded()))))
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws {
        if case .patch(_, let mask, _) = layer.content, case .mask(let data) = await assets.get(mask) { patchMasks.append(data) }
    }
    func remove(_ layer: Layer.ID) async throws {}
}

/// A host that warps: it hands back the crop it was given as reshaped, changed where the person was.
private actor ReshapingHost: EditHost {
    private(set) var asked: [Double] = []
    func size() async -> PixelSize { PixelSize(width: 40, height: 40) }
    func render(maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: 40, height: 40))
    }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: max(1, Int((region.width * 40).rounded())),
                                                                   height: max(1, Int((region.height * 40).rounded()))))
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws {}
    func remove(_ layer: Layer.ID) async throws {}
    func reshaped(_ image: EncodedImage, mask: MaskData, shoulders: Double, waist: Double) async throws -> Reshaped? {
        asked = [shoulders, waist]
        return Reshaped(image: image, changed: mask)
    }
}

/// Draws image 1, then image 2, each the crop's size.
private actor NumberedGenerator: Generator {
    let modelID = "muse-image-1.0"
    private(set) var prompts: [String] = []
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        prompts.append(request.prompt)
        return EncodedImage(data: Data([UInt8(prompts.count)]), format: .png, size: request.image.size)
    }
}

/// A photo whose crop measures a cool skin tone; the first redraw comes back warm, the second close to the photo.
private actor TonedHost: EditHost {
    private(set) var placed: [Data] = []
    func size() async -> PixelSize { PixelSize(width: 40, height: 40) }
    func render(maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: 40, height: 40))
    }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: max(1, Int((region.width * 40).rounded())),
                                                                   height: max(1, Int((region.height * 40).rounded()))))
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws {
        if case .patch(let image, _, _) = layer.content, case .image(let encoded) = await assets.get(image) { placed.append(encoded.data) }
    }
    func remove(_ layer: Layer.ID) async throws {}
    func measure(_ image: EncodedImage, mask: MaskData?) async throws -> ColourMeasurement? {
        switch image.data.first {
        case 1: ColourMeasurement(lightness: 62, a: 24, b: 30)
        case 2: ColourMeasurement(lightness: 60, a: 11, b: 16)
        default: ColourMeasurement(lightness: 60, a: 10, b: 14)
        }
    }
}

/// A host that tone-matches: the matched redraw is image 9.
private actor MatchingHost: EditHost {
    private(set) var placed: [Data] = []
    func size() async -> PixelSize { PixelSize(width: 40, height: 40) }
    func render(maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: 40, height: 40))
    }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: max(1, Int((region.width * 40).rounded())),
                                                                   height: max(1, Int((region.height * 40).rounded()))))
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws {
        if case .patch(let image, _, _) = layer.content, case .image(let encoded) = await assets.get(image) { placed.append(encoded.data) }
    }
    func remove(_ layer: Layer.ID) async throws {}
    func toneMatched(_ generated: EncodedImage, to original: EncodedImage, under mask: MaskData) async throws -> EncodedImage? {
        EncodedImage(data: Data([9]), format: .png, size: generated.size)
    }
}

/// An image model that declines every request.
private actor DecliningGenerator: Generator {
    let modelID = "muse-image-1.0"
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        throw LumenError.http(status: 400, message: "The response was filtered due to the prompt triggering our content management policy.")
    }
}
