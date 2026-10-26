// Decodes SAM 3.1 mask payloads. This target is a port of Meta's reference decoder
// (python/src/meta_sam_parser/_mask_codec.py in https://github.com/meta-models/meta-sam) and, unlike the rest of
// Lumen, is distributed under the SAM License; see LICENSE in this directory.

import Foundation

public enum SAMMask {
    public enum DecodeError: Error, Equatable, Sendable {
        case unsupportedEncoding
        case malformed(String)
    }

    /// The mask's raster, `height × width` values of 0 or 1 in rows from the top, from a mask token's
    /// `data=H,W,payload`.
    public static func decode(height: Int, width: Int, payload: String) throws -> [UInt8] {
        throw DecodeError.malformed("The decoder isn't ported yet.")
    }
}
