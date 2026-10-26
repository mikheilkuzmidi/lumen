import Foundation
import ImageIO
import LumenCore
import Testing
@testable import LumenMeta

let testConfiguration = MetaConfiguration(apiKey: "recorded-key", baseURL: URL(string: "https://models.example/v1")!)
let testPhoto = EncodedImage(data: Data([1, 2, 3]), format: .jpeg, size: PixelSize(width: 10, height: 6))
let losslessMask = #"~!!!!.!0^zlTde]:)]`W"#
let oneBitMask = "!!!!!(QO(0lu8?"

func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

func expectJSON(_ data: Data, equals expected: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) throws {
    let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary
    #expect(actual == NSDictionary(dictionary: expected), sourceLocation: sourceLocation)
}

func recordedPhoto() throws -> EncodedImage {
    let reply = try ReplayTransport.Reply(file: "image.json")
    let entry = try #require((json(reply.body)["data"] as? [[String: String]])?.first)
    let base64 = try #require(entry["b64_json"])
    let data = try #require(Data(base64Encoded: base64))
    return EncodedImage(data: data, format: .png, size: PixelSize(width: 2, height: 1))
}

func sse(_ events: [[String: Any]]) throws -> String {
    try events.map { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) + "\n\n" }.joined()
}

func laneEvent(_ type: String, _ values: [String: Any] = [:]) -> [String: Any] {
    ["type": type, "item_id": "selection", "output_index": 0, "content_index": 0].merging(values) { _, value in value }
}

func readEvents(_ events: [[String: Any]]) async throws -> String {
    let lines = try sse(events).components(separatedBy: "\n")
    return try await SAMResponseText.read(AsyncThrowingStream { continuation in
        for line in lines { continuation.yield(line) }
        continuation.finish()
    })
}

func segmentLine(box: String = "x1=2;y1=1;x2=7;y2=4;w=10;h=6", mask: String? = nil) -> String {
    "<0f>7<|box;\(box)|><|mask;x=0;y=0;data=2,3,\(mask ?? losslessMask)|>"
}
