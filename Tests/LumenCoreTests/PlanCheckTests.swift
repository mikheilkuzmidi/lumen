import Foundation
import Testing
@testable import LumenCore

@Suite("Plan checking")
struct PlanCheckTests {
    @Test func revertsNeedKnownLayersAndCannotRepeat() {
        let id = UUID().uuidString
        let plan = EditPlan(summary: "Undo the sky", steps: [
            .revert(Revert(layer: "missing")),
            .revert(Revert(layer: " \n\(id)\t")),
            .revert(Revert(layer: id)),
            .revert(Revert(layer: "")),
            .adjust(Adjustment(region: "sky", values: [.exposure: 0.1])),
        ])
        let checked = plan.checked(knownRegions: ["sky"], knownLayers: [id])
        #expect(checked.plan.steps == [
            .revert(Revert(layer: id)),
            .adjust(Adjustment(region: "sky", values: [.exposure: 0.1])),
        ])
        #expect(checked.notes.filter { $0.contains("unknown layer") }.count == 3)
        #expect(checked.notes.contains { $0.contains("trimmed layer reference") })
        #expect(checked.plan.checked(knownRegions: ["sky"], knownLayers: [id]).notes.isEmpty)
        #expect(EditPlan(summary: "Undo", steps: [.revert(Revert(layer: id))]).checked().plan.steps.isEmpty)
    }

    @Test(arguments: AdjustmentKey.allCases)
    func adjustmentsStayWithinTheirRanges(key: AdjustmentKey) {
        let checked = EditPlan(summary: "Develop", steps: [
            .adjust(Adjustment(values: [key: key.range.lowerBound - 1])),
            .adjust(Adjustment(values: [key: key.range.upperBound + 1])),
        ]).checked()

        #expect(checked.plan.steps == [
            .adjust(Adjustment(values: [key: key.range.lowerBound])),
            .adjust(Adjustment(values: [key: key.range.upperBound])),
        ])
        #expect(checked.notes.count == 2)
        #expect(checked.notes.allSatisfy { $0.contains("clamped \(key.rawValue)") })
        #expect(checked.plan.checked().notes.isEmpty)
    }

    @Test func nonFiniteValuesAndEmptyAdjustmentsAreDropped() {
        let checked = EditPlan(summary: "Develop", steps: [
            .adjust(Adjustment(values: [.exposure: .nan, .contrast: .infinity, .shadows: -.infinity, .tint: 20])),
            .adjust(Adjustment(values: [.sharpness: .nan])),
            .adjust(Adjustment(values: [:])),
        ]).checked()

        #expect(checked.plan.steps == [.adjust(Adjustment(values: [.tint: 20]))])
        #expect(checked.notes.filter { $0.contains("dropped non-finite") }.count == 4)
        #expect(checked.notes.filter { $0.contains("dropped adjustment with no values") }.count == 2)
    }

    @Test func gradientsAreHeldToThePhotoAndMustFallAcrossIt() {
        let light = Gradient(from: NormalizedPoint(x: 1.2, y: 0.3), to: NormalizedPoint(x: 0.3, y: 0.7))
        let short = Gradient(from: NormalizedPoint(x: 0.5, y: 0.5), to: NormalizedPoint(x: 0.51, y: 0.5))
        let checked = EditPlan(summary: "Golden hour", steps: [
            .select(Selection(id: "sun", gradient: light)),
            .select(Selection(id: "edge", gradient: short)),
            .select(Selection(id: "sky", concept: "sky", gradient: short)),
            .adjust(Adjustment(region: "sun", values: [.exposure: 0.3])),
        ]).checked()
        #expect(checked.plan.steps == [
            .select(Selection(id: "sun", gradient: Gradient(from: NormalizedPoint(x: 1, y: 0.3), to: NormalizedPoint(x: 0.3, y: 0.7)))),
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sun", values: [.exposure: 0.3])),
        ])
        #expect(checked.notes.contains { $0.contains("clamped the gradient") })
        #expect(checked.notes.filter { $0.contains("too short") }.count == 2)
        #expect(checked.notes.contains { $0.contains("no usable concept, box, points or gradient") })
    }

    @Test func rectanglesAreClippedToThePhoto() {
        let outside = NormalizedRect(x: -0.25, y: 0.75, width: 0.75, height: 0.5)
        let inside = NormalizedRect(x: 0, y: 0.75, width: 0.5, height: 0.25)
        let checked = EditPlan(summary: "Crop and select", steps: [
            .crop(Crop(rect: outside)),
            .select(Selection(id: "subject", box: outside)),
            .crop(Crop(rect: NormalizedRect(x: -2, y: -1, width: 4, height: 3))),
        ]).checked()

        #expect(checked.plan.steps == [
            .crop(Crop(rect: inside)),
            .select(Selection(id: "subject", box: inside)),
            .crop(Crop(rect: .whole)),
        ])
        #expect(checked.notes.count == 3)
        #expect(checked.notes.allSatisfy { $0.contains("clamped rectangle") })
        #expect(checked.plan.checked().notes.isEmpty)
    }

    @Test(arguments: [
        NormalizedRect(x: 1.5, y: 0, width: 0.5, height: 1),
        NormalizedRect(x: 0, y: -2, width: 1, height: 1),
        NormalizedRect(x: 0, y: 0, width: 0, height: 1),
        NormalizedRect(x: 0, y: 0, width: 1, height: -1),
        NormalizedRect(x: 0, y: 1, width: 1, height: 0.25),
    ])
    func emptyRectanglesAreDropped(rect: NormalizedRect) {
        let checked = EditPlan(summary: "Crop and select", steps: [
            .crop(Crop(rect: rect)),
            .select(Selection(id: "sky", concept: "sky", box: rect)),
        ]).checked()

        #expect(checked.plan.steps == [.select(Selection(id: "sky", concept: "sky"))])
        #expect(checked.notes.count == 2)
        #expect(checked.notes.allSatisfy { $0.contains("dropped rectangle empty after clamping") })
    }

    @Test func nonFiniteGeometryIsDropped() {
        let checked = EditPlan(summary: "Select", steps: [
            .crop(Crop(rect: NormalizedRect(x: .nan, y: 0, width: 1, height: 1))),
            .select(Selection(id: "coat", concept: "coat", box: NormalizedRect(x: 0, y: 0, width: .infinity, height: 1), points: [
                NormalizedPoint(x: .nan, y: 0), NormalizedPoint(x: 0, y: -.infinity),
            ])),
        ]).checked()

        #expect(checked.plan.steps == [.select(Selection(id: "coat", concept: "coat"))])
        #expect(checked.notes.filter { $0.contains("dropped non-finite rectangle") }.count == 2)
        #expect(checked.notes.filter { $0.contains("dropped non-finite point") }.count == 2)
    }

    @Test func pointsAreClampedAndInvertIsKept() {
        let checked = EditPlan(summary: "Select", steps: [
            .select(Selection(id: "coat", points: [
                NormalizedPoint(x: -0.5, y: 1.5), NormalizedPoint(x: 2, y: -1),
                NormalizedPoint(x: 0.5, y: 0.25),
            ], invert: true)),
        ]).checked()

        #expect(checked.plan.steps == [.select(Selection(id: "coat", points: [
            NormalizedPoint(x: 0, y: 1), NormalizedPoint(x: 1, y: 0), NormalizedPoint(x: 0.5, y: 0.25),
        ], invert: true))])
        #expect(checked.notes.count == 2)
        #expect(checked.notes.allSatisfy { $0.contains("clamped point") })
    }

    @Test func promptsAreTrimmedAndCappedAtWholeCharacters() {
        let longPrompt = String(repeating: "🧑🏽‍🎨", count: 501)
        let capped = String(repeating: "🧑🏽‍🎨", count: 500)
        let checked = EditPlan(summary: "Redraw", steps: [
            .select(Selection(id: "coat", concept: " \n\(longPrompt)\t ")),
            .regenerate(Regeneration(region: "coat", prompt: " \t\(longPrompt)\n")),
        ]).checked()

        #expect(checked.plan.steps == [
            .select(Selection(id: "coat", concept: capped)),
            .regenerate(Regeneration(region: "coat", prompt: capped)),
        ])
        #expect(checked.notes.filter { $0.contains("trimmed surrounding whitespace") }.count == 2)
        #expect(checked.notes.filter { $0.contains("shortened prompt to 500 characters") }.count == 2)
    }

    @Test(arguments: ["", " \n\t "])
    func blankPromptsAreDropped(prompt: String) {
        let checked = EditPlan(summary: "Select", steps: [
            .select(Selection(id: "box", concept: prompt, box: .whole)),
            .select(Selection(id: "empty", concept: prompt)),
            .regenerate(Regeneration(region: "box", prompt: prompt)),
            .remove(Removal(region: "empty")),
        ]).checked()

        #expect(checked.plan.steps == [.select(Selection(id: "box", box: .whole))])
        #expect(checked.notes.filter { $0.contains("dropped empty prompt") }.count == 3)
        #expect(checked.notes.contains { $0.contains("dropped selection with no usable") })
        #expect(checked.notes.contains { $0.contains("dropped regeneration with no prompt") })
        #expect(checked.notes.contains { $0.contains("unknown region \"empty\"") })
    }

    @Test func shorteningDoesNotLeaveTrailingWhitespace() {
        let prompt = String(repeating: "a", count: 499) + " more"
        let checked = EditPlan(summary: "Redraw", steps: [
            .regenerate(Regeneration(region: "coat", prompt: prompt)),
        ]).checked(knownRegions: ["coat"])

        #expect(checked.plan.steps == [.regenerate(Regeneration(region: "coat", prompt: String(repeating: "a", count: 499)))])
        #expect(checked.notes.contains { $0.contains("shortened prompt") })
        #expect(checked.notes.contains { $0.contains("trimmed whitespace after shortening") })
        #expect(checked.plan.checked(knownRegions: ["coat"]).notes.isEmpty)
    }

    @Test func aSelectionNeedsAUsablePrompt() {
        let checked = EditPlan(summary: "Select", steps: [
            .select(Selection(id: "missing")),
            .select(Selection(id: "outside", box: NormalizedRect(x: 2, y: 0, width: 1, height: 1))),
            .select(Selection(id: "invalid", points: [NormalizedPoint(x: .infinity, y: 0)])),
        ]).checked()

        #expect(checked.plan.steps.isEmpty)
        #expect(checked.notes.filter { $0.contains("dropped selection with no usable") }.count == 3)
    }

    @Test func referencesNeedAnEarlierSelection() {
        let checked = EditPlan(summary: "Sky", steps: [
            .adjust(Adjustment(region: "sky", values: [.exposure: 1])),
            .regenerate(Regeneration(region: "sky", prompt: "clouds")),
            .remove(Removal(region: "sky")),
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: 1])),
            .adjust(Adjustment(values: [.contrast: 5])),
        ]).checked()

        #expect(checked.plan.steps == [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: 1])),
            .adjust(Adjustment(values: [.contrast: 5])),
        ])
        #expect(checked.notes.count == 3)
        #expect(checked.notes.allSatisfy { $0.contains("unknown region \"sky\"") })
    }

    @Test func regionsFromEarlierPlansAreAvailable() {
        let plan = EditPlan(summary: "Keep editing", steps: [
            .adjust(Adjustment(region: "sky", values: [.exposure: -1])),
            .regenerate(Regeneration(region: "coat", prompt: "navy coat")),
            .remove(Removal(region: "person")),
        ])
        let checked = plan.checked(knownRegions: ["sky", "coat", "person"])
        #expect(checked.plan == plan)
        #expect(checked.notes.isEmpty)
    }

    @Test func regionIDsAreTrimmedAndEmptyIDsAreDropped() {
        let checked = EditPlan(summary: "Sky", steps: [
            .select(Selection(id: " \n\t", concept: "sky")),
            .select(Selection(id: " sky ", concept: "sky")),
            .adjust(Adjustment(region: " sky\n", values: [.exposure: -1])),
            .remove(Removal(region: "")),
        ]).checked()

        #expect(checked.plan.steps == [
            .select(Selection(id: "sky", concept: "sky")),
            .adjust(Adjustment(region: "sky", values: [.exposure: -1])),
        ])
        #expect(checked.notes.contains { $0.contains("empty region id") })
        #expect(checked.notes.contains { $0.contains("trimmed region id") })
        #expect(checked.notes.contains { $0.contains("trimmed region reference") })
        #expect(checked.notes.contains { $0.contains("unknown region \"\"") })
    }

    @Test func duplicateIDsAreRenamedAndLaterReferencesFollowThem() {
        let checked = EditPlan(summary: "Two coats", steps: [
            .select(Selection(id: "coat", concept: "left coat")),
            .remove(Removal(region: "coat")),
            .select(Selection(id: "coat", concept: "right coat")),
            .adjust(Adjustment(region: "coat", values: [.saturation: 10])),
            .regenerate(Regeneration(region: "coat", prompt: "navy coat")),
        ]).checked(knownRegions: ["coat", "coat-2"])

        #expect(checked.plan.steps == [
            .select(Selection(id: "coat-3", concept: "left coat")),
            .remove(Removal(region: "coat-3")),
            .select(Selection(id: "coat-4", concept: "right coat")),
            .adjust(Adjustment(region: "coat-4", values: [.saturation: 10])),
            .regenerate(Regeneration(region: "coat-4", prompt: "navy coat")),
        ])
        #expect(checked.notes.filter { $0.contains("renamed duplicate region") }.count == 2)
        #expect(checked.notes.filter { $0.contains("updated region reference") }.count == 3)
        #expect(checked.plan.checked(knownRegions: ["coat", "coat-2"]).notes.isEmpty)
    }

    @Test func aNewSelectionDoesNotChangeEarlierReferencesToKnownRegions() {
        let checked = EditPlan(summary: "Another sky region", steps: [
            .adjust(Adjustment(region: "sky", values: [.exposure: -1])),
            .select(Selection(id: "sky", concept: "clouds")),
            .remove(Removal(region: "sky")),
        ]).checked(knownRegions: ["sky"])

        #expect(checked.plan.steps == [
            .adjust(Adjustment(region: "sky", values: [.exposure: -1])),
            .select(Selection(id: "sky-2", concept: "clouds")),
            .remove(Removal(region: "sky-2")),
        ])
        #expect(checked.notes.count == 2)
    }

    @Test func onlyTheFirstFinishIsKeptAndMovedLast() {
        let checked = EditPlan(summary: "Develop", steps: [
            .finish(Finish(reason: "First reason")),
            .adjust(Adjustment(values: [.exposure: -1])),
            .finish(Finish(reason: "Second reason")),
            .adjust(Adjustment(values: [.contrast: 10])),
        ]).checked()

        #expect(checked.plan.steps == [
            .adjust(Adjustment(values: [.exposure: -1])),
            .adjust(Adjustment(values: [.contrast: 10])),
            .finish(Finish(reason: "First reason")),
        ])
        #expect(checked.notes.contains { $0.contains("dropped extra finish") })
        #expect(checked.notes.contains("Moved the finish step to the end."))
        #expect(checked.plan.checked().notes.isEmpty)
    }

    @Test func aValidPlanNeedsNoChanges() {
        let plan = EditPlan(summary: "Sky", steps: [
            .select(Selection(id: "sky", concept: "sky", box: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), points: [
                NormalizedPoint(x: 0, y: 1),
            ])),
            .adjust(Adjustment(region: "sky", values: [.exposure: -5, .contrast: 100, .sharpness: 0])),
            .regenerate(Regeneration(region: "sky", prompt: "darker clouds")),
            .finish(Finish(reason: "Done")),
        ])

        #expect(plan.checked() == CheckedPlan(plan: plan, notes: []))
        #expect(EditPlan(summary: "No changes", steps: []).checked().plan.steps.isEmpty)
    }
}
