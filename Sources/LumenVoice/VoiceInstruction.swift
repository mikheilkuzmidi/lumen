import Foundation
import LumenCore
import LumenMeta
import Observation

/// The microphone beside an instruction field: click to speak, click again (or Return) to stop. Muse Voice Transcribe
/// writes down what was said, in the language it was said, and the words go into the field for the person to read,
/// correct and run. Nothing runs by itself.
@MainActor @Observable
public final class VoiceInstruction {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    /// Longer than any instruction; a recording stops by itself here.
    public static let longest: TimeInterval = 60
    /// Shorter than any word: a click and a click again.
    public static let shortest: TimeInterval = 0.4

    public private(set) var state: State = .idle
    /// How long this recording has run.
    public private(set) var elapsed: TimeInterval = 0
    /// How loud the voice is right now, 0...1, for the button's meter.
    public private(set) var level: Float = 0
    /// What the last transcription cost, in US dollars.
    public private(set) var lastCost: Double?

    public var isRecording: Bool { state == .recording }
    public var isTranscribing: Bool { state == .transcribing }
    public var failure: String? { if case .failed(let message) = state { message } else { nil } }

    private let transcribe: @Sendable (Data) async throws -> Transcript
    private let recorder: any VoiceRecording
    private let permission: @Sendable () async -> Bool
    private var heard: ((String) -> Void)?
    private var started: Date?
    private var ticker: Task<Void, Never>?
    private var work: Task<Void, Never>?

    /// `transcribe` sends a WAV to Muse Voice Transcribe (`MetaTranscriber.transcribe(wav:)` with the person's key).
    public init(recorder: any VoiceRecording = VoiceRecorder(),
                permission: @escaping @Sendable () async -> Bool = { await VoiceRecorder.permission() },
                transcribe: @escaping @Sendable (Data) async throws -> Transcript) {
        self.recorder = recorder
        self.permission = permission
        self.transcribe = transcribe
    }

    /// Starts listening, or stops and writes down what was said, handing the words to `heard`.
    public func toggle(heard: @escaping (String) -> Void) {
        switch state {
        case .recording: finish()
        case .transcribing: break
        case .idle, .failed: start(heard: heard)
        }
    }

    /// Stops listening or transcribing and keeps nothing.
    public func cancel() {
        if state == .recording { _ = recorder.stop() }
        ticker?.cancel(); ticker = nil
        work?.cancel(); work = nil
        heard = nil
        elapsed = 0; level = 0
        state = .idle
    }

    /// Clears a failure shown beside the field.
    public func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    /// Transcribes a recording already made, as if it had been spoken now: for scripted checks, which have no voice.
    public func transcribe(file: URL, heard: @escaping (String) -> Void) {
        guard state != .recording, state != .transcribing else { return }
        do { send(try SpokenAudio.wav(contentsOf: file), heard: heard) }
        catch { state = .failed(Self.message(for: error)) }
    }

    private func start(heard: @escaping (String) -> Void) {
        self.heard = heard
        state = .recording
        elapsed = 0; level = 0
        work = Task { [weak self] in
            guard let self else { return }
            guard await permission() else {
                if state == .recording { state = .failed("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.") }
                return
            }
            guard state == .recording, !Task.isCancelled else { return }
            do { try recorder.start() } catch {
                state = .failed(Self.message(for: error))
                return
            }
            started = Date()
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, state == .recording, let started else { return }
                    elapsed = Date().timeIntervalSince(started)
                    level = recorder.level
                    if elapsed >= Self.longest { finish() }
                }
            }
        }
    }

    private func finish() {
        ticker?.cancel(); ticker = nil
        let samples = started == nil ? [] : recorder.stop()
        started = nil
        level = 0
        guard let heard else { state = .idle; return }
        guard Double(samples.count) / SpokenAudio.sampleRate >= Self.shortest else {
            state = .failed("Nothing was heard. Click the microphone and speak, then click it again.")
            return
        }
        send(SpokenAudio.wav(samples), heard: heard)
    }

    private func send(_ wav: Data, heard: @escaping (String) -> Void) {
        state = .transcribing
        let transcribe = transcribe
        work = Task { [weak self] in
            do {
                let transcript = try await transcribe(wav)
                guard let self, !Task.isCancelled else { return }
                lastCost = MetaPricing.cost(model: "muse-voice-transcribe-1.0", audioSeconds: transcript.seconds)
                if transcript.text.isEmpty {
                    state = .failed("Nothing was heard. Click the microphone and speak, then click it again.")
                } else {
                    state = .idle
                    heard(transcript.text)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                state = .failed(Self.message(for: error))
            }
            self?.heard = nil
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case LumenError.missingKey: "Voice needs your Meta API key."
        case LumenError.cancelled: "Stopped."
        default: "Couldn't write down what was said: \(error.localizedDescription)"
        }
    }
}
