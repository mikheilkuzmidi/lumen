import Foundation
import LumenCore
import Testing
@testable import LumenMeta

@Test func plannerSendsStrictChatRequestAndReadsPlan() async throws {
    let transport = ReplayTransport([try .init(file: "plan.json")])
    let planner = MetaPlanner(configuration: testConfiguration, transport: transport)
    let area = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
    let region = RegionInfo(id: "coat", concept: "coat", box: .whole, area: 0.2)
    let layer = LayerInfo(id: UUID().uuidString, label: "Coat: exposure −0.4", kind: "adjust", region: "coat")
    let plan = try await planner.plan(PlanRequest(instruction: "Darken the sky", image: testPhoto,
                                                area: area, regions: [region], done: ["Selected coat"],
                                                layers: [layer], history: ["Darken the coat", "A little more"]))
    #expect(plan.summary == "Darken the sky")
    #expect(plan.steps == [.select(Selection(id: "sky", concept: "sky")),
                           .adjust(Adjustment(region: "sky", values: [.exposure: -0.4])),
                           .finish(Finish(reason: "The sky is moodier."))])
    #expect(planner.modelID == "muse-spark-1.3")
    let call = try #require(await transport.requests.first)
    #expect(call.url?.absoluteString == "https://models.example/v1/chat/completions")
    #expect(call.httpMethod == "POST")
    #expect(call.value(forHTTPHeaderField: "Authorization") == "Bearer recorded-key")
    #expect(call.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try json(#require(call.httpBody))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    // The photo first, the changing text last, so the start of the prompt can be served from Meta's cache.
    let contextText = try #require(content.last?["text"] as? String)
    try expectJSON(Data(contextText.utf8), equals: ["instruction": "Darken the sky",
        "area": ["x": 0.1, "y": 0.2, "width": 0.6, "height": 0.5],
        "regions": [["id": "coat", "concept": "coat", "box": ["x": 0, "y": 0, "width": 1, "height": 1], "area": 0.2]],
        "done": ["Selected coat"],
        "layers": [["id": layer.id, "label": layer.label, "kind": "adjust", "region": "coat"]],
        "history": ["Darken the coat", "A little more"]])
    try expectJSON(#require(call.httpBody), equals: ["model": "muse-spark-1.3", "messages": [
        ["role": "system", "content": MetaPlanner.planPrompt],
        ["role": "user", "content": [["type": "image_url", "image_url": ["url": testPhoto.dataURL]],
                                    ["type": "text", "text": contextText]]],
    ], "response_format": ["type": "json_schema", "json_schema": [
        "name": "edit_plan", "schema": try JSONSerialization.jsonObject(with: EditPlan.jsonSchema()), "strict": true]]])
    for rule in ["conservative", "select", "adjust", "regenerate", "remove", "area", "select box", "lowercase", "Finish",
                 "history, oldest first", "reuse by id without selecting again", "not selected before",
                 "smaller adjustment to the same region", "undo that", "go back", "matching latest layer", "exact layer id"] {
        #expect(MetaPlanner.planPrompt.contains(rule))
    }
}

@Test func critiqueLabelsBothPhotosAndReadsAnswer() async throws {
    let transport = ReplayTransport([try .init(file: "critique.json")])
    let planner = MetaPlanner(configuration: testConfiguration, transport: transport)
    let after = EncodedImage(data: Data([4, 5]), format: .png, size: testPhoto.size)
    let layer = LayerInfo(id: UUID().uuidString, label: "Sky: exposure −0.4", kind: "adjust", region: "sky")
    let critique = try await planner.critique(CritiqueRequest(instruction: "Darken the sky", before: testPhoto, after: after,
                                                            layers: [layer], history: ["Make it warmer"]))
    #expect(critique == Critique(satisfied: true, notes: "The sky is darker and natural."))
    let call = try #require(await transport.requests.first)
    let body = try json(#require(call.httpBody))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    let text = try #require(content.last?["text"] as? String)
    try expectJSON(Data(text.utf8), equals: ["instruction": "Darken the sky", "regions": [], "done": [], "history": ["Make it warmer"],
        "layers": [["id": layer.id, "label": layer.label, "kind": "adjust", "region": "sky"]]])
    try expectJSON(#require(call.httpBody), equals: ["model": "muse-spark-1.3", "messages": [
        ["role": "system", "content": MetaPlanner.critiquePrompt],
        ["role": "user", "content": [["type": "text", "text": "Before"],
                                    ["type": "image_url", "image_url": ["url": testPhoto.dataURL]],
                                    ["type": "text", "text": "After"],
                                    ["type": "image_url", "image_url": ["url": after.dataURL]],
                                    ["type": "text", "text": text]]],
    ], "response_format": ["type": "json_schema", "json_schema": [
        "name": "critique", "schema": try JSONSerialization.jsonObject(with: Critique.jsonSchema()), "strict": true]]])
}

/// A smeared wheel is a few pixels of the whole photo: each redrawn region also goes to the critic close up.
@Test func critiqueShowsEachRedrawnRegionCloseUpAfterTheWholePhotos() async throws {
    let transport = ReplayTransport([try .init(file: "critique.json")])
    let planner = MetaPlanner(configuration: testConfiguration, transport: transport)
    let after = EncodedImage(data: Data([4, 5]), format: .png, size: testPhoto.size)
    let closeBefore = EncodedImage(data: Data([6]), format: .png, size: PixelSize(width: 4, height: 4))
    let closeAfter = EncodedImage(data: Data([7]), format: .png, size: PixelSize(width: 4, height: 4))
    _ = try await planner.critique(CritiqueRequest(instruction: "Make the bicycles yellow", before: testPhoto, after: after,
                                                   closeUps: [CloseUp(region: "bicycles", before: closeBefore, after: closeAfter)]))
    let body = try json(#require(await transport.requests.first?.httpBody))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    let labels = content.compactMap { $0["text"] as? String }.dropLast()
    #expect(Array(labels) == ["Before", "After", "Close-up of bicycles, before", "Close-up of bicycles, after"])
    let images = content.compactMap { ($0["image_url"] as? [String: String])?["url"] }
    #expect(images == [testPhoto.dataURL, after.dataURL, closeBefore.dataURL, closeAfter.dataURL])
    #expect(MetaPlanner.critiquePrompt.contains("a smeared wheel, a\nmelted edge or a changed neighbouring object is a visible flaw"))
}

@Test func theCriticReadsEachRegionsColourBeforeAndAfter() async throws {
    let transport = ReplayTransport([try .init(file: "critique.json")])
    let planner = MetaPlanner(configuration: testConfiguration, transport: transport)
    let cup = RegionChange(region: "cup", before: ColourMeasurement(lightness: 52.4, a: -14, b: -6),
                           after: ColourMeasurement(lightness: 30.2, a: -12.4, b: -5.1))
    _ = try await planner.critique(CritiqueRequest(instruction: "Make the cup matte black", before: testPhoto, after: testPhoto,
                                                   measurements: [cup]))
    let body = try json(#require(await transport.requests.first?.httpBody))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    let context = try json(Data(try #require(content.last?["text"] as? String).utf8))
    let measured = try #require((context["measurements"] as? [[String: Any]])?.first)
    #expect(measured["region"] as? String == "cup")
    #expect(measured["change"] as? Double == 22.3)
    let before = try #require(measured["before"] as? [String: Any])
    let after = try #require(measured["after"] as? [String: Any])
    #expect(before["lightness"] as? Int == 52 && before["chroma"] as? Int == 15 && before["hue"] as? Int == 203)
    #expect(after["lightness"] as? Int == 30 && after["colour"] as? String == "muted dark teal")
    #expect(MetaPlanner.critiquePrompt.contains("a region it names that changed by\n  less than 3 has not met it"))
    #expect(MetaPlanner.critiquePrompt.contains("so charcoal, dark grey or dark teal is not black"))

    // Without measurements, the context says nothing about them.
    let quiet = ReplayTransport([try .init(file: "critique.json")])
    _ = try await MetaPlanner(configuration: testConfiguration, transport: quiet)
        .critique(CritiqueRequest(instruction: "Make the cup matte black", before: testPhoto, after: testPhoto))
    let plain = try json(#require(await quiet.requests.first?.httpBody))
    let text = try #require(((plain["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])?.last?["text"] as? String)
    #expect(!text.contains("measurements"))
}

@Test func chatBuilderSupportsHostingProviders() throws {
    let builder = ChatCompletionRequestBuilder(baseURL: URL(string: "https://host.example/custom/v1/")!, apiKey: "host-key",
                                               model: "hosted-spark", extraHeaders: ["X-Deployment": "spark"], timeout: 42)
    let call = try builder.request(systemPrompt: "Edit carefully", content: [.text("Sky")], schemaName: "answer", schema: Data("{}".utf8))
    #expect(call.url?.absoluteString == "https://host.example/custom/v1/chat/completions")
    #expect(call.value(forHTTPHeaderField: "Authorization") == "Bearer host-key")
    #expect(call.value(forHTTPHeaderField: "X-Deployment") == "spark")
    #expect(call.timeoutInterval == 42)
    #expect(try json(#require(call.httpBody))["model"] as? String == "hosted-spark")
}

@Test func plannerAcceptsARevertAnswerWithDefaultMemory() async throws {
    let id = UUID().uuidString
    let answer: [String: Any] = ["summary": "Undo that", "steps": [["type": "revert", "layer": id]]]
    let content = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    let completion = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    let transport = ReplayTransport([.init(text: String(decoding: completion, as: UTF8.self))])
    let planner = MetaPlanner(configuration: testConfiguration, transport: transport)
    let plan = try await planner.plan(PlanRequest(instruction: "Undo that", image: testPhoto))
    #expect(plan.steps == [.revert(Revert(layer: id))])
    let call = try #require(await transport.requests.first)
    let body = try json(#require(call.httpBody))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let parts = try #require(messages[1]["content"] as? [[String: Any]])
    let text = try #require(parts.last?["text"] as? String)
    try expectJSON(Data(text.utf8), equals: ["instruction": "Undo that", "regions": [], "done": [], "layers": [], "history": []])
}

@Test func plannerPreservesRefusalsAndExcerptsMalformedContent() async throws {
    let refusal = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([try .init(file: "refusal.json")]))
    await #expect(throws: LumenError.refused("Cannot perform that edit.")) {
        try await refusal.plan(PlanRequest(instruction: "Edit", image: testPhoto))
    }
    let malformed = MetaPlanner(configuration: testConfiguration, transport: ReplayTransport([try .init(file: "malformed.json")]))
    await #expect(throws: LumenError.invalidResponse(#"{"summary": broken answer"#)) {
        try await malformed.plan(PlanRequest(instruction: "Edit", image: testPhoto))
    }
    let parts = Data(#"{"choices":[{"message":{"content":[{"type":"refusal","refusal":"Declined"}]}}]}"#.utf8)
    #expect(throws: LumenError.refused("Declined")) { try ChatCompletionRequestBuilder.decode(EditPlan.self, from: parts) }
    for content in [#"{"choices":[]}"#, #"{"choices":[{"message":{"content":null}}]}"#, "broken"] {
        #expect(throws: LumenError.self) { try ChatCompletionRequestBuilder.decode(EditPlan.self, from: Data(content.utf8)) }
    }
}
