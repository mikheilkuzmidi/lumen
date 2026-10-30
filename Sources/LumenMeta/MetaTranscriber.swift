import Foundation
import LumenCore

/// What was said, as Muse Voice Transcribe wrote it down.
public struct Transcript: Equatable, Sendable {
    public var text: String
    /// The whole seconds of audio heard, which is what is billed.
    public var seconds: Int

    public init(text: String, seconds: Int) {
        self.text = text
        self.seconds = seconds
    }
}

/// Muse Voice Transcribe writes down a spoken instruction in the language it was said, for the person to read and run.
public struct MetaTranscriber: Sendable {
    public let configuration: MetaConfiguration
    public let transport: any MetaTransport
    public var modelID: String { configuration.transcriptionModel }

    public init(configuration: MetaConfiguration, transport: any MetaTransport = RetryingMetaTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    /// `wav` is mono 16-bit PCM at 16 or 24 kHz, up to ten minutes, as `SpokenAudio` records it.
    public func transcribe(wav: Data) async throws -> Transcript {
        do {
            let call = try MetaHTTP.multipart(baseURL: configuration.baseURL, path: "asr/transcribe", key: configuration.apiKey,
                                              timeout: configuration.timeout, headers: ["Accept": "application/json"], parts: [
                .json(name: "request", ["mode": "PUSH_TO_TALK", "model": modelID, "audioEncoding": "WAV"]),
                .file(name: "audio", filename: "instruction.wav", type: "audio/wav", wav),
            ])
            let (data, response) = try await transport.data(for: call)
            try MetaHTTP.validate(response, data: data)
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
                throw MetaHTTP.invalid(String(decoding: data, as: UTF8.self))
            }
            let seconds = max(0, (answer.audioDurationMs ?? 0) / 1_000)
            ModelUsageReporting.report?(ModelUsage(cost: configuration.recordsCost ? MetaPricing.cost(model: modelID, audioSeconds: seconds) : nil))
            return Transcript(text: Self.tidy(answer.transcript), seconds: seconds)
        } catch { throw MetaHTTP.error(error) }
    }

    /// The words as said, without the ",." or ".." it sometimes ends a short sentence with.
    static func tidy(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while [",.", " .", ".."].contains(where: text.hasSuffix) { text.remove(at: text.index(text.endIndex, offsetBy: -2)) }
        if text.hasSuffix(",") { text.removeLast() }
        return text
    }

    private struct Answer: Decodable {
        var transcript: String
        var audioDurationMs: Int?
    }
}
