import Foundation
import LumenCore
import LumenSAMMask

/// Turns image-frame records into masks in the photo's pixel space.
enum SAMSegments {
    struct PixelBox {
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int

        init(left: Int, top: Int, right: Int, bottom: Int) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        init(_ box: NormalizedRect, size: PixelSize) throws {
            let right = box.x + box.width, bottom = box.y + box.height
            guard [box.x, box.y, box.width, box.height, right, bottom].allSatisfy(\.isFinite),
                  box.width > 0, box.height > 0, size.width > 0, size.height > 0 else {
                throw MetaHTTP.invalid("Selection box must have finite, positive dimensions.")
            }
            self.left = Int(floor(min(1, max(0, box.x)) * Double(size.width)))
            self.top = Int(floor(min(1, max(0, box.y)) * Double(size.height)))
            self.right = Int(ceil((min(1, max(0, right)) * Double(size.width)).nextDown))
            self.bottom = Int(ceil((min(1, max(0, bottom)) * Double(size.height)).nextDown))
            guard self.left < self.right, self.top < self.bottom else {
                throw MetaHTTP.invalid("Selection box is outside the photo.")
            }
        }

        func contains(_ other: PixelBox) -> Bool {
            left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom
        }

        /// The share of `other`'s area that lies inside this box.
        func covered(_ other: PixelBox) -> Double {
            let width = max(0, min(right, other.right) - max(left, other.left))
            let height = max(0, min(bottom, other.bottom) - max(top, other.top))
            let area = (other.right - other.left) * (other.bottom - other.top)
            return area > 0 ? Double(width * height) / Double(area) : 0
        }
    }

    static func parse(_ text: String, request: SegmentRequest) throws -> [Segment] {
        let size = request.image.size
        let (area, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        guard size.width > 0, size.height > 0, !overflow, area > 0 else {
            throw MetaHTTP.invalid("The photo needs valid pixel dimensions.")
        }
        let boundary = try request.box.map { try PixelBox($0, size: size) }
        var segments: [Segment] = []
        var positions: [String: Int] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard line.hasPrefix("<") else { continue }
            guard let end = line.firstIndex(of: ">") else { throw MetaHTTP.invalid(line) }
            let marker = line[line.index(after: line.startIndex)..<end].split(separator: ";", omittingEmptySubsequences: false)[0]
            guard marker.hasSuffix("f"), let frame = integer(String(marker.dropLast()), signed: false), frame == 0 else {
                throw MetaHTTP.invalid(line)
            }
            var rest = line[line.index(after: end)...]
            guard !rest.isEmpty else { throw MetaHTTP.invalid(line) }
            while !rest.isEmpty {
                if rest.first == "," { rest = rest.dropFirst() }
                let digits = rest.prefix { $0.isASCII && $0 >= "0" && $0 <= "9" }
                guard !digits.isEmpty else { throw MetaHTTP.invalid(line) }
                let id = String(digits)
                rest = rest.dropFirst(digits.count)
                var boxToken: Token?
                var maskToken: Token?
                while rest.hasPrefix("<|") {
                    guard let close = rest.range(of: "|>") else { throw MetaHTTP.invalid(line) }
                    let token = try Token(String(rest.dropFirst(2)[..<close.lowerBound]))
                    rest = rest[close.upperBound...]
                    if token.name == "box" {
                        guard boxToken == nil else { throw MetaHTTP.invalid(line) }
                        boxToken = token
                    } else if token.name == "mask" {
                        guard maskToken == nil else { throw MetaHTTP.invalid(line) }
                        maskToken = token
                    }
                }
                guard let boxToken, let maskToken else { throw MetaHTTP.invalid(line) }
                let box = try boxToken.box(size: size)
                let raster = try maskToken.raster()
                // A box beside a concept says which of the things found is meant: most of it must lie inside.
                if request.concept != nil, let boundary, boundary.covered(box) < 0.5 { continue }
                let boxWidth = box.right - box.left, boxHeight = box.bottom - box.top
                let placed = MaskData(size: PixelSize(width: raster.width, height: raster.height),
                                      coverage: raster.values.map { $0 * 255 })
                    .resized(to: PixelSize(width: boxWidth, height: boxHeight))
                var coverage = [UInt8](repeating: 0, count: area)
                for y in box.top..<box.bottom {
                    let row = (y - box.top) * boxWidth
                    let start = y * size.width + box.left
                    coverage.replaceSubrange(start..<(start + boxWidth), with: placed.coverage[row..<(row + boxWidth)])
                }
                let normalized = NormalizedRect(x: Double(box.left) / Double(size.width),
                                                y: Double(box.top) / Double(size.height),
                                                width: Double(boxWidth) / Double(size.width),
                                                height: Double(boxHeight) / Double(size.height))
                let segment = Segment(label: request.concept ?? "", box: normalized,
                                      mask: MaskData(size: size, coverage: coverage), score: boxToken.confidence ?? maskToken.confidence)
                if let position = positions[id] { segments[position] = segment }
                else { positions[id] = segments.count; segments.append(segment) }
            }
        }
        return segments
    }

    static func integer(_ text: String, signed: Bool) -> Int? {
        var digits = text[...]
        if signed && digits.first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0 >= "0" && $0 <= "9" }),
              let value = Int(text), (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value) else { return nil }
        return value
    }

    private struct Token {
        var name: String
        var fields: [String: String] = [:]
        var confidence: Double?

        init(_ body: String) throws {
            let parts = body.split(separator: ";", omittingEmptySubsequences: false)
            name = String(parts[0])
            guard name.range(of: #"^[A-Za-z][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
                throw MetaHTTP.invalid("Malformed SAM token name.")
            }
            guard name == "box" || name == "mask" else { return }
            var confidenceCount = 0
            for part in parts.dropFirst() {
                let field = part.trimmingCharacters(in: .whitespaces)
                if field.isEmpty { continue }
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = pair[0].trimmingCharacters(in: .whitespaces)
                let value = pair.count == 2 ? pair[1].trimmingCharacters(in: .whitespaces) : ""
                if key == "c" {
                    confidenceCount += 1
                    if confidenceCount == 1,
                       value.range(of: #"^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                                   options: .regularExpression) != nil,
                       let score = Double(value), score.isFinite, (0...1).contains(score) {
                        confidence = score == 0 ? 0 : score
                    } else { confidence = nil }
                } else {
                    guard fields.updateValue(value, forKey: key) == nil else {
                        throw MetaHTTP.invalid("Repeated SAM field \(key).")
                    }
                }
            }
        }

        func number(_ key: String, signed: Bool = false) throws -> Int {
            guard let text = fields[key], let value = integer(text, signed: signed) else {
                throw MetaHTTP.invalid("Invalid SAM field \(key).")
            }
            return value
        }

        func box(size: PixelSize) throws -> PixelBox {
            let x1 = try number("x1", signed: true), y1 = try number("y1", signed: true)
            let x2 = try number("x2", signed: true), y2 = try number("y2", signed: true)
            let width = try number("w"), height = try number("h")
            guard width == size.width, height == size.height, x1 >= 0, y1 >= 0,
                  x2 >= x1, y2 >= y1, x2 < width, y2 < height else {
                throw MetaHTTP.invalid("SAM box is outside the photo or uses different pixel dimensions.")
            }
            return PixelBox(left: x1, top: y1, right: x2 + 1, bottom: y2 + 1)
        }

        func raster() throws -> (values: [UInt8], width: Int, height: Int) {
            guard try number("x") == 0, try number("y") == 0, let data = fields["data"] else {
                throw MetaHTTP.invalid("Invalid SAM mask origin or data.")
            }
            let parts = data.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let height = integer(String(parts[0]), signed: false),
                  let width = integer(String(parts[1]), signed: false) else {
                throw MetaHTTP.invalid("Invalid SAM mask dimensions.")
            }
            do {
                return (try SAMMask.decode(height: height, width: width, payload: String(parts[2])), width, height)
            } catch { throw MetaHTTP.invalid("Invalid SAM mask payload: \(error)") }
        }
    }
}
