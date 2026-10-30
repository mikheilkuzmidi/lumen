import AVFoundation
import Foundation
import LumenCore
import LumenMeta
import Synchronization
import Testing
@testable import LumenVoice

@Test func aRecordingIsWrittenAsTheMonoSixteenKilohertzWAVMetaTakes() {
    let wav = SpokenAudio.wav([0, 1, -1, 32_767])
    #expect(wav.count == 44 + 8)
    #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
    func word(_ at: Int) -> Int { Int(wav[at]) | Int(wav[at + 1]) << 8 }
    func long(_ at: Int) -> Int { word(at) | word(at + 2) << 16 }
    #expect(long(4) == 36 + 8)
    #expect(word(20) == 1)        // PCM
    #expect(word(22) == 1)        // mono
    #expect(long(24) == 16_000)   // samples a second
    #expect(long(28) == 32_000)   // bytes a second
    #expect(word(34) == 16)       // bits a sample
    #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
    #expect(long(40) == 8)
    #expect(Array(wav[44...]) == [0, 0, 1, 0, 0xFF, 0xFF, 0xFF, 0x7F])
}

@Test func anyAudioFileBecomesSixteenKilohertzMono() throws {
    // A second of a 440 Hz tone in stereo at 44.1 kHz, as a voice memo or `say` would write something else.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-voice-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
    buffer.frameLength = 44_100
    for channel in 0..<2 {
        for frame in 0..<44_100 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.5) }
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    let wav = try SpokenAudio.wav(contentsOf: url)
    let samples = (wav.count - 44) / 2
    #expect(abs(samples - 16_000) <= 64)
    let values = stride(from: 44, to: wav.count - 1, by: 2).map { Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8) }
    #expect(SpokenAudio.level(Array(values[2_000..<14_000])) > 0.5)
    #expect(SpokenAudio.level([]) == 0)
}

/// Hands over what it was given to have heard.
final class HeardRecorder: VoiceRecording {
    private let state = Mutex<(samples: [Int16], started: Bool, stopped: Int)>(([], false, 0))
    init(seconds: Double) { state.withLock { $0.samples = Array(repeating: 1_000, count: Int(seconds * 16_000)) } }
    var started: Bool { state.withLock { $0.started } }
    var stops: Int { state.withLock { $0.stopped } }
    var level: Float { 0.4 }
    func start() throws { state.withLock { $0.started = true } }
    func stop() -> [Int16] { state.withLock { $0.stopped += 1; return $0.samples } }
}

@MainActor private func until(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@MainActor struct VoiceInstructionTests {
    @Test func whatWasSaidGoesToTheFieldAndNothingRuns() async throws {
        let recorder = HeardRecorder(seconds: 1.5)
        let sent = Mutex(0)
        let voice = VoiceInstruction(recorder: recorder, permission: { true }) { wav in
            sent.withLock { $0 = wav.count }
            return Transcript(text: "Сделай его куртку ярко-желтой.", seconds: 1)
        }
        var field: [String] = []
        voice.toggle { field.append($0) }
        try await until { recorder.started }
        #expect(voice.isRecording)
        voice.toggle { field.append($0) }
        try await until { voice.state == .idle }
        #expect(field == ["Сделай его куртку ярко-желтой."])
        #expect(sent.withLock { $0 } == 44 + 24_000 * 2)
        #expect(voice.lastCost == 0.18 / 3_600)
    }

    @Test func aClickAndAClickAgainIsNotAnInstruction() async throws {
        let recorder = HeardRecorder(seconds: 0.1)
        let voice = VoiceInstruction(recorder: recorder, permission: { true }) { _ in
            Issue.record("Nothing should be sent")
            return Transcript(text: "", seconds: 0)
        }
        voice.toggle { _ in Issue.record("Nothing should be heard") }
        try await until { recorder.started }
        voice.toggle { _ in }
        #expect(voice.failure?.hasPrefix("Nothing was heard") == true)
    }

    @Test func cancellingKeepsNothing() async throws {
        let recorder = HeardRecorder(seconds: 2)
        let voice = VoiceInstruction(recorder: recorder, permission: { true }) { _ in Transcript(text: "x", seconds: 1) }
        voice.toggle { _ in Issue.record("Nothing should be heard") }
        try await until { recorder.started }
        voice.cancel()
        #expect(voice.state == .idle)
        #expect(recorder.stops == 1)
    }

    @Test func noMicrophoneAccessNoKeyOrSilenceEachSaySo() async throws {
        let denied = VoiceInstruction(recorder: HeardRecorder(seconds: 1), permission: { false }) { _ in Transcript(text: "x", seconds: 1) }
        denied.toggle { _ in }
        try await until { denied.failure != nil }
        #expect(denied.failure?.contains("Microphone access is off") == true)

        for (error, words) in [(LumenError.missingKey, "Voice needs your Meta API key."), (LumenError.timedOut, "Couldn't write down")] {
            let recorder = HeardRecorder(seconds: 1)
            let voice = VoiceInstruction(recorder: recorder, permission: { true }) { _ in throw error }
            voice.toggle { _ in }
            try await until { recorder.started }
            voice.toggle { _ in }
            try await until { voice.failure != nil }
            #expect(voice.failure?.hasPrefix(words) == true)
            voice.dismissFailure()
            #expect(voice.state == .idle)
        }

        let recorder = HeardRecorder(seconds: 1)
        let silent = VoiceInstruction(recorder: recorder, permission: { true }) { _ in Transcript(text: "", seconds: 1) }
        silent.toggle { _ in Issue.record("Nothing should be heard") }
        try await until { recorder.started }
        silent.toggle { _ in }
        try await until { silent.failure != nil }
        #expect(silent.failure?.hasPrefix("Nothing was heard") == true)
    }
}
