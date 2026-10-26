// Vectors copied from https://github.com/meta-models/meta-sam/tree/main/conformance/cases.
// These vectors are under the SAM License; see Sources/LumenSAMMask/LICENSE.

struct MaskVector: Sendable {
    var name: String
    var height: Int
    var width: Int
    var payload: String
    var runs: [(UInt8, Int)]

    var raster: [UInt8] { runs.flatMap { [UInt8](repeating: $0.0, count: $0.1) } }
}

let maskVectors = [
    MaskVector(name: "compact-api-image-lossless", height: 2, width: 3,
               payload: #"~!!!!.!0^zlTde]:)]`W"#,
               runs: [(0, 2), (1, 2), (0, 1), (1, 1)]),
    MaskVector(name: "synthetic-image-chunking", height: 5, width: 5,
               payload: #"!!!!!(QO(0lu8?"#,
               runs: [(1, 1), (0, 2), (1, 1), (0, 3), (1, 2), (0, 6), (1, 1), (0, 1), (1, 4), (0, 3), (1, 1)]),
    MaskVector(name: "captured-api-image-lossless", height: 11, width: 11,
               payload: #"~!!!!r!kCq#$.pF[_cZIw.?wO3R8-&NJofiCI$_J0aA.1VC*YyK_'z*(LEG8!+H9evY.82Z-4.@C[.9C@T86o$3E=-&8w3W=]xS."#,
               runs: [(0, 4), (1, 2), (0, 7), (1, 7), (0, 3), (1, 9), (0, 2), (1, 9), (0, 1), (1, 22), (0, 1), (1, 10), (0, 1), (1, 10), (0, 1), (1, 9), (0, 3), (1, 8), (0, 5), (1, 3), (0, 4)])
]
