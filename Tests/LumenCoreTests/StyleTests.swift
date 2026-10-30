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

    /// The face on `person()`'s head, its chin at row 5.
    static let face = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
        (16..<24).contains(i % 40) && (1..<6).contains(i / 40) ? 255 : 0
    })

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
        #expect(athletic.built()!.prompt(person: "person", place: "on the left", firmer: .sameOutline)
            .contains("Keep the body exactly as wide as it is at the shoulders and the waist"))
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

    /// Measured from the face, a half-length body's shoulders are found below the chin, not in hair wider than they
    /// are where arms cover them.
    @Test func aBodyIsMeasuredDownFromItsFace() throws {
        // Hair 30 wide (rows 0–9), covered shoulders 12 wide (rows 10–13), a torso 26 wide, a waist 20 (rows 26–31).
        let body = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            let y = i / 40, w = y < 10 ? 30 : y < 14 ? 12 : (26..<32).contains(y) ? 20 : 26
            return abs(Double(i % 40) + 0.5 - 20) < Double(w) / 2 ? 255 : 0
        })
        let frame = BodyFrame(chin: 9, face: 7)
        #expect(frame.shoulders == 11...20 && frame.waist == 25)
        let measured = try #require(ShapeMeasure.body(body, frame: frame))
        #expect(measured.shoulders == 26 && measured.waist == 20)
        #expect(ShapeMeasure.body(body)?.shoulders == 30, "without it, the hair")
        #expect(frame.reach(9) == 0 && frame.reach(12) == 1)
    }

    /// A muscle redraw widened a slim man's waist by a fifth, within the largest change allowed, and read as heavier.
    @Test func aWaistWiderThanTheStyleAllowsIsNotBelievable() {
        let limits = PersonStyle.named("muscular")!.limits!
        #expect(EditAgent.miss([("shoulders", 0.12), ("waist", 0.04)], limits) == 0)
        #expect(abs(EditAgent.miss([("shoulders", 0.12), ("waist", 0.20)], limits) - 0.12) < 0.001)
        #expect(EditAgent.shapeNote([("shoulders", 0.15), ("waist", -0.05)], limits: limits)
                == "Shape: shoulders +15%, waist −5% (a believable change is 3% to 20%, the waist at most +8% wider).")
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
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                 [Self.segment(Self.person(waist: 16))], [Self.segment(Self.person(waist: 22))]])
        let generator = StyleGenerator(), host = StyleHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        for try await _ in agent.run("Make my body athletic") {}
        let prompts = await generator.prompts
        #expect(prompts.count == 2)
        #expect(prompts.first?.contains("V-shaped torso") == true && prompts.last?.contains("subtler") == true)
        let done = try #require(await planner.critiqued.first)
        #expect(done.contains("Person: Athletic build"))
        #expect(done.contains("Shape: shoulders +0%, waist −8% (a believable change is 2% to 15%, the waist at most +2% wider)."), "\(done)")
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
        #expect(done.contains("Shape: shoulders +10%, waist −10% (a believable change is 2% to 15%, the waist at most +2% wider)."), "\(done)")
    }

    /// Muse Image redrew a bluish phone photo's face warmer than the photo, which showed as a seam down the neck. A face
    /// whose colour drifted is drawn once more, told so, and the closer one is kept.
    @Test func aFaceRedrawnInAnotherToneIsDrawnAgainInThePhotosOwn() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Smile", steps: [
            .select(Selection(id: "man", concept: "face", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "smile")),
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
        #expect(await host.asked == [0.15, -0.05])
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
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                 [Self.segment(Self.person(waist: 40))], [Self.segment(Self.person(waist: 36))]])
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
        #expect(done.contains("Shape: shoulders +15%, waist −5% (a believable change is 3% to 20%, the waist at most +8% wider)."), "the reshape's own numbers")
    }

    /// In a half-length photo, a man's friends' arms covered his shoulders and his hair was the widest part of him: the
    /// warp took it for his shoulders and widened his head, and the muscle redraw redrew his face and hair. A body's
    /// face is found first; it reaches the warp, and nothing at or above the chin is redrawn.
    @Test func aBodyIsReshapedAndRedrawnBelowItsFace() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Gym-built", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "muscular")),
        ]))
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                 [Self.segment(Self.person(waist: 23))]])
        let host = KeepingHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: StyleGenerator(), host: host)
        for try await _ in agent.run("Make him look gym-built") {}
        #expect(await segmenter.requests.map(\.concept) == ["person", "face", "person"])
        let face = try #require(await host.face)
        #expect(BodyFrame(face: face)?.chin == 5, "the face reaches the warp, in the crop's rows")
        let redrawn = try #require(await host.patchMasks.last)
        #expect(await host.patchMasks.count == 2, "the reshape and the redraw")
        #expect((0...5).allSatisfy { y in (0..<40).allSatisfy { redrawn[$0, y] == 0 } }, "nothing at or above the chin")
        #expect(redrawn[20, 20] > 200, "the body is")
    }

    /// SAM's "head" was only the hair: asked to look 30 years older, a man got grey hair on a face as young as it was.
    /// A head to age takes in the face too.
    @Test func aHeadToAgeIsItsFaceAsWellAsItsHair() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Older", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "older")),
        ]))
        let hair = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (15..<25).contains(i % 40) && (0..<2).contains(i / 40) ? 255 : 0
        })
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                 [Self.segment(hair, "head")]])
        let host = StyleHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: StyleGenerator(), host: host)
        for try await _ in agent.run("Make him look 30 years older") {}
        #expect(await segmenter.requests.prefix(3).map(\.concept) == ["person", "face", "head"])
        let mask = try #require(await host.patchMasks.first)
        // The crop is the head's box grown by 30% each way, clipped to the photo; the face's middle is in it.
        #expect(mask.coverage.filter { $0 > 200 }.count > 2 * hair.coverage.filter { $0 > 0 }.count, "the face is redrawn with the hair")
    }

    /// A big fish held against a man's chest was bent by the warp and smeared by the redraw. What the plan says to
    /// keep reaches the host's reshape, and the redraw doesn't show over it.
    @Test func whatThePersonHoldsIsKeptOutOfTheReshapeAndTheRedraw() async throws {
        let fish = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (2..<20).contains(i % 40) && (16..<24).contains(i / 40) ? 255 : 0
        })
        let planner = StylePlanner(plan: EditPlan(summary: "Gym-built", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .select(Selection(id: "fish", concept: "fish", points: [NormalizedPoint(x: 0.25, y: 0.5)])),
            .style(StyleStep(region: "man", style: "muscular", keep: "fish")),
        ]))
        // The redraw found again 4% slimmer at the waist: a believable change, so it is placed.
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(fish, "fish")],
                                                 [Self.segment(Self.face, "face")], [Self.segment(Self.person(waist: 23))]])
        let host = KeepingHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: StyleGenerator(), host: host)
        for try await _ in agent.run("Make him look gym-built") {}
        let kept = try #require(await host.kept)
        #expect(kept[10, 20] > 200 && kept[30, 5] == 0, "the fish reaches the reshape")
        let redrawn = try #require(await host.patchMasks.last)
        #expect(await host.patchMasks.count == 2, "the reshape and the redraw")
        #expect(redrawn[10, 20] < 30 && redrawn[20, 30] > 200, "the redraw shows over him but not over the fish")
    }

    @Test func thePlanCheckDropsAnUnknownKeepButNotTheStyle() {
        let checked = EditPlan(summary: "Gym-built", steps: [
            .select(Selection(id: "man", concept: "person")),
            .style(StyleStep(region: "man", style: "muscular", keep: "fish")),
        ]).checked()
        #expect(checked.plan.steps.last == .style(StyleStep(region: "man", style: "muscular")))
        #expect(checked.notes.contains { $0.contains("dropped keep using unknown region \"fish\"") })
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
        #expect(await generator.prompts.first?.contains("Change only these parts of the person in the centre of this picture: their face; their neck and ears") == true)
    }

    /// `person()`'s bare skin: a neck under the chin (rows 6–9), a hand at each side of the waist (rows 24–27), and
    /// skin on the shoulder not joined to the face (a friend's hand, rows 8–9).
    static let skin = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
        let x = i % 40, y = i / 40
        let neck = (17..<23).contains(x) && (6..<10).contains(y)
        let hands = (24..<28).contains(y) && ((8..<12).contains(x) || (28..<32).contains(x))
        let friend = (12..<15).contains(x) && (8..<10).contains(y)
        return neck || hands || friend ? 255 : 0
    })

    /// Made 30 years older, a face sat on a young neck and young hands. An older head takes the neck and ears joined
    /// to its face with it, and the hands are aged apart, in their own close-up.
    @Test func anOlderHeadTakesItsNeckWithItAndItsHandsApart() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Older", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "older")),
        ]))
        let hair = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (15..<25).contains(i % 40) && (0..<2).contains(i / 40) ? 255 : 0
        })
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                 [Self.segment(hair, "head")]])
        let host = StyleHost(skin: Self.skin)
        let generator = StyleGenerator()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        for try await _ in agent.run("Make him look 30 years older") {}
        #expect(await segmenter.requests.prefix(3).map(\.concept) == ["person", "face", "head"], "the face is found once, first")
        let prompts = await generator.prompts
        #expect(prompts.count == 2, "the head with its neck, then the hands")
        #expect(prompts.first?.contains("their head and hair; their neck and ears") == true)
        #expect(prompts.last?.contains("hands and arms") == true && prompts.last?.contains("30 years older") == true)
        #expect(await host.covers(0, x: 20, y: 9) > 200, "the neck is redrawn with the head")
        #expect(await host.covers(0, x: 13, y: 9) < 30, "a friend's hand on the shoulder is not")
        let (left, right) = (await host.covers(1, x: 10, y: 25), await host.covers(1, x: 29, y: 26))
        #expect(left > 200 && right > 200, "both hands are")
        let done = await planner.critiqued.first ?? []
        #expect(done.contains("Redrawn with the head: their neck and ears."))
    }

    /// Zombie make-up's hands were declined by Muse Image, and the trace cut the reason off with the prompt. The face
    /// stays made up, the critic is told the hands weren't, and the trace keeps the whole error.
    @Test func aDeclinedHandsRedrawKeepsTheFaceAndSaysWhy() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Zombie", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "zombie")),
        ]))
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                 [Self.segment(Self.face, "face")]])
        let host = StyleHost(skin: Self.skin)
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: SecondDecliningGenerator(), host: host)
        var details: [String] = []
        for try await event in agent.run("Give him zombie make-up") {
            if case .trace(let trace) = event { details.append(trace.detail) }
        }
        #expect(await host.patchMasks.count == 1, "the face, with its neck")
        #expect(details.contains { $0.hasSuffix("content management policy.") }, "the whole error, after the shortened prompt")
        #expect((await planner.critiqued.first ?? []).contains { $0.hasPrefix("The redraw of the man's hands and arms didn't work") })
    }

    /// Meta's filter turned down grey-green body paint on "hands and arms" and let it by on "hands": turned down, the
    /// hands alone are asked for once more.
    @Test func aFilteredHandsRedrawAsksForTheHandsAlone() async throws {
        let planner = StylePlanner(plan: EditPlan(summary: "Zombie", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
            .style(StyleStep(region: "man", style: "zombie")),
        ]))
        let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                 [Self.segment(Self.face, "face")]])
        let host = StyleHost(skin: Self.skin)
        let generator = ArmsDecliningGenerator()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        for try await _ in agent.run("Give him zombie make-up") {}
        let prompts = await generator.prompts
        // The face may be drawn twice (this fake SAM finds it again off where it was); the hands come last.
        let hands = prompts.suffix(2)
        #expect(hands.first?.contains("Cover this person's hands and arms in grey-green theatrical body paint") == true)
        #expect(hands.last?.contains("Cover this person's hands in grey-green theatrical body paint") == true
                && hands.last?.contains("Change only the bare skin of the hands in this picture") == true)
        #expect(await host.patchMasks.count == 2, "the face, then the hands")
    }

    /// Athletic on a man in a T-shirt only warped his outline. A body whose build shows (a fitted top, or none) is
    /// redrawn with the new build, evenly, inside the outline the warp moved and told to keep it: asked for broader
    /// shoulders again over the warp, Muse Image drew them back as they were. Under a jacket only the outline moves,
    /// and so it does where the host doesn't say where the outline went.
    @Test func aBodyInAFittedTopIsRedrawnWithItsNewBuild() async throws {
        for wears in ["fitted", "loose", "unsaid"] {
            let planner = StylePlanner(plan: EditPlan(summary: "Athletic", steps: [
                .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.5)])),
                .style(StyleStep(region: "man", style: "athletic", wears: wears == "unsaid" ? "fitted" : wears)),
            ]))
            // SAM's outline of the warped crop, to compare the build with, then the build found again 4% slimmer.
            let segmenter = StyleSegmenter(answers: [[Self.segment(Self.person())], [Self.segment(Self.face, "face")],
                                                     [Self.segment(Self.person())], [Self.segment(Self.person(waist: 23))]])
            let host = KeepingHost(outlines: wears != "unsaid")
            let generator = StyleGenerator()
            let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
            for try await _ in agent.run("Make him athletic") {}
            let prompts = await generator.prompts
            if wears == "fitted" {
                #expect(await host.patchMasks.count == 2, "the warp, then the build redrawn")
                let prompt = prompts.first ?? ""
                #expect(prompt.contains("They wear a fitted top") && prompt.contains("evenly on both sides"))
                #expect(prompt.contains("keep its width, size and every edge exactly where they are") && !prompt.contains("10% broader"),
                        "the build inside the warped outline, not the outline asked for again")
                let done = await planner.critiqued.first ?? []
                #expect(done.contains("The man wears a fitted top, so their build was redrawn as well as their outline moved."))
                #expect(await segmenter.requests.map(\.concept) == ["person", "face", "person", "person"],
                        "the warped crop's own outline, then the build's")
                #expect(done.contains("The build was redrawn on the reshaped body; against the warp's new outline it moved "
                                      + "shoulders +0%, waist −4%, and up to 5% keeps it: the body's change is the warp's Shape note."))
            } else {
                #expect(await host.patchMasks.count == 1 && prompts.isEmpty, "the warp alone")
            }
        }
    }

    /// A bare chest is seen in the skin, whatever the planner said; otherwise the planner's word is taken.
    @Test func aBareChestIsSeenInItsSkin() {
        let chest = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (6..<22).contains(i / 40) && (8..<32).contains(i % 40) ? 255 : 0
        })
        let share = PersonPieces.bareChest(face: Self.face, person: Self.person(), skin: chest)
        #expect((share ?? 0) > 0.9)
        #expect(PersonPieces.attire(planned: "fitted", bareChest: share) == .bare)
        #expect(PersonPieces.attire(planned: "fitted", bareChest: 0.1) == .fitted)
        #expect(PersonPieces.attire(planned: nil, bareChest: nil) == .loose)
        #expect(PersonPieces.bareChest(face: Self.face, person: Self.person(), skin: Self.skin) ?? 1 < 0.2, "a neck and hands are no bare chest")
    }

    /// A pirate needs a hat where the photo has only sky, and a coat where it has a shirt. The costume's mask takes in
    /// room above the head, the clothes on the upper body and the neck, and the head isn't compared again after: a
    /// hat changes its outline on purpose.
    @Test func aCostumeMakesRoomForItsHatAndTakesInTheClothes() async throws {
        // `person()` 12 rows lower, so there is room above the head.
        let lower = { (mask: MaskData) in
            MaskData(size: mask.size, coverage: (0..<1600).map { i in i / 40 >= 12 ? mask.coverage[i - 480] : 0 })
        }
        let person = lower(Self.person()), face = lower(Self.face)
        let hair = MaskData(size: PixelSize(width: 40, height: 40), coverage: (0..<1600).map { i in
            (15..<25).contains(i % 40) && (12..<14).contains(i / 40) ? 255 : 0
        })
        let planner = StylePlanner(plan: EditPlan(summary: "Pirate", steps: [
            .select(Selection(id: "man", concept: "person", points: [NormalizedPoint(x: 0.5, y: 0.6)])),
            .style(StyleStep(region: "man", style: "pirate")),
        ]))
        let segmenter = StyleSegmenter(answers: [[Self.segment(person)], [Self.segment(face, "face")], [Self.segment(hair, "head")]])
        let host = StyleHost()
        let generator = StyleGenerator()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host)
        var applied: [Layer] = []
        for try await event in agent.run("Dress him as a pirate captain") {
            if case .applied(let layer) = event { applied.append(layer) }
        }
        #expect(await segmenter.requests.map(\.concept) == ["person", "face", "head"], "no head compared after the redraw")
        #expect(applied.first?.drawsNew == true, "a costume draws new clothes: none of the jacket's detail comes back")
        #expect(await host.covers(0, x: 2, y: 30) > 200, "placed as far as it was drawn, past its room beside the waist")
        let prompt = try #require(await generator.prompts.first)
        #expect(prompt.contains("tricorn hat") && prompt.contains("the space just above their head")
                && prompt.contains("the clothes on their upper body"))
        #expect(await host.covers(0, x: 20, y: 9) > 200, "room for the hat, above the head")
        let (chest, shoulder) = (await host.covers(0, x: 20, y: 26), await host.covers(0, x: 3, y: 22))
        #expect(chest > 200 && shoulder > 200, "the coat over the chest and shoulders")
    }

    /// A costume the catalogue lacks is dressed as the planner says, and one with nothing to dress as is dropped.
    @Test func aCostumeIsDressedAsThePlannerSays() {
        let costume = PersonStyle.named("costume")!.dressed(as: "a medieval knight in shining armour")
        #expect(costume.prompt(person: "person", place: "in the centre", pieces: costume.pieces)
            .contains("Dress this person up as a medieval knight in shining armour"))
        let checked = EditPlan(summary: "Costumes", steps: [
            .select(Selection(id: "man", concept: "person")),
            .style(StyleStep(region: "man", style: "costume", wears: "unknown", with: ["hat", "cape"], outfit: "a knight")),
            .style(StyleStep(region: "man", style: "costume", outfit: " ")),
            .style(StyleStep(region: "man", style: "chad", outfit: "a knight")),
        ]).checked()
        #expect(checked.plan.steps.dropFirst().first == .style(StyleStep(region: "man", style: "costume", with: ["hat"], outfit: "a knight")))
        #expect(checked.plan.steps.last == .style(StyleStep(region: "man", style: "chad")), "an outfit only goes with a costume")
        #expect(checked.notes.contains { $0.contains("dropped unknown piece \"cape\"") })
        #expect(checked.notes.contains { $0.contains("dropped the costume style with no outfit") })
    }

    /// The neck is the skin joined to the face; skin beside it that isn't (a friend's hand on the shoulder) is not.
    @Test func aNeckIsTheSkinJoinedToTheFace() throws {
        let neck = try #require(PersonPieces.neck(face: Self.face, person: Self.person(), skin: Self.skin))
        #expect(neck[20, 8] == 255 && neck[13, 9] == 0 && neck[10, 25] == 0)
        let outline = try #require(PersonPieces.neck(face: Self.face, person: Self.person(), skin: nil))
        #expect(outline[20, 7] > 200 && outline[2, 8] == 0, "without skin, the outline under the chin, about the jaw's width")
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

/// An image model behind a filter that turns down body paint on "hands and arms", as Meta's did, and lets the rest by.
private actor ArmsDecliningGenerator: Generator {
    let modelID = "muse-image-1.0"
    private(set) var prompts: [String] = []
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        prompts.append(request.prompt)
        if request.prompt.contains("hands and arms") && request.prompt.contains("body paint") {
            throw LumenError.http(status: 400, message: "The response was filtered due to the prompt triggering our content management policy.")
        }
        return request.image
    }
}

/// A 40 × 40 photo whose crops are the size they cover, keeping each patch's mask.
private actor StyleHost: EditHost {
    private(set) var patchMasks: [MaskData] = []
    private(set) var patchRects: [NormalizedRect] = []
    /// The person's bare skin, as a host that can look at its pixels finds it; nil for one that can't.
    private let bare: MaskData?
    init(skin: MaskData? = nil) { bare = skin }
    /// Says a redraw drew over the whole crop, as a costume bigger than its room does.
    func drawn(_ generated: EncodedImage, over original: EncodedImage, beyond mask: MaskData, reach: Int) async throws -> MaskData? {
        MaskData(size: mask.size, filledWith: 255)
    }
    func size() async -> PixelSize { PixelSize(width: 40, height: 40) }
    func render(maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: 40, height: 40))
    }
    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        EncodedImage(data: Data([0]), format: .png, size: PixelSize(width: max(1, Int((region.width * 40).rounded())),
                                                                   height: max(1, Int((region.height * 40).rounded()))))
    }
    func apply(_ layer: Layer, assets: AssetStore) async throws {
        if case .patch(_, let mask, let rect) = layer.content, case .mask(let data) = await assets.get(mask) {
            patchMasks.append(data)
            patchRects.append(rect)
        }
    }
    func remove(_ layer: Layer.ID) async throws {}
    func skin(_ image: EncodedImage, face: MaskData, person: MaskData) async throws -> MaskData? { bare?.resized(to: image.size) }

    /// What patch `index` covers at (`x`, `y`) on the 40 × 40 photo.
    func covers(_ index: Int, x: Int, y: Int) -> UInt8 {
        let mask = patchMasks[index], rect = patchRects[index]
        let cx = Int(((Double(x) + 0.5) / 40 - rect.x) / rect.width * Double(mask.size.width))
        let cy = Int(((Double(y) + 0.5) / 40 - rect.y) / rect.height * Double(mask.size.height))
        guard cx >= 0, cx < mask.size.width, cy >= 0, cy < mask.size.height else { return 0 }
        return mask[cx, cy]
    }
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
    private(set) var kept: MaskData?
    private(set) var face: MaskData?
    func reshaped(_ image: EncodedImage, mask: MaskData, face: MaskData?, keep: MaskData?, shoulders: Double,
                  waist: Double) async throws -> Reshaped? {
        asked = [shoulders, waist]
        kept = keep
        self.face = face
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

/// An image model that draws the first request and declines every one after.
private actor SecondDecliningGenerator: Generator {
    let modelID = "muse-image-1.0"
    private var count = 0
    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        count += 1
        if count == 1 { return request.image }
        throw LumenError.http(status: 400, message: "The response was filtered due to the prompt triggering our content management policy.")
    }
}

/// A host that warps and keeps each patch's mask, for what is kept out of both.
private actor KeepingHost: EditHost {
    private(set) var kept: MaskData?
    private(set) var patchMasks: [MaskData] = []
    /// Whether it says where the warped outline is (here, where it was).
    private let outlines: Bool
    init(outlines: Bool = false) { self.outlines = outlines }
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
    private(set) var face: MaskData?
    func reshaped(_ image: EncodedImage, mask: MaskData, face: MaskData?, keep: MaskData?, shoulders: Double,
                  waist: Double) async throws -> Reshaped? {
        kept = keep
        self.face = face
        return Reshaped(image: image, changed: mask, outline: outlines ? mask : nil)
    }
}
