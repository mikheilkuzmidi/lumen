import Foundation
import Testing
@testable import LumenCore

@Suite("Edit agent", .timeLimit(.minutes(1)))
struct AgentTests {
    @Test func followUpsReuseTheSkyAndCanRevertAnEarlierLayer() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Darken the sky", steps: [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: -0.4])),
        ]))
        let segmenter = AgentSegmenter(segments: [segment()])
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: AgentGenerator(), host: host)
        let first = try await collect(agent.run("Darken the sky"))
        let originalLayer = try #require(first.layers.first)
        let originalInfo = LayerInfo(id: originalLayer.id.uuidString, label: originalLayer.label, kind: "adjust", region: "sky")

        await planner.setPlan(EditPlan(summary: "Lighten it a little", steps: [
            .adjust(Adjustment(region: "sky", values: [.exposure: 0.1])),
        ]))
        let second = try await collect(agent.run("a bit less"))
        let adjustment = try #require(second.layers.first)
        let requests = await planner.plans
        #expect(requests[0].history.isEmpty && requests[0].layers.isEmpty)
        #expect(requests[1].instruction == "a bit less")
        #expect(requests[1].history == ["Darken the sky"])
        #expect(requests[1].regions == [RegionInfo(id: "sky", concept: "sky", box: segment().mask.boundingBox!, area: segment().mask.area)])
        #expect(requests[1].layers == [originalInfo])
        #expect(second.selections.isEmpty)
        #expect(await segmenter.requests.count == 1)
        #expect(second.stepIndices == [0], "step counts start fresh for each instruction")
        guard case .adjustment(let values, let mask) = adjustment.content,
              case .adjustment(_, let originalMask) = originalLayer.content else {
            Issue.record("Expected two sky adjustments")
            return
        }
        #expect(values == [.exposure: 0.1])
        #expect(mask == originalMask)
        #expect(await agent.assets.get(try #require(mask)) == .mask(segment().mask))
        let critiques = await planner.critiques
        #expect(critiques[1].before == AgentPhoto.preview(layers: 1))
        #expect(critiques[1].after == AgentPhoto.preview(layers: 2))
        #expect(critiques[1].layers.map(\.id) == [originalLayer.id.uuidString, adjustment.id.uuidString])
        #expect(critiques[0].history.isEmpty)
        #expect(critiques[1].history == ["Darken the sky"], "the critic reads \"a bit less\" against the earlier instruction")

        await planner.setPlan(EditPlan(summary: "Undo the first darkening", steps: [
            .revert(Revert(layer: originalLayer.id.uuidString)),
        ]))
        let third = try await collect(agent.run("Undo the first darkening"))
        #expect(third.reverted == [originalLayer.id])
        #expect(third.layers.isEmpty)
        #expect(await host.removed == [originalLayer.id])
        #expect(await host.layers == [adjustment])
        #expect(third.traces.contains { $0.kind == .revert && $0.detail.contains(originalLayer.id.uuidString) && $0.model == nil })
        let thirdRequest = try #require(await planner.plans.last)
        #expect(thirdRequest.history == ["Darken the sky", "a bit less"])
        #expect(thirdRequest.layers.map(\.id) == [originalLayer.id.uuidString, adjustment.id.uuidString])
        let thirdCritique = try #require(await planner.critiques.last)
        #expect(thirdCritique.before == AgentPhoto.preview(layers: 2))
        #expect(thirdCritique.after == AgentPhoto.preview(layers: 1))
        #expect(thirdCritique.layers.map(\.id) == [adjustment.id.uuidString])

        await planner.setPlan(EditPlan(summary: "No change", steps: []))
        _ = try await collect(agent.run("Keep it"))
        let nextRequest = try #require(await planner.plans.last)
        #expect(nextRequest.history == ["Darken the sky", "a bit less", "Undo the first darkening"])
        #expect(nextRequest.layers.map(\.id) == [adjustment.id.uuidString])
        #expect(nextRequest.regions.map(\.id) == ["sky"])
    }

    @Test func anUndoThatOnlyRevertsEndsWithoutAnotherLook() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Darken the sky", steps: [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: -0.4])),
        ]))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]), generator: AgentGenerator(), host: host)
        let layer = try #require(try await collect(agent.run("Darken the sky")).layers.first)
        let looks = await planner.critiques.count
        await planner.setPlan(EditPlan(summary: "Undo it", steps: [
            .revert(Revert(layer: layer.id.uuidString)), .finish(Finish(reason: "The darkening is undone.")),
        ]))
        let undo = try await collect(agent.run("Undo that"))
        #expect(undo.reverted == [layer.id])
        #expect(undo.reasons == ["The darkening is undone."])
        #expect(await planner.critiques.count == looks, "taking a layer off leaves the photo exactly as it was, so the critic is not asked")
        #expect(await host.layers.isEmpty)
    }

    @Test func resetForgetsThePhotoWithoutRemovingItsLayers() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Darken sky", steps: [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: -0.4])),
        ]))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                              generator: AgentGenerator(), host: host)
        let first = try await collect(agent.run("Darken the sky"))
        await agent.reset()
        await planner.setPlan(EditPlan(summary: "Warm the new photo", steps: [.adjust(Adjustment(values: [.temperature: 5]))]))
        _ = try await collect(agent.run("Warm this photo"))
        let request = try #require(await planner.plans.last)
        #expect(request.regions.isEmpty && request.layers.isEmpty && request.history.isEmpty && request.done.isEmpty)
        #expect(await host.removed.isEmpty)
        #expect(await host.layers.first == first.layers.first)
        #expect(await planner.critiques.last?.layers.map(\.kind) == ["adjust"])
        #expect(await planner.critiques.last?.layers.first?.region == nil)
    }

    @Test func aFailedRevertKeepsTheLayerInMemory() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Brighten", steps: [.adjust(Adjustment(values: [.exposure: 0.2]))]))
        let host = AgentHost(removeError: .invalidResponse("Cannot remove the layer."))
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host)
        let first = try await collect(agent.run("Brighten"))
        let layer = try #require(first.layers.first)
        await planner.setPlan(EditPlan(summary: "Undo", steps: [.revert(Revert(layer: layer.id.uuidString))]))
        let second = try await collect(agent.run("Undo that"))
        #expect(second.reverted.isEmpty)
        #expect(second.traces.contains { $0.kind == .failure && $0.detail.contains("Cannot remove") })
        #expect(await host.layers == [layer])
        #expect(await planner.critiques.last?.layers.map(\.id) == [layer.id.uuidString])
    }

    @Test func overlappingInstructionsRememberTheEarlierRun() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Darken sky", steps: [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: -0.4])),
        ]))
        let host = AgentHost(applyGate: gate)
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                              generator: AgentGenerator(), host: host)
        let first = Task { try await collect(agent.run("Darken the sky")) }
        await gate.waitUntilEntered()
        await planner.setPlan(EditPlan(summary: "A little less", steps: [.adjust(Adjustment(region: "sky", values: [.exposure: 0.1]))]))
        let second = Task { try await collect(agent.run("a bit less")) }
        await gate.release()
        let firstEvents = try await first.value
        let secondEvents = try await second.value
        #expect(firstEvents.layers.count == 1 && secondEvents.layers.count == 1)
        #expect(await planner.plans.last?.history == ["Darken the sky"])
        #expect(await planner.plans.last?.layers.map(\.id) == firstEvents.layers.map { $0.id.uuidString })
    }

    @Test func theCriticCanRevertALayerAppliedDuringTheRun() async throws {
        let host = AgentHost()
        let agent = EditAgent(planner: RevertingPlanner(), segmenter: AgentSegmenter(segments: []),
                              generator: AgentGenerator(), host: host)
        let events = try await collect(agent.run("Brighten a little"))
        let layer = try #require(events.layers.first)
        #expect(events.reverted == [layer.id])
        #expect(events.critiques.map(\.satisfied) == [false, true])
        #expect(await host.layers.isEmpty)
        #expect(await host.removed == [layer.id])
    }

    @Test func resetStopsAnEarlierRunFromRestoringItsMemory() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Change sky", steps: [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: -0.4])),
            .regenerate(Regeneration(region: "sky", prompt: "a sunset sky")),
        ]))
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                              generator: AgentGenerator(gate: gate), host: AgentHost())
        let first = Task { try await collect(agent.run("Make a sunset")) }
        await gate.waitUntilEntered()
        await agent.reset()
        await gate.release()
        await #expect(throws: LumenError.cancelled) { try await first.value }
        await planner.setPlan(EditPlan(summary: "No change", steps: []))
        _ = try await collect(agent.run("Keep this photo"))
        let request = try #require(await planner.plans.last)
        #expect(request.regions.isEmpty && request.layers.isEmpty && request.history.isEmpty)
    }

    @Test func selectsAdjustsAndRedrawsAsSeparateLayers() async throws {
        let plan = EditPlan(summary: "Change the coat", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4, .saturation: 10])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy wool coat")),
            .finish(Finish(reason: "The coat is ready.")),
        ])
        let planner = AgentPlanner(plan: plan)
        // SAM's check finds the redrawn coat where the old one was.
        let box = try #require(segment().mask.boundingBox)
        let crop = NormalizedRect(x: box.x - box.width * 0.15, y: box.y - box.height * 0.15,
                                  width: box.width * 1.3, height: box.height * 1.3)
        let redrawn = segment().mask.cropped(to: crop).resized(to: AgentGenerator.image.size)
        let segmenter = AgentSegmenter(segments: [segment()],
                                       answers: [[segment()], [Segment(label: "coat", box: .whole, mask: redrawn)]])
        let generator = AgentGenerator()
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: generator, host: host,
                              configuration: AgentConfiguration(previewLongEdge: 900))
        let events = try await collect(agent.run("Make the coat navy"))
        let layers = await host.layers
        #expect(layers == events.layers)
        #expect(layers.map(\.label) == ["Coat: exposure −0.4, saturation +10", "Coat: redrawn as a navy wool coat"])
        let adjustment = try #require(layers.first)
        guard case .adjustment(let values, let maskID) = adjustment.content else {
            Issue.record("Expected an adjustment layer")
            return
        }
        #expect(values == [.exposure: -0.4, .saturation: 10])
        let selectedMask = try #require(maskID)
        #expect(await agent.assets.get(selectedMask) == .mask(segment().mask))
        let patch = try #require(layers.last)
        guard case .patch(let imageID, let patchMaskID, let rect) = patch.content else {
            Issue.record("Expected a patch layer")
            return
        }
        #expect(abs(rect.x - 0.14) < 0.000001)
        #expect(abs(rect.y - 0.225) < 0.000001)
        #expect(abs(rect.width - 0.52) < 0.000001)
        #expect(abs(rect.height - 0.65) < 0.000001)
        #expect(await agent.assets.get(imageID) == .image(AgentGenerator.image))
        let generateRequest = try #require(await generator.requests.first)
        #expect(generateRequest.prompt == "a navy wool coat. Change only the coat in the centre of this picture, and nothing else.")
        let size = generateRequest.image.size
        let edge = max(2, Int((Double(min(size.width, size.height)) * 0.012).rounded()))
        #expect(generateRequest.mask == segment().mask.cropped(to: rect).resized(to: size).grown(by: edge), "a little past SAM's edge")
        // The redraw shows through SAM's own mask, held to the photo by the host (as it is, here) with the redrawn coat.
        let shown = segment().mask.cropped(to: rect).resized(to: size).union(redrawn)
        #expect(await agent.assets.get(patchMaskID) == .mask(shown.resized(to: AgentGenerator.image.size)))
        #expect(await host.fittedRegions == [rect])
        // The generator's crop, then the coat close up before it was redrawn and again for the check.
        #expect(await host.crops.map(\.maxLongEdge) == [2048, 768, 768])
        #expect(await host.crops.map(\.rect) == [rect, rect, rect])
        let closeUps = try #require(await planner.critiques.first?.closeUps)
        #expect(closeUps.map(\.region) == ["coat"] && closeUps.first?.before == AgentPhoto.crop && closeUps.first?.after == AgentPhoto.crop)
        // The plan and the check at the preview size; the selection at SAM's own size, where detail fits the mask.
        #expect(await host.previews == [900, 1536, 900], "the plan, the selection and the check")
        let request = try #require(await planner.plans.first)
        #expect(request.instruction == "Make the coat navy")
        #expect(request.regions.isEmpty && request.done.isEmpty)
        #expect(await planner.critiques.first?.layers.map(\.kind) == ["adjust", "regenerate"])
        #expect(await planner.critiques.first?.layers.map(\.region) == ["coat", "coat"])
        #expect(events.stepIndices == [0, 1, 2, 3])
        // The plan said it was ready before any result existed; the critic looked once and agreed.
        #expect(events.reasons == ["Done."])
        #expect(await planner.critiques.count == 1)
        let calls = events.traces.filter { $0.model != nil }
        // SAM looks at the redraw too, to check the coat kept its place and size.
        #expect(calls.map(\.kind) == [.plan, .select, .regenerate, .select, .critique])
        #expect(calls.map(\.model) == ["muse-spark-1.3", "sam-3.1", "muse-image-1.0", "sam-3.1", "muse-spark-1.3"])
        #expect(calls.allSatisfy { !$0.detail.isEmpty && $0.duration >= 0 && $0.started <= Date() })
    }

    @Test func areaFillsInOnlyAMissingSelectionBox() async throws {
        let area = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.7)
        let box = NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
        let point = NormalizedPoint(x: 0.4, y: 0.4)
        let planner = AgentPlanner(plan: EditPlan(summary: "Select", steps: [
            .select(Selection(id: "coat", concept: "coat", points: [point])),
            .select(Selection(id: "sleeve", box: box, points: [point])),
            .finish(Finish(reason: "Selected")),
        ]))
        let segmenter = AgentSegmenter(segments: [segment()])
        let agent = EditAgent(planner: planner, segmenter: segmenter, generator: AgentGenerator(), host: AgentHost())
        _ = try await collect(agent.run("Select the coat", area: area))
        #expect(await planner.plans.first?.area == area)
        let requests = await segmenter.requests
        #expect(requests.map(\.box) == [area, box])
        #expect(requests.map(\.concept) == ["coat", nil])
        #expect(requests.map(\.points) == [[point], [point]])
    }

    @Test func unionsSegmentsBeforeInvertingTheSelection() async throws {
        let size = PixelSize(width: 2, height: 2)
        let first = Segment(label: "coat", box: .whole, mask: MaskData(size: size, coverage: [255, 0, 0, 0]))
        let second = Segment(label: "coat", box: .whole, mask: MaskData(size: size, coverage: [0, 128, 0, 0]))
        let planner = AgentPlanner(plan: EditPlan(summary: "Select outside", steps: [
            .select(Selection(id: "outside", concept: "coat", invert: true)),
            .adjust(Adjustment(region: "outside", values: [.contrast: 5])),
        ]))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [first, second]),
                              generator: AgentGenerator(), host: host)
        let events = try await collect(agent.run("Change the background"))
        let selected = try #require(events.selections.first)
        #expect(selected.mask.coverage == [0, 127, 255, 255])
        #expect(selected.box == .whole)
        let request = try #require(await planner.critiques.first)
        #expect(request.regions.first?.area == selected.mask.area)
        #expect(request.regions.first?.box == selected.box)
        #expect(request.done == ["Outside: selected", "Outside: contrast +5"])
    }

    @Test(arguments: [false, true]) func nothingFoundSkipsDependentSteps(invert: Bool) async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Edit the missing coat", steps: [
            .select(Selection(id: "coat", concept: "coat", invert: invert)),
            .adjust(Adjustment(region: "coat", values: [.contrast: 20])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy coat")),
            .remove(Removal(region: "coat")),
            .adjust(Adjustment(values: [.exposure: 0.2])),
        ]))
        let generator = AgentGenerator()
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: generator, host: host)
        let events = try await collect(agent.run("Make the coat navy"))
        #expect(events.selections.isEmpty)
        #expect(await generator.requests.isEmpty)
        #expect(await host.layers.map(\.label) == ["Photo: exposure +0.2"])
        #expect(events.traces.contains { $0.detail == "Nothing found for coat." })
        #expect(events.traces.filter { $0.detail.hasPrefix("Skipped") }.count == 3)
        #expect(await planner.critiques.first?.regions.isEmpty == true)
        #expect(await planner.critiques.first?.done == ["Coat: nothing found for “coat”", "Photo: exposure +0.2"])
    }

    @Test func critiqueRevisesUsingTheSelectedRegionAndCompletedSteps() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Darken the coat", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4])),
        ]), critiques: [
            .success(Critique(satisfied: false, notes: "Needs more saturation", steps: [
                .adjust(Adjustment(region: "coat", values: [.saturation: 10])),
            ])),
            .success(Critique(satisfied: true, notes: "The coat looks right.")),
        ])
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                              generator: AgentGenerator(), host: host)
        let events = try await collect(agent.run("Darken the coat"))
        #expect(events.layers.map(\.label) == ["Coat: exposure −0.4", "Coat: saturation +10"])
        #expect(events.stepIndices == [0, 1, 2])
        #expect(events.critiques.map(\.satisfied) == [false, true])
        #expect(events.reasons == ["The coat looks right."])
        let requests = await planner.critiques
        #expect(requests.count == 2)
        #expect(requests[0].instruction == "Darken the coat")
        #expect(requests[0].before == AgentPhoto.preview(layers: 0))
        #expect(requests[0].after == AgentPhoto.preview(layers: 1))
        #expect(requests[1].before == requests[0].before)
        #expect(requests[1].after == AgentPhoto.preview(layers: 2))
        #expect(requests[1].regions == [RegionInfo(id: "coat", concept: "coat", box: segment().mask.boundingBox!, area: segment().mask.area)])
        #expect(requests[1].done == ["Coat: selected", "Coat: exposure −0.4", "Coat: saturation +10"])
        #expect(requests[0].layers.map(\.id) == [events.layers[0].id.uuidString])
        #expect(requests[1].layers.map(\.id) == events.layers.map { $0.id.uuidString })
    }

    @Test func stepLimitIncludesStepsFromRevisions() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [
            .adjust(Adjustment(values: [.exposure: 0.2])),
        ]), critiques: [.success(Critique(satisfied: false, notes: "More contrast", steps: [
            .adjust(Adjustment(values: [.contrast: 10])),
            .crop(Crop(rect: .whole)),
            .finish(Finish(reason: "Done")),
        ]))])
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host,
                              configuration: AgentConfiguration(maxSteps: 2))
        let events = try await collect(agent.run("Improve the photo"))
        #expect(events.stepIndices == [0, 1])
        #expect(await host.layers.count == 2)
        #expect(await planner.critiques.count == 1)
        #expect(events.reasons == ["Step limit reached."])
    }

    /// Re-selecting three women's tops each round used up all 12 steps before the critic's first revision was done.
    /// Selections change nothing in the photo, so the limit counts only the steps that do.
    @Test func selectionsDontCountTowardTheStepLimit() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Coat", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .select(Selection(id: "sleeve", concept: "coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: 0.2])),
        ]))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]), generator: AgentGenerator(),
                              host: host, configuration: AgentConfiguration(maxSteps: 1))
        let events = try await collect(agent.run("Brighten the coat"))
        #expect(events.stepIndices == [0, 1, 2])
        #expect(await host.layers.count == 1, "the adjustment, after two selections")
    }

    /// The black top under a woman's poncho answered to no name, so SAM found it by where it was; looked for by name
    /// after its redraw, it came back "could not check" each time and the critic asked for it again. A thing found only
    /// by location isn't looked for again by name.
    @Test func aThingFoundOnlyByLocationIsNotLookedForAgainByName() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Top", steps: [
            .select(Selection(id: "top", concept: "top", box: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5))),
            .regenerate(Regeneration(region: "top", prompt: "Make it royal blue")),
        ]))
        // Nothing by name in the box, nothing by name anywhere, then the box itself.
        let segmenter = AgentSegmenter(answers: [[], [], [segment()]])
        let events = try await collect(EditAgent(planner: planner, segmenter: segmenter, generator: AgentGenerator(),
                                                 host: AgentHost()).run("Make her top royal blue"))
        let requests = await segmenter.requests
        #expect(requests.count == 3 && requests[2].concept == nil, "selected by location, and not looked for again")
        #expect(!events.traces.contains { $0.detail.contains("Could not check the redraw") })
    }

    @Test func zeroStepsMakesNoModelCalls() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Unused", steps: []))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host,
                              configuration: AgentConfiguration(maxSteps: 0))
        let events = try await collect(agent.run("Improve the photo"))
        #expect(await planner.plans.isEmpty)
        #expect(await host.previews.isEmpty)
        #expect(events.reasons == ["Step limit reached."])
    }

    @Test func revisionLimitStopsEvenWhenTheCriticKeepsAsking() async throws {
        let revision = Critique(satisfied: false, notes: "Try more contrast", steps: [.adjust(Adjustment(values: [.contrast: 10]))])
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]),
                                   critiques: [.success(revision), .success(revision)])
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host,
                              configuration: AgentConfiguration(maxRevisions: 1))
        let events = try await collect(agent.run("Improve the photo"))
        #expect(await host.layers.count == 2)
        #expect(await planner.critiques.count == 2)
        #expect(events.reasons == ["Revision limit reached. Try more contrast"])
    }

    @Test func aRunCanAllowFewerRevisionsThanConfiguredButNotMore() async throws {
        let revision = Critique(satisfied: false, notes: "Try more contrast", steps: [.adjust(Adjustment(values: [.contrast: 10]))])
        func agent(_ planner: AgentPlanner, host: AgentHost) -> EditAgent {
            EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host,
                      configuration: AgentConfiguration(maxRevisions: 1))
        }
        // None this time: the first check ends the run, as when credits run low.
        let low = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]),
                               critiques: [.success(revision), .success(revision)])
        let lowHost = AgentHost()
        let events = try await collect(agent(low, host: lowHost).run("Improve the photo", maxRevisions: 0))
        let lowLayers = await lowHost.layers.count, lowChecks = await low.critiques.count
        #expect(lowLayers == 1 && lowChecks == 1)
        #expect(events.reasons == ["Revision limit reached. Try more contrast"])
        // Asking for more than configured gets the configured limit.
        let more = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]),
                                critiques: [.success(revision), .success(revision), .success(revision)])
        let moreHost = AgentHost()
        _ = try await collect(agent(more, host: moreHost).run("Improve the photo", maxRevisions: 5))
        let moreLayers = await moreHost.layers.count, moreChecks = await more.critiques.count
        #expect(moreLayers == 2 && moreChecks == 2)
    }

    @Test func refusedStepContinuesWithTheNextLayer() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Redraw and adjust", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .regenerate(Regeneration(region: "coat", prompt: "a navy coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4])),
            .finish(Finish(reason: "Adjusted the coat.")),
        ]))
        let generator = AgentGenerator(error: .refused("This edit was declined."))
        let host = AgentHost()
        let events = try await collect(EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                                                 generator: generator, host: host).run("Change the coat"))
        #expect(await host.layers.map(\.label) == ["Coat: exposure −0.4"])
        #expect(events.traces.contains { $0.kind == .failure && $0.detail.contains("declined") })
        #expect(events.traces.filter { $0.model == "muse-image-1.0" }.count == 1)
        // The plan said it was finished, but a step failed, so the critic looked before finishing.
        #expect(await planner.critiques.count == 1)
        #expect(events.reasons == ["Done."])
    }

    @Test func aPlannersBoxThatFindsNothingIsDroppedForASecondLook() async throws {
        let segmenter = AgentSegmenter(answers: [[], [segment()]])
        let planner = AgentPlanner(plan: EditPlan(summary: "Coat", steps: [
            .select(Selection(id: "coat", concept: "coat", box: NormalizedRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1))),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.2])),
            .finish(Finish(reason: "Darker coat.")),
        ]))
        let host = AgentHost()
        let events = try await collect(EditAgent(planner: planner, segmenter: segmenter, generator: AgentGenerator(), host: host).run("Darken the coat"))
        let requests = await segmenter.requests
        #expect(requests.count == 2 && requests[0].box != nil && requests[1].box == nil)
        #expect(await host.layers.map(\.label) == ["Coat: exposure −0.2"])
        #expect(events.reasons == ["Done."])
    }

    @Test func refusedPlanFailsTheStream() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Unused", steps: []), error: .refused("Cannot plan this edit."))
        let host = AgentHost()
        var events: [AgentEvent] = []
        do {
            for try await event in EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []),
                                             generator: AgentGenerator(), host: host).run("Change the photo") {
                events.append(event)
            }
            Issue.record("A refused plan must fail")
        } catch {
            #expect(error as? LumenError == .refused("Cannot plan this edit."))
        }
        #expect(await host.layers.isEmpty)
        #expect(events.stepIndices.isEmpty)
        #expect(events.traces.contains { $0.kind == .failure })
    }

    @Test func removalUsesItsPromptAndClipsContextToThePhoto() async throws {
        let mask = MaskData(size: PixelSize(width: 2, height: 2), coverage: [255, 0, 0, 0])
        let planner = AgentPlanner(plan: EditPlan(summary: "Remove", steps: [
            .select(Selection(id: "object", concept: "object")),
            .remove(Removal(region: "object")),
            .crop(Crop(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1))),
        ]))
        let generator = AgentGenerator()
        let host = AgentHost()
        let object = Segment(label: "object", box: .whole, mask: mask)
        // SAM finds nothing where the object was: it is gone.
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(answers: [[object], []]),
                              generator: generator, host: host)
        let events = try await collect(agent.run("Remove the object and crop"))
        #expect(await generator.requests.first?.prompt == "Remove the whole object at the top left of this picture, every part "
            + "of it. Fill its place with what is behind it, continuing the surroundings naturally. Change nothing else.")
        // Three times the object's size, clipped to the photo.
        let rect = try #require(await host.crops.first?.rect)
        #expect(rect == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        #expect(events.layers.map(\.label) == ["Object: removed", "Photo: cropped"])
        #expect(events.layers.last?.content == .crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)))
        #expect(events.traces.contains { $0.kind == .remove && $0.model == "muse-image-1.0" })
        #expect(await planner.critiques.first?.layers.map(\.kind) == ["remove", "crop"])
        #expect(await planner.critiques.first?.layers.map(\.region) == ["object", nil])
    }

    @Test func cancelledPlannerResultAddsNoLayers() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]), gate: gate)
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host)
        let consumer = Task { try await collect(agent.run("Brighten")) }
        await gate.waitUntilEntered()
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.isEmpty)
        #expect(await host.previews.count == 1)
        #expect(await gate.wasCancelled)
    }

    @Test func cancelledGenerationDiscardsItsResultAndPreservesCompletedLayers() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Change coat", steps: [
            .select(Selection(id: "coat", concept: "coat")),
            .adjust(Adjustment(region: "coat", values: [.exposure: -0.4])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy coat")),
            .crop(Crop(rect: .whole)),
        ]))
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: [segment()]),
                              generator: AgentGenerator(gate: gate), host: host)
        let consumer = Task { try await collect(agent.run("Change the coat")) }
        await gate.waitUntilEntered()
        #expect(await host.layers.count == 1)
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.map(\.label) == ["Coat: exposure −0.4"])
        #expect(await gate.wasCancelled)
        await planner.setPlan(EditPlan(summary: "A little less", steps: [.adjust(Adjustment(region: "coat", values: [.exposure: 0.1]))]))
        let followUp = try await collect(agent.run("A little less"))
        #expect(followUp.layers.count == 1 && followUp.selections.isEmpty)
        #expect(await planner.plans.last?.history == ["Change the coat"])
        #expect(await planner.plans.last?.layers.map(\.label) == ["Coat: exposure −0.4"])
    }

    @Test func terminatingTheStreamCancelsTheModelTask() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]), gate: gate)
        let host = AgentHost()
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host)
        let consumer = Task { try await collect(agent.run("Brighten")) }
        await gate.waitUntilEntered()
        consumer.cancel()
        _ = try? await consumer.value
        await gate.release()
        await gate.waitUntilLeft()
        #expect(await gate.wasCancelled)
        #expect(await host.layers.isEmpty)
    }

    @Test func cancellationDuringApplicationRollsBackTheLayer() async throws {
        let gate = AgentGate()
        let planner = AgentPlanner(plan: EditPlan(summary: "Adjust", steps: [.adjust(Adjustment(values: [.exposure: 1]))]))
        let host = AgentHost(applyGate: gate)
        let agent = EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []), generator: AgentGenerator(), host: host)
        let consumer = Task { try await collect(agent.run("Brighten")) }
        await gate.waitUntilEntered()
        #expect(await host.layers.count == 1)
        await agent.cancel()
        await gate.release()
        do {
            _ = try await consumer.value
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.isEmpty)
        #expect(await host.removed.count == 1)
        await planner.setPlan(EditPlan(summary: "No change", steps: []))
        _ = try await collect(agent.run("Keep the photo"))
        #expect(await planner.plans.last?.layers.isEmpty == true)
    }

    @Test func cancellationErrorEndsTheStreamWithTheDomainError() async throws {
        let planner = AgentPlanner(plan: EditPlan(summary: "Unused", steps: []), throwsCancellation: true)
        let host = AgentHost()
        do {
            _ = try await collect(EditAgent(planner: planner, segmenter: AgentSegmenter(segments: []),
                                            generator: AgentGenerator(), host: host).run("Brighten"))
            Issue.record("Cancellation must fail the stream")
        } catch {
            #expect(error as? LumenError == .cancelled)
        }
        #expect(await host.layers.isEmpty)
    }

    @Test func aModelCallTriedAgainSaysSoInTheTrace() async throws {
        let events = try await collect(EditAgent(planner: RetriedPlanner(), segmenter: AgentSegmenter(segments: []),
                                                 generator: AgentGenerator(), host: AgentHost()).run("Brighten"))
        let plan = try #require(events.traces.first { $0.kind == .plan && $0.model != nil })
        #expect(plan.detail == "Brighten (rate limited; tried again after 2 s)")
    }

    private func segment() -> Segment {
        var coverage = [UInt8](repeating: 0, count: 100)
        for y in 3..<8 {
            for x in 2..<6 { coverage[y * 10 + x] = 255 }
        }
        return Segment(label: "coat", box: .whole, mask: MaskData(size: PixelSize(width: 10, height: 10), coverage: coverage))
    }
}

private func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private extension Array where Element == AgentEvent {
    var layers: [Layer] { compactMap { if case .applied(let layer) = $0 { layer } else { nil } } }
    var reverted: [Layer.ID] { compactMap { if case .reverted(let id) = $0 { id } else { nil } } }
    var stepIndices: [Int] { compactMap { if case .stepStarted(let index, _) = $0 { index } else { nil } } }
    var selections: [Segment] { compactMap { if case .selected(_, let segment) = $0 { segment } else { nil } } }
    var critiques: [Critique] { compactMap { if case .critiqued(let critique) = $0 { critique } else { nil } } }
    var reasons: [String] { compactMap { if case .finished(let reason) = $0 { reason } else { nil } } }
    var traces: [TraceEvent] { compactMap { if case .trace(let trace) = $0 { trace } else { nil } } }
}

private actor AgentPlanner: Planner {
    let modelID = "muse-spark-1.3"
    private var answer: EditPlan
    private var answers: [Result<Critique, LumenError>]
    private let error: LumenError?
    private let gate: AgentGate?
    private let throwsCancellation: Bool
    private(set) var plans: [PlanRequest] = []
    private(set) var critiques: [CritiqueRequest] = []

    init(plan: EditPlan, critiques: [Result<Critique, LumenError>] = [], error: LumenError? = nil,
         gate: AgentGate? = nil, throwsCancellation: Bool = false) {
        answer = plan
        answers = critiques
        self.error = error
        self.gate = gate
        self.throwsCancellation = throwsCancellation
    }

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        plans.append(request)
        await gate?.wait()
        await gate?.recordReturn(cancelled: Task.isCancelled)
        if throwsCancellation { throw CancellationError() }
        if let error { throw error }
        return answer
    }

    func setPlan(_ plan: EditPlan) { answer = plan }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        critiques.append(request)
        return try answers.isEmpty ? Critique(satisfied: true, notes: "Done.") : answers.removeFirst().get()
    }
}

/// Answers after its first try was rate limited, as a retrying transport reports it.
private struct RetriedPlanner: Planner {
    let modelID = "muse-spark-1.3"

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        ModelCallNotes.report?("rate limited; tried again after 2 s")
        return EditPlan(summary: "Brighten", steps: [.adjust(Adjustment(values: [.exposure: 0.5])), .finish(Finish(reason: "Done."))])
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique { Critique(satisfied: true, notes: "Done.") }
}

private struct RevertingPlanner: Planner {
    let modelID = "muse-spark-1.3"

    func plan(_ request: PlanRequest) async throws -> EditPlan {
        EditPlan(summary: "Brighten", steps: [.adjust(Adjustment(values: [.exposure: 0.5]))])
    }

    func critique(_ request: CritiqueRequest) async throws -> Critique {
        guard let layer = request.layers.last else { return Critique(satisfied: true, notes: "Done.") }
        return Critique(satisfied: false, notes: "Too bright", steps: [.revert(Revert(layer: layer.id))])
    }
}

private actor AgentSegmenter: Segmenter {
    let modelID = "sam-3.1"
    private let segments: [Segment]
    /// Answers in turn, before falling back to `segments`.
    private var answers: [[Segment]]
    private(set) var requests: [SegmentRequest] = []

    init(segments: [Segment] = [], answers: [[Segment]] = []) {
        self.segments = segments
        self.answers = answers
    }

    func segment(_ request: SegmentRequest) async throws -> [Segment] {
        requests.append(request)
        return answers.isEmpty ? segments : answers.removeFirst()
    }
}

private actor AgentGenerator: Generator {
    let modelID = "muse-image-1.0"
    static let image = AgentPhoto.generated
    private let error: LumenError?
    private let gate: AgentGate?
    private(set) var requests: [GenerateRequest] = []

    init(error: LumenError? = nil, gate: AgentGate? = nil) {
        self.error = error
        self.gate = gate
    }

    func generate(_ request: GenerateRequest) async throws -> EncodedImage {
        requests.append(request)
        await gate?.wait()
        await gate?.recordReturn(cancelled: Task.isCancelled)
        if let error { throw error }
        return Self.image
    }
}

private actor AgentHost: EditHost {
    struct RenderedCrop: Sendable {
        var rect: NormalizedRect
        var maxLongEdge: Int
    }

    private(set) var layers: [Layer] = []
    private(set) var previews: [Int] = []
    private(set) var crops: [RenderedCrop] = []
    private(set) var removed: [Layer.ID] = []
    private let applyGate: AgentGate?
    private let removeError: LumenError?

    init(applyGate: AgentGate? = nil, removeError: LumenError? = nil) {
        self.applyGate = applyGate
        self.removeError = removeError
    }

    func size() async -> PixelSize { PixelSize(width: 10, height: 10) }

    func render(maxLongEdge: Int) async throws -> EncodedImage {
        previews.append(maxLongEdge)
        return AgentPhoto.preview(layers: layers.count)
    }

    func render(region: NormalizedRect, maxLongEdge: Int) async throws -> EncodedImage {
        crops.append(RenderedCrop(rect: region, maxLongEdge: maxLongEdge))
        return AgentPhoto.crop
    }

    private(set) var fittedRegions: [NormalizedRect] = []

    func fitted(_ mask: MaskData, region: NormalizedRect) async throws -> MaskData {
        fittedRegions.append(region)
        return mask
    }

    func apply(_ layer: Layer, assets: AssetStore) async throws {
        layers.append(layer)
        await applyGate?.wait()
        await applyGate?.recordReturn(cancelled: Task.isCancelled)
    }

    func remove(_ layer: Layer.ID) async throws {
        if let removeError { throw removeError }
        removed.append(layer)
        layers.removeAll { $0.id == layer }
    }
}

private enum AgentPhoto {
    static func preview(layers: Int) -> EncodedImage {
        let images = [
            "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFElEQVR4nGMQERH5TwxmGFVIX4UABkJ7DV6H+GcAAAAASUVORK5CYII=",
            "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFElEQVR4nGPQ0ND4TwxmGFVIX4UA17iSfTwsfN8AAAAASUVORK5CYII=",
            "iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFElEQVR4nGOwsbH5TwxmGFVIX4UAqT2p7R6JOgIAAAAASUVORK5CYII=",
        ]
        return EncodedImage(data: Data(base64Encoded: images[min(layers, 2)])!, format: .png, size: PixelSize(width: 10, height: 10))
    }

    static let crop = EncodedImage(
        data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAGCAYAAAD+Bd/7AAAAEklEQVR4nGMICAj4jw8zDAUFALYLXNFb7LvbAAAAAElFTkSuQmCC")!,
        format: .png, size: PixelSize(width: 8, height: 6))
    static let generated = EncodedImage(
        data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAMCAYAAABr5z2BAAAAF0lEQVR4nGNISUn5TwlmGDVg1IDhYQAAm0OgUBCLqvQAAAAASUVORK5CYII=")!,
        format: .png, size: PixelSize(width: 16, height: 12))
}

/// Lets a fake model finish after its caller has been cancelled.
private actor AgentGate {
    private var entered = false
    private var released = false
    private var left = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var completionObservers: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func wait() async {
        entered = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        if !released { await withCheckedContinuation { waiting = $0 } }
    }

    func recordReturn(cancelled: Bool) {
        wasCancelled = cancelled
        left = true
        for observer in completionObservers { observer.resume() }
        completionObservers.removeAll()
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }

    func waitUntilLeft() async {
        if !left { await withCheckedContinuation { completionObservers.append($0) } }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}
