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
    let contextText = try #require(content[0]["text"] as? String)
    try expectJSON(Data(contextText.utf8), equals: ["instruction": "Darken the sky",
        "area": ["x": 0.1, "y": 0.2, "width": 0.6, "height": 0.5],
        "regions": [["id": "coat", "concept": "coat", "box": ["x": 0, "y": 0, "width": 1, "height": 1], "area": 0.2]],
        "done": ["Selected coat"],
        "layers": [["id": layer.id, "label": layer.label, "kind": "adjust", "region": "coat"]],
        "history": ["Darken the coat", "A little more"]])
    try expectJSON(#require(call.httpBody), equals: ["model": "muse-spark-1.3", "messages": [
        ["role": "system", "content": MetaPlanner.planPrompt],
        ["role": "user", "content": [["type": "text", "text": contextText],
                                    ["type": "image_url", "image_url": ["url": testPhoto.dataURL]]]],
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
                                                            layers: [layer]))
    #expect(critique == Critique(satisfied: true, notes: "The sky is darker and natural."))
    let call = try #require(await transport.requests.first)
    let body = try json(#require(call.httpBody))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    let text = try #require(content[0]["text"] as? String)
    try expectJSON(Data(text.utf8), equals: ["instruction": "Darken the sky", "regions": [], "done": [], "history": [],
        "layers": [["id": layer.id, "label": layer.label, "kind": "adjust", "region": "sky"]]])
    try expectJSON(#require(call.httpBody), equals: ["model": "muse-spark-1.3", "messages": [
        ["role": "system", "content": MetaPlanner.critiquePrompt],
        ["role": "user", "content": [["type": "text", "text": text], ["type": "text", "text": "Before"],
                                    ["type": "image_url", "image_url": ["url": testPhoto.dataURL]],
                                    ["type": "text", "text": "After"],
                                    ["type": "image_url", "image_url": ["url": after.dataURL]]]],
    ], "response_format": ["type": "json_schema", "json_schema": [
        "name": "critique", "schema": try JSONSerialization.jsonObject(with: Critique.jsonSchema()), "strict": true]]])
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
    let text = try #require(parts.first?["text"] as? String)
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
