import Foundation
import LumenCore
import Testing
@testable import LumenMeta

@Test func segmenterSendsConceptAndMapsRasterIntoBox() async throws {
    let transport = ReplayTransport([try .init(file: "sam.sse")])
    let segmenter = MetaSegmenter(configuration: testConfiguration, transport: transport)
    let segments = try await segmenter.segment(SegmentRequest(image: testPhoto, concept: "red coat"))
    let segment = try #require(segments.first)
    #expect(segments.count == 1)
    #expect(segment.label == "red coat")
    #expect(segment.box == NormalizedRect(x: 0.2, y: 1.0 / 6, width: 0.6, height: 4.0 / 6))
    #expect(segment.score == 0.75)
    #expect(segment.mask.size == testPhoto.size)
    let rows: [[UInt8]] = [
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 255, 255, 0, 0],
        [0, 0, 0, 0, 0, 0, 255, 255, 0, 0],
        [0, 0, 255, 255, 0, 0, 255, 255, 0, 0],
        [0, 0, 255, 255, 0, 0, 255, 255, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    ]
    #expect(segment.mask.coverage == rows.flatMap { $0 })
    let call = try #require(await transport.requests.first)
    #expect(call.url?.absoluteString == "https://models.example/v1/responses")
    #expect(call.httpMethod == "POST")
    #expect(call.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    try expectJSON(#require(call.httpBody), equals: [
        "model": "sam-3.1", "stream": true, "metadata": ["include_confidence": "true"],
        "input": [["role": "user", "content": [["type": "input_text", "text": "red coat"],
                                                ["type": "input_image", "image_url": testPhoto.dataURL]]]],
    ])
}

@Test func segmenterUsesPixelObjectPromptsAndFiltersOutsideSegments() async throws {
    let transport = ReplayTransport([try .init(file: "sam.sse")])
    let segmenter = MetaSegmenter(configuration: testConfiguration, transport: transport)
    let request = SegmentRequest(image: testPhoto, concept: "coat",
                                 box: NormalizedRect(x: 0.2, y: 0, width: 0.4, height: 1),
                                 points: [NormalizedPoint(x: 1, y: -0.2)])
    let segments = try await segmenter.segment(request, negativePoints: [NormalizedPoint(x: 0.3, y: 0.5)])
    #expect(segments.isEmpty)
    let call = try #require(await transport.requests.first)
    let body = try json(#require(call.httpBody))
    let content = try #require((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
    #expect(content[0]["text"] as? String == "<0f>1<|box;x1=2;y1=0;x2=5;y2=5;w=10;h=6|><|point;x=9;y=0;w=10;h=6|>-<|point;x=3;y=3;w=10;h=6|>")
    let contained = SegmentRequest(image: testPhoto, concept: "coat", box: .whole)
    #expect(try SAMSegments.parse(segmentLine(), request: contained).count == 1)
}

@Test func promptSupportsPointsAndWholePhotoEdges() throws {
    let image = EncodedImage(data: Data(), format: .png, size: PixelSize(width: 640, height: 480))
    #expect(try MetaSegmenter.prompt(SegmentRequest(image: image, box: .whole)) == "<0f>1<|box;x1=0;y1=0;x2=639;y2=479;w=640;h=480|>")
    #expect(try MetaSegmenter.prompt(SegmentRequest(image: image, points: [NormalizedPoint(x: 0.5, y: 0.5)])) == "<0f>1<|point;x=320;y=240;w=640;h=480|>")
    #expect(throws: LumenError.self) { try MetaSegmenter.prompt(SegmentRequest(image: image)) }
    #expect(throws: LumenError.self) { try MetaSegmenter.prompt(SegmentRequest(image: image, box: NormalizedRect(x: 2, y: 0, width: 1, height: 1))) }
    #expect(throws: LumenError.self) { try MetaSegmenter.prompt(SegmentRequest(image: image, points: [NormalizedPoint(x: .nan, y: 0)])) }
}

@Test func samRecordsAllowEitherTokenOrderOptionalCommasAndUnknownFields() throws {
    let box = "<|box; x1 = -0 ;y1=0;x2=9;y2=5;w=10;h=6;future=value;hidden;=5;c=7.5e-1|>"
    let mask = "<|mask; y = 0 ;x=0;;data=2,3,\(losslessMask);|>"
    let text = "<0f;future=1>,10\(mask)<|future_token;a=1|>\(box)42\(box)\(mask),999\(box)\(mask)<|marker|>"
    let segments = try SAMSegments.parse(text, request: SegmentRequest(image: testPhoto, concept: "coat"))
    #expect(segments.count == 3)
    #expect(segments.allSatisfy { $0.box == .whole && $0.score == 0.75 })
    #expect(segments[0].mask[0, 0] == 0)
    #expect(segments[0].mask[9, 5] == 255)
}

@Test func samConfidenceIsOptionalAndInvalidConfidenceDoesNotDropMask() throws {
    for confidence in ["", ";c=not-a-number", ";c", ";c=0.7;c=0.7", ";c=2", ";c=NaN", ";c=+1", ";c=1e999"] {
        let text = segmentLine(box: "x1=2;y1=1;x2=7;y2=4;w=10;h=6" + confidence)
        let segment = try #require(SAMSegments.parse(text, request: SegmentRequest(image: testPhoto)).first)
        #expect(segment.score == nil)
    }
    let text = "<0f>7<|box;x1=2;y1=1;x2=7;y2=4;w=10;h=6;c=2|><|mask;x=0;y=0;c=.25;data=2,3,\(losslessMask)|>"
    #expect(try SAMSegments.parse(text, request: SegmentRequest(image: testPhoto)).first?.score == 0.25)
}

@Test func samRejectsMalformedRecordsAndMasks() {
    let boxes = ["x1=2;y1=1;x2=7;y2=4;w=10", "x1=2;x1=2;y1=1;x2=7;y2=4;w=10;h=6",
                 "x1=+2;y1=1;x2=7;y2=4;w=10;h=6", "x1=2.0;y1=1;x2=7;y2=4;w=10;h=6",
                 "x1=2;y1=1;x2=10;y2=4;w=10;h=6", "x1=8;y1=1;x2=7;y2=4;w=10;h=6",
                 "x1=2;y1=1;x2=7;y2=4;w=20;h=6"]
    for box in boxes {
        #expect(throws: LumenError.self) { try SAMSegments.parse(segmentLine(box: box), request: SegmentRequest(image: testPhoto)) }
    }
    let valid = segmentLine()
    for text in ["<0f>", valid + ",", valid.replacingOccurrences(of: "<0f>", with: "<1f>"),
                 valid.replacingOccurrences(of: ">7<|", with: ">coat<|"), valid + "junk",
                 valid.replacingOccurrences(of: "x=0;y=0;data", with: "x=1;y=0;data"),
                 valid.replacingOccurrences(of: "data=2,3,", with: "data=0,3,"), segmentLine(mask: "!!!!!") ] {
        #expect(throws: LumenError.self) { try SAMSegments.parse(text, request: SegmentRequest(image: testPhoto)) }
    }
}

@Test func samAcceptsEmptyAnswersAndReplacesRepeatedObjectMasks() throws {
    #expect(try SAMSegments.parse("", request: SegmentRequest(image: testPhoto)).isEmpty)
    let text = segmentLine() + "\n" + segmentLine(box: "x1=0;y1=0;x2=2;y2=1;w=10;h=6")
    let segments = try SAMSegments.parse(text, request: SegmentRequest(image: testPhoto))
    #expect(segments.count == 1)
    #expect(segments[0].box == NormalizedRect(x: 0, y: 0, width: 0.3, height: 2.0 / 6))
}

@Test func samDecodesOneBitMask() throws {
    let line = "<0f>0<|mask;x=0;y=0;data=5,5,\(oneBitMask)|><|box;x1=0;y1=0;x2=4;y2=4;w=10;h=6|>"
    let mask = try #require(SAMSegments.parse(line, request: SegmentRequest(image: testPhoto)).first?.mask)
    #expect(mask[0, 0] == 255)
    #expect(mask[1, 0] == 0)
    #expect(mask[4, 4] == 255)
    #expect(mask[5, 4] == 0)
}

/// A real SAM 3.1 answer for "jacket" on a 512 × 768 photo of a man in a black hooded jacket, recorded on
/// October 26, 2026: one object, box (169, 305)–(409, 767) inclusive, confidence 0.82, a lossless mask the
/// size of the box.
@Test func aRecordedSAMAnswerDecodesIntoTheJacketsMask() async throws {
    let transport = ReplayTransport([try .init(file: "sam-live-jacket.sse")])
    let segmenter = MetaSegmenter(configuration: testConfiguration, transport: transport)
    let photo = EncodedImage(data: Data([0xff, 0xd8]), format: .jpeg, size: PixelSize(width: 512, height: 768))
    let segments = try await segmenter.segment(SegmentRequest(image: photo, concept: "jacket"))
    let jacket = try #require(segments.first)
    #expect(segments.count == 1)
    #expect(abs(jacket.box.x - 169.0 / 512) < 1e-9 && abs(jacket.box.width - 241.0 / 512) < 1e-9)
    #expect(abs(jacket.box.y - 305.0 / 768) < 1e-9 && abs(jacket.box.height - 463.0 / 768) < 1e-9)
    #expect(abs((jacket.score ?? 0) - 0.8242) < 0.001)
    #expect(jacket.mask.size == photo.size)
    // The jacket fills much of its box and nothing outside it.
    var inside = 0, outside = 0
    for y in 0..<768 { for x in 0..<512 where jacket.mask[x, y] > 127 {
        if (169...409).contains(x) && (305...767).contains(y) { inside += 1 } else { outside += 1 }
    } }
    #expect(outside == 0)
    #expect(Double(inside) / Double(241 * 463) > 0.4, "\(inside) of \(241 * 463)")
}
