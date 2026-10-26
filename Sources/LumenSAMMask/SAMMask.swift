// Decodes SAM 3.1 mask payloads. This target is a port of Meta's reference decoder
// (python/src/meta_sam_parser/_mask_codec.py in https://github.com/meta-models/meta-sam) and, unlike the rest of
// Lumen, is distributed under the SAM License; see LICENSE in this directory.
// Copyright (c) Meta Platforms, Inc. and affiliates. All Rights Reserved.

import Foundation

public enum SAMMask {
    public enum DecodeError: Error, Equatable, Sendable {
        case unsupportedEncoding
        case malformed(String)
    }

    /// The mask's raster, `height × width` values of 0 or 1 in rows from the top, from a mask token's
    /// `data=H,W,payload`.
    public static func decode(height: Int, width: Int, payload: String) throws -> [UInt8] {
        guard let marker = payload.utf8.first, marker == 33 || marker == 126 else {
            throw DecodeError.unsupportedEncoding
        }
        let safe = 9_007_199_254_740_991
        guard width > 0, height > 0, width <= safe, height <= safe else {
            throw DecodeError.malformed("Mask dimensions must be positive safe integers.")
        }
        guard width <= safe / height else {
            throw DecodeError.malformed("Mask dimensions produce an unsafe decoded area.")
        }
        let packed = try unpack(Array(payload.utf8.dropFirst()))
        if marker == 126 {
            return try lossless(packed, width: width, height: height).map { $0 >= 129 ? 1 : 0 }
        }
        return try oneBit(packed, width: width, height: height)
    }
}

private extension SAMMask {
    static let alphabet = Array("!#$%&'()*+-./0123456789:=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmnopqrstuvwxyz{".utf8)
    static let wordMask = 0xFFFF_FFFF
    static let top = 1 << 24
    static let bottom = 1 << 16

    static func pack(_ bytes: [UInt8]) -> [UInt8] {
        var length = bytes.count
        var output = [UInt8](repeating: 0, count: 5)
        for index in stride(from: 4, through: 0, by: -1) {
            output[index] = alphabet[length % 85]
            length /= 85
        }
        for start in stride(from: 0, to: bytes.count, by: 4) {
            let count = min(4, bytes.count - start)
            var value = 0
            for index in 0..<4 {
                value = (value << 8) | (index < count ? Int(bytes[start + index]) : 0)
            }
            var digits = [UInt8](repeating: 0, count: 5)
            for index in stride(from: 4, through: 0, by: -1) {
                digits[index] = alphabet[value % 85]
                value /= 85
            }
            output.append(contentsOf: digits.prefix(count == 4 ? 5 : count + 1))
        }
        return output
    }

    static func unpack(_ payload: [UInt8]) throws -> [UInt8] {
        func digit(_ byte: UInt8) throws -> Int {
            guard let value = alphabet.firstIndex(of: byte) else {
                throw DecodeError.malformed("Mask payload contains an invalid character.")
            }
            return value
        }
        guard payload.count >= 5 else { throw DecodeError.malformed("Mask payload is missing its length prefix.") }
        var length = 0
        for byte in payload.prefix(5) { length = try length * 85 + digit(byte) }
        let remainder = length % 4
        let expected = 5 + length / 4 * 5 + (remainder == 0 ? 0 : remainder + 1)
        guard payload.count == expected else {
            throw DecodeError.malformed("Mask payload length does not match its prefix.")
        }
        var output: [UInt8] = []
        output.reserveCapacity(length)
        var source = 5
        while output.count < length {
            let count = min(4, length - output.count)
            var value = 0
            for index in 0..<5 {
                value = try value * 85 + (count == 4 || index < count + 1 ? digit(payload[source + index]) : 84)
            }
            guard value <= wordMask else { throw DecodeError.malformed("Mask payload contains an out-of-range group or tail.") }
            for index in 0..<count { output.append(UInt8((value >> (24 - index * 8)) & 255)) }
            source += count == 4 ? 5 : count + 1
        }
        guard pack(output) == payload else { throw DecodeError.malformed("Mask payload is not in canonical form.") }
        return output
    }

    struct RangeDecoder {
        var input: [UInt8]
        var position = 4
        var low = 0
        var range = wordMask
        var code = 0
        var scaled = 0

        init(_ input: [UInt8]) throws {
            guard input.count >= 4 else { throw DecodeError.malformed("Mask payload is missing its finalization.") }
            self.input = input
            for byte in input.prefix(4) { code = (code << 8) | Int(byte) }
        }

        mutating func frequency(_ total: Int) throws -> Int {
            scaled = range / total
            guard scaled != 0 else { throw DecodeError.malformed("Mask payload has invalid coding state.") }
            return min(total - 1, ((code - low) & wordMask) / scaled)
        }

        mutating func decode(_ cumulative: Int, _ frequency: Int) throws {
            low = (low + scaled * cumulative) & wordMask
            range = scaled * frequency
            while true {
                if low ^ ((low + range) & wordMask) < top {
                    // The leading byte is settled.
                } else if range < bottom {
                    range = (-low & wordMask) & (bottom - 1)
                } else {
                    break
                }
                guard position < input.count else { throw DecodeError.malformed("Mask payload ended before decoding completed.") }
                code = ((code << 8) | Int(input[position])) & wordMask
                position += 1
                low = (low << 8) & wordMask
                range = (range << 8) & wordMask
            }
        }
    }

    /// Reconstructs the coded bytes only to validate one-bit finalization.
    struct CanonicalBytes {
        var low = 0
        var range = wordMask
        var output: [UInt8] = []

        mutating func append(_ cumulative: Int, _ frequency: Int, _ total: Int) {
            let scaled = range / total
            low = (low + scaled * cumulative) & wordMask
            range = scaled * frequency
            while true {
                if low ^ ((low + range) & wordMask) < top {
                    // The leading byte is settled.
                } else if range < bottom {
                    range = (-low & wordMask) & (bottom - 1)
                } else {
                    break
                }
                output.append(UInt8((low >> 24) & 255))
                low = (low << 8) & wordMask
                range = (range << 8) & wordMask
            }
        }

        mutating func finish() -> [UInt8] {
            for _ in 0..<4 {
                output.append(UInt8((low >> 24) & 255))
                low = (low << 8) & wordMask
            }
            return output
        }
    }

    static func oneBit(_ packed: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        var decoder = try RangeDecoder(packed)
        var canonical = CanonicalBytes()
        var counts = [Int](repeating: 1, count: 8192)
        let stride = width + 4
        var padded = [UInt8](repeating: 0, count: stride * (height + 2))
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let position = (y + 2) * stride + 2 + x
                let prior = position - stride
                let earlier = prior - stride
                let positions = [position - 1, position - 2, prior - 2, prior - 1, prior, prior + 1, prior + 2,
                                 earlier - 2, earlier - 1, earlier, earlier + 1, earlier + 2]
                var context = 0
                for (shift, index) in positions.enumerated() { context |= Int(padded[index]) << shift }
                let offset = context << 1
                let zero = counts[offset]
                let one = counts[offset + 1]
                let bit = try decoder.frequency(zero + one) < zero ? 0 : 1
                let cumulative = bit == 0 ? 0 : zero
                let frequency = bit == 0 ? zero : one
                try decoder.decode(cumulative, frequency)
                canonical.append(cumulative, frequency, zero + one)
                padded[position] = UInt8(bit)
                output[y * width + x] = UInt8(bit)
                counts[offset + bit] += 14
                if counts[offset] + counts[offset + 1] >= 4096 {
                    counts[offset] = max(1, counts[offset] >> 1)
                    counts[offset + 1] = max(1, counts[offset + 1] >> 1)
                }
            }
        }
        guard canonical.finish() == packed else {
            throw DecodeError.malformed("Mask payload is not canonical or has invalid finalization.")
        }
        return output
    }

    static func prediction(_ output: [UInt8], offset: Int, x: Int, y: Int, mode: Int, width: Int) throws -> Int {
        guard (0..<5).contains(mode) else { throw DecodeError.malformed("Lossless mask payload uses an invalid predictor.") }
        let left = x > 0 ? Int(output[offset - 1]) : 0
        let up = y > 0 ? Int(output[offset - width]) : 0
        if mode == 1 { return up }
        if mode == 2 { return left }
        if mode == 3 { return (left + up) >> 1 }
        let corner = x > 0 && y > 0 ? Int(output[offset - width - 1]) : 0
        if mode == 0 {
            let estimate = left + up - corner
            let a = abs(estimate - left), b = abs(estimate - up), c = abs(estimate - corner)
            if a <= b && a <= c { return left }
            return b <= c ? up : corner
        }
        if corner >= max(left, up) { return min(left, up) }
        if corner <= min(left, up) { return max(left, up) }
        return left + up - corner
    }

    static func lossless(_ packed: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        guard packed.count >= 5 else { throw DecodeError.malformed("Lossless mask payload is truncated.") }
        let selector = Int(packed[0])
        var decoder = try RangeDecoder(Array(packed.dropFirst()))
        let length = width * height
        var output = [UInt8](repeating: 0, count: length)
        var residuals = [Int](repeating: 0, count: length)
        var zeroCounts = [Int](repeating: 1, count: 32)
        var orderOne = [Int](repeating: 1, count: 256 * 256)
        var orderOneTotals = [Int](repeating: 256, count: 256)
        var orderZero = [Int](repeating: 2, count: 256)
        var orderZeroTotal = 512
        var orderTwo: [Int: [Int]] = [:]
        var previous = 0
        for offset in 0..<length {
            let x = offset % width, y = offset / width
            let left = x > 0 ? (residuals[offset - 1] == 0 ? 1 : 0) : 1
            let up = y > 0 ? (residuals[offset - width] == 0 ? 1 : 0) : 1
            let corner = x > 0 && y > 0 ? (residuals[offset - width - 1] == 0 ? 1 : 0) : 1
            let right = y > 0 && x < width - 1 ? (residuals[offset - width + 1] == 0 ? 1 : 0) : 1
            let zeroOffset = (left | (up << 1) | (corner << 2) | (right << 3)) << 1
            let zero = zeroCounts[zeroOffset], nonzero = zeroCounts[zeroOffset + 1]
            let bit = try decoder.frequency(zero + nonzero) < zero ? 0 : 1
            try decoder.decode(bit == 0 ? 0 : zero, bit == 0 ? zero : nonzero)
            zeroCounts[zeroOffset + bit] += 32
            if zeroCounts[zeroOffset] + zeroCounts[zeroOffset + 1] >= 16384 {
                zeroCounts[zeroOffset] = max(1, zeroCounts[zeroOffset] >> 1)
                zeroCounts[zeroOffset + 1] = max(1, zeroCounts[zeroOffset + 1] >> 1)
            }
            var symbol = 0
            if bit == 1 {
                let above = offset >= width ? residuals[offset - width] : 0
                let key = (previous << 8) | above
                var second = orderTwo.removeValue(forKey: key) ?? [Int](repeating: 0, count: 257)
                let first = previous << 8
                let excluded = second[0] + orderOne[first] + orderZero[0]
                let total = second[256] + orderOneTotals[previous] + orderZeroTotal - excluded
                let target = try decoder.frequency(total)
                var cumulative = 0
                symbol = 1
                var frequency = second[1] + orderOne[first + 1] + orderZero[1]
                while cumulative + frequency <= target {
                    cumulative += frequency
                    symbol += 1
                    guard symbol < 256 else { throw DecodeError.malformed("Lossless mask payload is malformed.") }
                    frequency = second[symbol] + orderOne[first + symbol] + orderZero[symbol]
                }
                try decoder.decode(cumulative, frequency)
                second[symbol] += 616
                second[256] += 616
                if second[256] >= 50176 {
                    for value in 0..<256 { second[value] >>= 1 }
                    second[256] = second.prefix(256).reduce(0, +)
                }
                orderTwo[key] = second
                orderOne[first + symbol] += 56
                orderOneTotals[previous] += 56
                if orderOneTotals[previous] >= 8192 {
                    var total = 0
                    for value in 0..<256 {
                        orderOne[first + value] = max(1, orderOne[first + value] >> 1)
                        total += orderOne[first + value]
                    }
                    orderOneTotals[previous] = total
                }
                orderZero[symbol] += 32
                orderZeroTotal += 32
                if orderZeroTotal >= 4096 {
                    for value in 0..<256 { orderZero[value] >>= 1 }
                    orderZeroTotal = orderZero.reduce(0, +)
                }
            }
            residuals[offset] = symbol
            let predicted = try prediction(output, offset: offset, x: x, y: y, mode: selector, width: width)
            let delta = symbol & 1 != 0 ? -((symbol + 1) >> 1) : symbol >> 1
            output[offset] = UInt8((predicted + delta) & 255)
            previous = symbol
        }
        return output
    }
}
