import Foundation
import LumenCore

/// SAM 3.1 finds things by words, a box or points.
public struct MetaSegmenter: Segmenter {
    public let configuration: MetaConfiguration
    public let transport: any MetaTransport
    public var modelID: String { configuration.segmentationModel }

    public init(configuration: MetaConfiguration, transport: any MetaTransport = URLSessionMetaTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// A concept is always searched for by name, which SAM answers best; a box beside it only chooses among
    /// what was found (most of a segment must lie inside it). Without a concept, the box and points are
    /// SAM's object prompts.
    public func segment(_ request: SegmentRequest) async throws -> [Segment] {
        try await segment(request, negativePoints: [])
    }

    /// Adds exclusion clicks while the shared point type represents positive clicks.
    public func segment(_ request: SegmentRequest, negativePoints: [NormalizedPoint]) async throws -> [Segment] {
        do {
            let text = try Self.prompt(request, negativePoints: negativePoints)
            var call = try MetaHTTP.request(baseURL: configuration.baseURL, path: "responses", key: configuration.apiKey,
                                            timeout: configuration.timeout, body: [
                "model": modelID, "stream": true, "metadata": ["include_confidence": "true"],
                "input": [["role": "user", "content": [
                    ["type": "input_text", "text": text],
                    ["type": "input_image", "image_url": request.image.dataURL],
                ]]],
            ])
            call.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (lines, response) = try await transport.lines(for: call)
            try MetaHTTP.validate(response)
            let answer = try await SAMResponseText.read(lines)
            try Task.checkCancellation()
            return try SAMSegments.parse(answer, request: request)
        } catch { throw MetaHTTP.error(error) }
    }

    static func prompt(_ request: SegmentRequest, negativePoints: [NormalizedPoint] = []) throws -> String {
        let size = request.image.size
        guard size.width > 0, size.height > 0 else { throw MetaHTTP.invalid("The photo needs positive pixel dimensions.") }
        if let concept = request.concept?.trimmingCharacters(in: .whitespacesAndNewlines), !concept.isEmpty {
            return concept
        }
        guard request.box != nil || !request.points.isEmpty || !negativePoints.isEmpty else {
            throw MetaHTTP.invalid("Selection needs a concept, box or point.")
        }
        var text = "<0f>1"
        let dimensions = "w=\(size.width);h=\(size.height)"
        if let box = request.box {
            let pixels = try SAMSegments.PixelBox(box, size: size)
            text += "<|box;x1=\(pixels.left);y1=\(pixels.top);x2=\(pixels.right - 1);y2=\(pixels.bottom - 1);\(dimensions)|>"
        }
        for (points, prefix) in [(request.points, ""), (negativePoints, "-")] {
            for point in points {
                guard point.x.isFinite, point.y.isFinite else { throw MetaHTTP.invalid("Selection points must be finite.") }
                let x = Int(floor(min(1, max(0, point.x)) * Double(size.width))).clamped(to: 0...(size.width - 1))
                let y = Int(floor(min(1, max(0, point.y)) * Double(size.height))).clamped(to: 0...(size.height - 1))
                text += "\(prefix)<|point;x=\(x);y=\(y);\(dimensions)|>"
            }
        }
        return text
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
