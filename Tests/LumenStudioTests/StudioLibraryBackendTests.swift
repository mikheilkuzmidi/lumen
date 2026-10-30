import Foundation
import LumenCore
import LumenMeta
import LumenOpen
import Testing
@testable import LumenStudio

@Suite("Library backends")
struct StudioLibraryBackendTests {
    @MainActor @Test(arguments: StudioScript.Backend.allCases)
    func reviewerUsesTheSelectedPlannersEndpoint(backend: StudioScript.Backend) throws {
        let local = URL(string: "http://127.0.0.1:8786/v1")!
        let provider = try StudioProvider(baseURL: "https://provider.example/v1", key: "test-provider-key", modelID: "hosted-spark")
        let models = try StudioModels.configured(backend: backend, metaKey: "test-meta-key", glimmerURL: local, provider: provider)
        let reviewer = try #require(models.reviewer as? MetaBatchPlanner)
        #expect(reviewer.modelID == models.planner.modelID)
        switch backend {
        case .meta:
            #expect(reviewer.configuration.baseURL.absoluteString == "https://api.meta.ai/v1")
            #expect(reviewer.configuration.apiKey == "test-meta-key")
        case .glimmer: #expect(reviewer.configuration.baseURL == local)
        case .sparkOpen:
            #expect(reviewer.configuration.baseURL == provider.baseURL)
            #expect(reviewer.configuration.apiKey == "test-provider-key")
        }
    }

    @Test func localLibraryReviewAndPlanUseTheDocumentedResponsesWithoutAKey() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.remove() }
        let transport = LibraryRecordedTransport()
        let reviewer = MetaBatchPlanner(configuration: MetaConfiguration(apiKey: "local-glimmer",
            baseURL: URL(string: "http://127.0.0.1:8786/v1")!, planningModel: "muse-glimmer"),
            transport: GlimmerChatTransport(transport: transport))
        let photo = fixture.photos[0]
        let image = try await fixture.host.thumbnail(photo, maxLongEdge: 512)
        let reviews = try await reviewer.review(ReviewRequest(instruction: "Blue shirts",
            photos: [ReviewPhoto(photo: photo, thumbnail: image, facts: LibraryFixture.facts)]))
        #expect(reviews.count == 1 && reviews[0].photo == photo)
        let plan = try await reviewer.plan(BatchPlanRequest(instruction: "Blue shirts", reviews: reviews))
        #expect(plan.groups.first?.photos == [photo])
        #expect(plan.groups.first?.instruction == "Make the shirt blue")
        let requests = await transport.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.path == "/v1/chat/completions")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            // llama-server 0.7 constrains only to the nested schema: given it directly, Glimmer answered freely.
            let format = try #require(json["response_format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
            let wrapper = try #require(format["json_schema"] as? [String: Any])
            let schema = try #require(wrapper["schema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
        }
        // A review names its photo before it describes it.
        let review = String(decoding: try #require(requests.first?.httpBody), as: UTF8.self)
        #expect(review.contains(#""properties":{"number":{"#))
    }
}

private actor LibraryRecordedTransport: MetaTransport {
    private(set) var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let content = requests.count == 1 ? #"{"photos":[{"number":1,"misfire":false,"misfireReason":null,"quality":0.8,"description":"Friends outdoors","group":"people","matchesInstruction":true}]}"#
            : #"{"summary":"Blue shirts","groups":[{"id":"people","title":"Friends","photos":[1],"instruction":"Make the shirt blue"}],"questions":[]}"#
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return (data, try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        throw LumenError.invalidResponse("The library reviewer should use a complete response.")
    }
}
