import Foundation
import LumenCore
import Testing
@testable import LumenMeta

@Test func batchReviewSendsFactsAndStrictSchemaAndRestoresPhotoOrder() async throws {
    let transport = ReplayTransport([try .init(file: "batch-review.json")])
    let planner = MetaBatchPlanner(configuration: testConfiguration, transport: transport)
    let photos = try batchPhotos()
    let reviews = try await planner.review(ReviewRequest(instruction: "Make their shirts blue", photos: photos))
    #expect(planner.modelID == "muse-spark-1.3")
    #expect(reviews == batchReviews)
    let call = try #require(await transport.requests.first)
    #expect(call.url?.absoluteString == "https://models.example/v1/chat/completions")
    #expect(call.httpMethod == "POST")
    #expect(call.value(forHTTPHeaderField: "Authorization") == "Bearer recorded-key")
    #expect(call.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try json(#require(call.httpBody))
    #expect(body["model"] as? String == "muse-spark-1.3")
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages[0]["content"] as? String == MetaBatchPlanner.reviewPrompt)
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(content.count == 2)
    let text = try #require(content[0]["text"] as? String)
    #expect(!text.contains("evening.jpg"))
    #expect(!text.contains("\n"))
    try expectJSON(Data(text.utf8), equals: ["instruction": "Make their shirts blue", "photos": [
        ["number": 1, "sharpness": 0.7, "exposure": 0.3, "clippedShadows": 0.01, "clippedHighlights": 0.02, "tilt": 2.0],
        ["number": 2, "sharpness": 0.01, "exposure": 0.01, "clippedShadows": 0.9, "clippedHighlights": 0.0, "tilt": NSNull()],
        ["number": 3, "sharpness": 0.9, "exposure": 0.5, "clippedShadows": 0.0, "clippedHighlights": 0.0, "tilt": -1.0],
    ]])
    let imageURL = try #require((content[1]["image_url"] as? [String: String])?["url"])
    #expect(imageURL.hasPrefix("data:image/jpeg;base64,"))
    let schema = try batchResponseSchema(body, name: "batch_review")
    try expectStrictBatchSchema(schema)
    let properties = try #require(schema["properties"] as? [String: Any])
    let array = try #require(properties["photos"] as? [String: Any])
    let item = try #require(array["items"] as? [String: Any])
    let fields = try #require(item["properties"] as? [String: [String: Any]])
    #expect(Set(fields.keys) == ["number", "misfire", "misfireReason", "quality", "description", "group", "matchesInstruction", "tilted"])
    #expect(fields["misfireReason"]?["type"] as? [String] == ["string", "null"])
    for rule in ["badly blurred", "black or almost black", "ground or a pocket", "closed eyes or motion blur",
                 "when a better one exists", "dark mood or a soft background is not a misfire", "0 is unusable, 1 needs nothing",
                 "same scene or subjects", "false when there is no instruction"] {
        #expect(MetaBatchPlanner.reviewPrompt.contains(rule))
    }
}

@Test func batchReviewWithoutInstructionNeverMatches() async throws {
    let transport = ReplayTransport([try .init(file: "batch-review.json")])
    let planner = MetaBatchPlanner(configuration: testConfiguration, transport: transport)
    let reviews = try await planner.review(ReviewRequest(instruction: nil, photos: batchPhotos()))
    #expect(reviews.allSatisfy { !$0.matchesInstruction })
    let context = try batchRequestContext(#require(await transport.requests.first))
    #expect(context["instruction"] is NSNull)
}

@Test func batchReviewRejectsMissingDuplicateAndUnknownNumbersAndInvalidQuality() async throws {
    let photos = try batchPhotos()
    for (numbers, expected) in [
        ([1, 2], "Missing photo number 3 in batch review."),
        ([1, 1, 3], "Duplicate photo number 1 in batch review."),
        ([1, 2, 4], "Unknown photo number 4; expected 1 through 3."),
        ([0, 2, 3], "Unknown photo number 0; expected 1 through 3."),
    ] {
        let reply = try batchCompletion(["photos": numbers.map { batchReviewAnswer(number: $0) }])
        let planner = MetaBatchPlanner(configuration: testConfiguration, transport: ReplayTransport([reply]))
        await #expect(throws: LumenError.invalidResponse(expected)) {
            try await planner.review(ReviewRequest(instruction: nil, photos: photos))
        }
    }
    // A quality a little past the range is clamped rather than losing the batch.
    let reply = try batchCompletion(["photos": [batchReviewAnswer(number: 1, quality: 1.1), batchReviewAnswer(number: 2),
                                                batchReviewAnswer(number: 3, quality: -0.05)]])
    let planner = MetaBatchPlanner(configuration: testConfiguration, transport: ReplayTransport([reply]))
    let reviews = try await planner.review(ReviewRequest(instruction: nil, photos: photos))
    #expect(reviews[0].quality == 1 && reviews[2].quality == 0)
}

@Test func batchReviewHandlesEmptyOversizedAndUnreadableSheetsWithoutTransport() async throws {
    let transport = ReplayTransport([])
    let planner = MetaBatchPlanner(configuration: testConfiguration, transport: transport)
    #expect(try await planner.review(ReviewRequest(instruction: nil, photos: [])) == [])
    let photo = try #require(batchPhotos().first)
    await #expect(throws: LumenError.invalidResponse("A contact sheet needs 1 through 20 photos.")) {
        try await planner.review(ReviewRequest(instruction: nil, photos: Array(repeating: photo, count: 21)))
    }
    let unreadable = ReviewPhoto(photo: PhotoID("broken"), thumbnail: testPhoto, facts: photo.facts)
    await #expect(throws: LumenError.invalidResponse("Could not decode photo 1 for the contact sheet.")) {
        try await planner.review(ReviewRequest(instruction: nil, photos: [unreadable]))
    }
    #expect(await transport.requests.isEmpty)
}

@Test func batchPlanSendsReviewsAndMapsGroupsAndQuestions() async throws {
    let transport = ReplayTransport([try .init(file: "batch-plan-questions.json")])
    var configuration = testConfiguration
    configuration.planningModel = "hosted-spark"
    configuration.timeout = 42
    let planner = MetaBatchPlanner(configuration: configuration, transport: transport)
    let plan = try await planner.plan(BatchPlanRequest(instruction: "Make their shirts blue", reviews: batchReviews))
    #expect(planner.modelID == "hosted-spark")
    #expect(plan.summary == "Make the friends' shirts blue")
    #expect(plan.groups == [BatchGroup(id: "friends", title: "Friends outdoors", photos: [batchReviews[2].photo, batchReviews[0].photo],
                                      instruction: "Make both friends' T-shirts royal blue, keeping each shirt's own cut and folds")])
    #expect(plan.questions == [BatchQuestion(id: "shirt-style", question: "Should their shirts keep their own style?",
                                            options: ["Keep each style in blue", "Give everyone the same shirt"],
                                            recommended: 0, groups: ["friends"])])
    let call = try #require(await transport.requests.first)
    #expect(call.timeoutInterval == 42)
    let body = try json(#require(call.httpBody))
    // Muse Wonder plans across the library; the reviewing model is still the configuration's.
    #expect(planner.planModelID == "muse-wonder-1.0")
    #expect(body["model"] as? String == "muse-wonder-1.0")
    try expectStrictBatchSchema(batchResponseSchema(body, name: "batch_plan"))
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages[0]["content"] as? String == MetaBatchPlanner.planPrompt)
    let content = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(content.count == 1)
    #expect(content[0]["type"] as? String == "text")
    let text = try #require(content[0]["text"] as? String)
    try expectJSON(Data(text.utf8), equals: ["instruction": "Make their shirts blue", "reviews": batchReviews.enumerated().map {
        ["number": $0.offset + 1, "description": $0.element.description, "group": $0.element.group,
         "likelyMatch": $0.element.matchesInstruction]
    }, "answers": [:]])
    for rule in ["person's choice", "two to four short options", "recommendation", "same shirt", "own style",
                 "small or partly hidden", "Never ask what the photos themselves can answer", "Make his T-shirt royal blue",
                 "With every answer given, the plan has no questions"] {
        #expect(MetaBatchPlanner.planPrompt.contains(rule))
    }
}

@Test func batchPlanUsesAnswersAndAcceptsNoQuestionsAndNullableInstructions() async throws {
    let transport = ReplayTransport([try .init(file: "batch-plan-answered.json")])
    let planner = MetaBatchPlanner(configuration: testConfiguration, transport: transport)
    let answers = ["shirt-style": "Keep each style in blue"]
    let plan = try await planner.plan(BatchPlanRequest(instruction: "Make their shirts blue", reviews: batchReviews, answers: answers))
    #expect(plan.questions.isEmpty)
    #expect(plan.groups.map(\.photos) == [[batchReviews[0].photo, batchReviews[2].photo], [batchReviews[1].photo]])
    #expect(plan.groups[1].instruction == nil)
    let context = try batchRequestContext(#require(await transport.requests.first))
    #expect(context["answers"] as? [String: String] == answers)
}

@Test func batchPlanRejectsUnknownAndDuplicatePhotoNumbers() async throws {
    for (numbers, expected) in [
        ([4], "Unknown photo number 4; expected 1 through 3."),
        ([1, 1], "Duplicate photo number 1 in batch plan groups."),
    ] {
        let reply = try batchCompletion(["summary": "Edit", "groups": [
            ["id": "friends", "title": "Friends", "photos": numbers, "instruction": NSNull()],
        ], "questions": []])
        let planner = MetaBatchPlanner(configuration: testConfiguration, transport: ReplayTransport([reply]))
        await #expect(throws: LumenError.invalidResponse(expected)) {
            try await planner.plan(BatchPlanRequest(instruction: "Blue shirts", reviews: batchReviews))
        }
    }
    let planner = MetaBatchPlanner(configuration: testConfiguration,
                                  transport: ReplayTransport([try .init(file: "batch-plan-questions.json")]))
    // A question already answered is dropped; the answer stands.
    let repeated = try await planner.plan(BatchPlanRequest(instruction: "Blue shirts", reviews: batchReviews,
                                                           answers: ["shirt-style": "Keep each style in blue"]))
    #expect(!repeated.questions.contains { $0.id == "shirt-style" })
}

@Test func batchCallsMapHTTPAndTransportFailuresLikePlanner() async throws {
    let photos = try batchPhotos()
    let replies: [(ReplayTransport.Reply, LumenError)] = [
        (.init(status: 401), .http(status: 401, message: "Check your Meta API key and its model access.")),
        (.init(status: 403), .http(status: 403, message: "Check your Meta API key and its model access.")),
        (.init(status: 402), .paymentRequired),
        (.init(status: 429, headers: ["retry-after": "12"]), .rateLimited(retryAfter: 12)),
        (.init(status: 429, headers: ["retry-after": "invalid"]), .rateLimited(retryAfter: nil)),
        (.init(text: #"{"error":{"message":"Try later."}}"#, status: 500), .http(status: 500, message: "Try later.")),
        (.init(failure: .timedOut), .timedOut),
        (.init(failure: .cancelled), .cancelled),
    ]
    for (reply, expected) in replies {
        let planner = MetaBatchPlanner(configuration: testConfiguration, transport: ReplayTransport([reply, reply]))
        await #expect(throws: expected) { try await planner.review(ReviewRequest(instruction: nil, photos: photos)) }
        await #expect(throws: expected) { try await planner.plan(BatchPlanRequest(instruction: "Blue", reviews: batchReviews)) }
    }
}

@Test func batchCallsPreserveRefusalsAndMalformedResponses() async throws {
    let photos = try batchPhotos()
    for (file, expected) in [("refusal.json", LumenError.refused("Cannot perform that edit.")),
                              ("malformed.json", .invalidResponse(#"{"summary": broken answer"#))] {
        let reply = try ReplayTransport.Reply(file: file)
        let planner = MetaBatchPlanner(configuration: testConfiguration, transport: ReplayTransport([reply, reply]))
        await #expect(throws: expected) { try await planner.review(ReviewRequest(instruction: nil, photos: photos)) }
        await #expect(throws: expected) { try await planner.plan(BatchPlanRequest(instruction: "Blue", reviews: batchReviews)) }
    }
}

@Test func batchCallsRejectMissingKeyAndCancellationBeforeTransport() async throws {
    let photos = try batchPhotos()
    let transport = ReplayTransport([])
    let missingKey = MetaBatchPlanner(configuration: MetaConfiguration(apiKey: " "), transport: transport)
    await #expect(throws: LumenError.missingKey) { try await missingKey.review(ReviewRequest(instruction: nil, photos: photos)) }
    await #expect(throws: LumenError.missingKey) {
        try await missingKey.plan(BatchPlanRequest(instruction: "Blue", reviews: batchReviews))
    }
    let planner = MetaBatchPlanner(configuration: testConfiguration, transport: transport)
    let review = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await planner.review(ReviewRequest(instruction: nil, photos: photos))
    }
    let plan = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await planner.plan(BatchPlanRequest(instruction: "Blue", reviews: batchReviews))
    }
    await #expect(throws: LumenError.cancelled) { try await review.value }
    await #expect(throws: LumenError.cancelled) { try await plan.value }
    #expect(await transport.requests.isEmpty)
}

let batchReviews = [
    PhotoReview(photo: PhotoID("evening.jpg"), misfire: false, quality: 0.7,
                description: "Two friends in evening light, red and grey T-shirts", group: "friends", matchesInstruction: true, tilted: false),
    PhotoReview(photo: PhotoID("pocket.jpg"), misfire: true, misfireReason: "Accidental pocket shot", quality: 0.05,
                description: "Black fabric close up", group: "pocket", matchesInstruction: false, tilted: false),
    PhotoReview(photo: PhotoID("daylight.jpg"), misfire: false, quality: 0.9,
                description: "Two friends outdoors, red and grey T-shirts", group: "friends", matchesInstruction: true, tilted: false),
]

func batchPhotos() throws -> [ReviewPhoto] {
    let photo = try recordedPhoto()
    let facts = [
        PhotoFacts(size: photo.size, sharpness: 0.7, exposure: 0.3, clippedShadows: 0.01, clippedHighlights: 0.02, tilt: 2),
        PhotoFacts(size: photo.size, sharpness: 0.01, exposure: 0.01, clippedShadows: 0.9),
        PhotoFacts(size: photo.size, sharpness: 0.9, exposure: 0.5, tilt: -1),
    ]
    return zip(batchReviews, facts).map { ReviewPhoto(photo: $0.photo, thumbnail: photo, facts: $1) }
}

private func batchRequestContext(_ call: URLRequest) throws -> [String: Any] {
    let body = try json(#require(call.httpBody))
    let messages = try #require(body["messages"] as? [[String: Any]])
    let parts = try #require(messages[1]["content"] as? [[String: Any]])
    return try json(Data(#require(parts[0]["text"] as? String).utf8))
}

private func batchResponseSchema(_ body: [String: Any], name: String) throws -> [String: Any] {
    let format = try #require(body["response_format"] as? [String: Any])
    #expect(format["type"] as? String == "json_schema")
    let schema = try #require(format["json_schema"] as? [String: Any])
    #expect(schema["name"] as? String == name)
    #expect(schema["strict"] as? Bool == true)
    let root = try #require(schema["schema"] as? [String: Any])
    #expect(root["type"] as? String == "object")
    return root
}

private func expectStrictBatchSchema(_ schema: [String: Any]) throws {
    #expect(schema["oneOf"] == nil)
    #expect(schema["allOf"] == nil)
    if schema["type"] as? String == "object" {
        #expect(schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(Set(try #require(schema["required"] as? [String])) == Set(properties.keys))
        for property in properties.values { try expectStrictBatchSchema(property) }
    }
    if let items = schema["items"] as? [String: Any] { try expectStrictBatchSchema(items) }
}

private func batchReviewAnswer(number: Int, quality: Double = 0.5) -> [String: Any] {
    ["number": number, "misfire": false, "misfireReason": NSNull(), "quality": quality,
     "description": "Friends", "group": "friends", "matchesInstruction": false, "tilted": false]
}

private func batchCompletion(_ answer: [String: Any]) throws -> ReplayTransport.Reply {
    let content = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    return .init(text: String(decoding: body, as: UTF8.self))
}
