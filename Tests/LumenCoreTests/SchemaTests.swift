import Foundation
import Testing
@testable import LumenCore

@Suite("Structured response schemas")
struct SchemaTests {
    @Test(arguments: [EditPlan.jsonSchema(), Critique.jsonSchema()])
    func everyObjectIsStrictAndNestingIsBounded(data: Data) throws {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["type"] as? String == "object")
        #expect(root["anyOf"] == nil)
        try checkStrictSchema(root)

        let properties = try #require(root["properties"] as? [String: Any])
        let steps = try #require(properties["steps"] as? [String: Any])
        let items = try #require(steps["items"] as? [String: Any])
        let choices = try #require(items["anyOf"] as? [[String: Any]])
        #expect(choices.count == 7)
        var types: [String] = []
        for choice in choices {
            let fields = try #require(choice["properties"] as? [String: Any])
            let type = try #require(fields["type"] as? [String: Any])
            let values = try #require(type["enum"] as? [String])
            #expect(type["type"] as? String == "string")
            #expect(values.count == 1)
            types += values
        }
        #expect(Set(types) == ["select", "adjust", "regenerate", "remove", "crop", "revert", "finish"])
    }

    @Test func nullableFieldsAndAdjustmentUnitsAreDescribed() throws {
        let root = try #require(JSONSerialization.jsonObject(with: EditPlan.jsonSchema()) as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["summary", "steps"])
        let steps = try #require(properties["steps"] as? [String: Any])
        let items = try #require(steps["items"] as? [String: Any])
        let choices = try #require(items["anyOf"] as? [[String: Any]])
        let select = try #require(choices[0]["properties"] as? [String: Any])
        #expect((select["concept"] as? [String: Any])?["type"] as? [String] == ["string", "null"])
        let box = try #require(select["box"] as? [String: Any])
        #expect(box["type"] as? [String] == ["object", "null"])
        #expect(Set((box["properties"] as? [String: Any])?.keys.map { $0 } ?? []) == ["x", "y", "width", "height"])
        let points = try #require(select["points"] as? [String: Any])
        let point = try #require(points["items"] as? [String: Any])
        #expect(Set((point["properties"] as? [String: Any])?.keys.map { $0 } ?? []) == ["x", "y"])

        let adjust = try #require(choices[1]["properties"] as? [String: Any])
        #expect((adjust["region"] as? [String: Any])?["type"] as? [String] == ["string", "null"])
        let values = try #require(adjust["values"] as? [String: Any])
        let settings = try #require(values["properties"] as? [String: Any])
        #expect(Set(settings.keys) == Set(AdjustmentKey.allCases.map(\.rawValue)))
        for key in AdjustmentKey.allCases {
            let setting = try #require(settings[key.rawValue] as? [String: Any])
            #expect(setting["type"] as? [String] == ["number", "null"])
            let description = try #require(setting["description"] as? String)
            #expect(description.contains(key == .exposure ? "stops" : "percent"))
            #expect(description.contains("\(key.range.lowerBound)...\(key.range.upperBound)"))
        }
    }

    @Test func aStrictPlanAnswerWithNullsDecodes() throws {
        let data = Data(Self.planAnswer.utf8)
        let plan = try JSONDecoder().decode(EditPlan.self, from: data)
        let expected = EditPlan(summary: "Darker sky and navy coat", steps: [
            .select(Selection(id: "sky", concept: "sky",
                              gradient: Gradient(from: NormalizedPoint(x: 1, y: 0.3), to: NormalizedPoint(x: 0.3, y: 0.7)),
                              every: true, colours: ["orange", "yellow"])),
            .select(Selection(id: "coat", box: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), points: [
                NormalizedPoint(x: 0.5, y: 0.5),
            ], invert: true, shadowTip: NormalizedPoint(x: 0.9, y: 0.8))),
            .adjust(Adjustment(values: [.exposure: -0.5, .saturation: 10])),
            .regenerate(Regeneration(region: "coat", prompt: "a navy wool coat")),
            .remove(Removal(region: "sky")),
            .crop(Crop(rect: .whole)),
            .finish(Finish(reason: "The requested changes are complete.")),
        ])
        #expect(plan == expected)
        #expect(plan.checked().notes.isEmpty)
        #expect(try JSONDecoder().decode(EditPlan.self, from: JSONEncoder().encode(plan)) == expected)
        let schema = try #require(JSONSerialization.jsonObject(with: EditPlan.jsonSchema()) as? [String: Any])
        #expect(matches(try JSONSerialization.jsonObject(with: data), schema: schema))
    }

    @Test func aStrictCritiqueAnswerDecodes() throws {
        let data = Data(#"{"satisfied":false,"notes":"The sky needs work.","steps":[{"type":"select","id":"sky","concept":null,"box":{"x":0,"y":0,"width":1,"height":0.5},"points":[],"invert":false,"gradient":null,"shadowTip":null,"every":false,"colours":[]}]}"#.utf8)
        let critique = try JSONDecoder().decode(Critique.self, from: data)
        #expect(critique == Critique(satisfied: false, notes: "The sky needs work.", steps: [
            .select(Selection(id: "sky", box: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5))),
        ]))
        let schema = try #require(JSONSerialization.jsonObject(with: Critique.jsonSchema()) as? [String: Any])
        #expect(Set((schema["properties"] as? [String: Any])?.keys.map { $0 } ?? []) == ["satisfied", "notes", "steps"])
        #expect(matches(try JSONSerialization.jsonObject(with: data), schema: schema))
    }

    @Test func aStrictRevertMatchesThePlanAndCritiqueSchemas() throws {
        let id = UUID().uuidString
        let plan: [String: Any] = ["summary": "Undo the sky", "steps": [["type": "revert", "layer": id]]]
        let critique: [String: Any] = ["satisfied": false, "notes": "Undo the sky", "steps": plan["steps"]!]
        for (answer, data) in [(plan, EditPlan.jsonSchema()), (critique, Critique.jsonSchema())] {
            let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(matches(answer, schema: schema))
        }
        let data = try JSONSerialization.data(withJSONObject: plan)
        #expect(try JSONDecoder().decode(EditPlan.self, from: data).steps == [.revert(Revert(layer: id))])
        let critiqueData = try JSONSerialization.data(withJSONObject: critique)
        #expect(try JSONDecoder().decode(Critique.self, from: critiqueData).steps == [.revert(Revert(layer: id))])
    }

    @Test(arguments: [
        #"{"id":"sky","concept":null,"box":null}"#,
        #"{"id":"sky","concept":null,"box":null,"points":null,"invert":null}"#,
    ])
    func missingSelectionDefaultsAreAccepted(json: String) throws {
        #expect(try JSONDecoder().decode(Selection.self, from: Data(json.utf8)) == Selection(id: "sky"))
    }

    @Test func allNullAdjustmentValuesDecodeAsEmpty() throws {
        let data = Data(#"{"region":null,"values":{"exposure":null,"contrast":null,"highlights":null,"shadows":null,"whites":null,"blacks":null,"temperature":null,"tint":null,"vibrance":null,"saturation":null,"highlightWarmth":null,"shadowWarmth":null,"clarity":null,"dehaze":null,"sharpness":null,"noiseReduction":null}}"#.utf8)
        #expect(try JSONDecoder().decode(Adjustment.self, from: data) == Adjustment(values: [:]))
    }

    private func checkStrictSchema(_ schema: [String: Any], depth: Int = 1) throws {
        #expect(depth <= 10)
        #expect(schema["$ref"] == nil)
        #expect(schema["oneOf"] == nil)
        #expect(schema["allOf"] == nil)
        let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map { [$0] } ?? []
        if types.contains("object") {
            #expect(schema["additionalProperties"] as? Bool == false)
            let properties = try #require(schema["properties"] as? [String: Any])
            let required = try #require(schema["required"] as? [String])
            #expect(Set(required) == Set(properties.keys))
            #expect(required.count == properties.count)
            for property in properties.values {
                try checkStrictSchema(try #require(property as? [String: Any]), depth: depth + 1)
            }
        }
        if let items = schema["items"] as? [String: Any] { try checkStrictSchema(items, depth: depth + 1) }
        if let choices = schema["anyOf"] as? [[String: Any]] {
            for choice in choices { try checkStrictSchema(choice, depth: depth) }
        }
        if !types.isEmpty && !types.contains("object") && !types.contains("array") {
            #expect(!(schema["description"] as? String ?? "").isEmpty)
        }
    }

    /// Checks the subset used by these response formats against a hand-built answer.
    private func matches(_ value: Any, schema: [String: Any]) -> Bool {
        if let choices = schema["anyOf"] as? [[String: Any]] {
            return choices.contains { matches(value, schema: $0) }
        }
        let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map { [$0] } ?? []
        if value is NSNull { return types.contains("null") }
        if let object = value as? [String: Any], types.contains("object"),
           let properties = schema["properties"] as? [String: [String: Any]],
           let required = schema["required"] as? [String] {
            return Set(object.keys) == Set(required) && object.allSatisfy { key, value in
                properties[key].map { matches(value, schema: $0) } ?? false
            }
        }
        if let array = value as? [Any], types.contains("array"), let items = schema["items"] as? [String: Any] {
            return array.allSatisfy { matches($0, schema: items) }
        }
        if let string = value as? String, types.contains("string") {
            return (schema["enum"] as? [String])?.contains(string) ?? true
        }
        if let number = value as? NSNumber {
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            return isBoolean ? types.contains("boolean") : types.contains("number")
        }
        return false
    }

    private static let planAnswer = #"""
    {
      "summary": "Darker sky and navy coat",
      "steps": [
        {"type":"select","id":"sky","concept":"sky","box":null,"points":[],"invert":false,"gradient":{"from":{"x":1,"y":0.3},"to":{"x":0.3,"y":0.7}},"shadowTip":null,"every":true,"colours":["orange","yellow"]},
        {"type":"select","id":"coat","concept":null,"box":{"x":0.25,"y":0.25,"width":0.5,"height":0.5},"points":[{"x":0.5,"y":0.5}],"invert":true,"gradient":null,"shadowTip":{"x":0.9,"y":0.8},"every":false,"colours":[]},
        {"type":"adjust","region":null,"values":{"exposure":-0.5,"contrast":null,"highlights":null,"shadows":null,"whites":null,"blacks":null,"temperature":null,"tint":null,"vibrance":null,"saturation":10,"highlightWarmth":null,"shadowWarmth":null,"clarity":null,"dehaze":null,"sharpness":null,"noiseReduction":null}},
        {"type":"regenerate","region":"coat","prompt":"a navy wool coat"},
        {"type":"remove","region":"sky"},
        {"type":"crop","rect":{"x":0,"y":0,"width":1,"height":1}},
        {"type":"finish","reason":"The requested changes are complete."}
      ]
    }
    """#
}
