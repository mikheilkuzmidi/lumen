import Testing
@testable import LumenSAMMask

@Test func decodesConformanceRasters() throws {
    for vector in maskVectors {
        let raster = try SAMMask.decode(height: vector.height, width: vector.width, payload: vector.payload)
        #expect(raster == vector.raster, "\(vector.name)")
    }
}

@Test func rejectsInvalidEnvelopes() {
    let malformed = ["!", "!!!!!", "!!!!!%{{{{{", "!!!!!#{{", "!!!!!#!!", "!!!!!#!#",
                     "!!!!!$!!!!", "!!!!!(QO(0lu8?|", "!!!!!(QO(0lu8?!", "~!!!!%!!!!!"]
    for payload in malformed {
        #expect(throws: SAMMask.DecodeError.self) { try SAMMask.decode(height: 5, width: 5, payload: payload) }
    }
    #expect(throws: SAMMask.DecodeError.unsupportedEncoding) { try SAMMask.decode(height: 1, width: 1, payload: "rle") }
}

@Test func rejectsInvalidDimensions() {
    for (height, width) in [(0, 1), (1, -1), (1, Int.max), (2, 9_007_199_254_740_991)] {
        #expect(throws: SAMMask.DecodeError.self) { try SAMMask.decode(height: height, width: width, payload: "!!!!!(QO(0lu8?") }
    }
}

@Test func rejectsInvalidFinalizationAndPredictors() {
    let payloads = [
        #"!!!!!%!!!!"#,
        #"!!!!!'QO(0lu*"#,
        #"!!!!!)QO(0lu8?8"#,
        #"~!!!!.#h8QqTde]:)]`W"#
    ]
    for payload in payloads {
        #expect(throws: SAMMask.DecodeError.self) { try SAMMask.decode(height: 5, width: 5, payload: payload) }
    }
}

@Test func acceptsLosslessFinalizationVariants() throws {
    let payloads = [
        #"~!!!!/!0^zlTde]:)]`W["#,
        #"~!!!!.!0^zlTde[y)]`W"#
    ]
    for payload in payloads {
        #expect(try SAMMask.decode(height: 2, width: 3, payload: payload) == [0, 0, 1, 1, 0, 1])
    }
}
