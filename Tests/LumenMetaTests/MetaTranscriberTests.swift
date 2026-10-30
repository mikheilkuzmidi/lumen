import Foundation
import LumenCore
import Synchronization
import Testing
@testable import LumenMeta

@Test func aSpokenInstructionIsSentAsAFormWithItsSettingsAndTheRecording() async throws {
    let transport = ReplayTransport([try .init(file: "transcript.json")])
    let transcriber = MetaTranscriber(configuration: testConfiguration, transport: transport)
    let wav = Data("RIFF-recorded-speech".utf8)
    let usage = Mutex<ModelUsage?>(nil)
    let transcript = try await ModelUsageReporting.$report.withValue({ value in usage.withLock { $0 = value } }) {
        try await transcriber.transcribe(wav: wav)
    }
    // The words as said, with "." for the ",." it ended them with; billed for one whole second of the 1.84 heard.
    #expect(transcript == Transcript(text: "make his jacket bright yellow.", seconds: 1))
    #expect(usage.withLock { $0?.cost } == 0.18 / 3_600)

    let call = try #require(await transport.requests.first)
    #expect(call.url?.absoluteString == "https://models.example/v1/asr/transcribe")
    #expect(call.httpMethod == "POST")
    #expect(call.value(forHTTPHeaderField: "Authorization") == "Bearer recorded-key")
    #expect(call.value(forHTTPHeaderField: "Accept") == "application/json")
    let type = try #require(call.value(forHTTPHeaderField: "Content-Type"))
    let boundary = try #require(type.components(separatedBy: "boundary=").last)
    #expect(type.hasPrefix("multipart/form-data; boundary="))
    let body = String(decoding: try #require(call.httpBody), as: UTF8.self)
    #expect(body == "--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n"
        + #"{"audioEncoding":"WAV","mode":"PUSH_TO_TALK","model":"muse-voice-transcribe-1.0"}"# + "\r\n"
        + "--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"audio\"; filename=\"instruction.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        + "RIFF-recorded-speech\r\n"
        + "--\(boundary)--\r\n")
}

@Test func aTranscriptKeepsItsLanguageAndOnlyLosesStrayPunctuation() {
    #expect(MetaTranscriber.tidy("  Сделай его куртку ярко-желтой.  ") == "Сделай его куртку ярко-желтой.")
    #expect(MetaTranscriber.tidy("make it warmer,") == "make it warmer")
    #expect(MetaTranscriber.tidy("make it warmer .") == "make it warmer.")
    #expect(MetaTranscriber.tidy("Make his jacket bright yellow..") == "Make his jacket bright yellow.")
    #expect(MetaTranscriber.tidy("") == "")
}

@Test func aTranscriptionWithoutAKeyOrRefusedSaysWhy() async throws {
    var configuration = testConfiguration
    configuration.apiKey = " "
    await #expect(throws: LumenError.missingKey) {
        try await MetaTranscriber(configuration: configuration, transport: ReplayTransport([])).transcribe(wav: Data())
    }
    let transport = ReplayTransport([.init(text: #"{"error":{"message":"Audio exceeds 10 minutes."}}"#, status: 400)])
    await #expect(throws: LumenError.http(status: 400, message: "Audio exceeds 10 minutes.")) {
        try await MetaTranscriber(configuration: testConfiguration, transport: transport).transcribe(wav: Data())
    }
}
