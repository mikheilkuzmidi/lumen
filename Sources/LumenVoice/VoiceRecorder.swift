import AVFoundation
import Foundation
import LumenCore
import Synchronization

/// Something that records the person's voice. `VoiceRecorder` is the Mac's microphone; tests record nothing.
public protocol VoiceRecording: AnyObject, Sendable {
    func start() throws
    /// The samples heard since `start`, in `SpokenAudio.format`.
    func stop() -> [Int16]
    /// The loudness of the latest moment, 0...1.
    var level: Float { get }
}

/// The Mac's default microphone, converted to 16 kHz mono as it is heard.
public final class VoiceRecorder: VoiceRecording {
    private struct Heard {
        var samples: [Int16] = []
        var level: Float = 0
    }

    // The engine is only started and stopped by the one controller that owns this recorder; the tap writes `heard`.
    nonisolated(unsafe) private let engine = AVAudioEngine()
    private let heard = Mutex(Heard())

    public init() {}

    /// Whether the person lets this app use the microphone, asking them the first time.
    public static func permission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public var level: Float { heard.withLock { $0.level } }

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: SpokenAudio.format) else {
            throw LumenError.invalidResponse("No microphone is available.")
        }
        heard.withLock { $0 = Heard() }
        nonisolated(unsafe) let shared = converter
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let samples = try? SpokenAudio.convert(buffer, with: shared, last: false) else { return }
            let level = SpokenAudio.level(samples)
            heard.withLock {
                $0.samples.append(contentsOf: samples)
                $0.level = level
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() -> [Int16] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return heard.withLock { heard in
            defer { heard = Heard() }
            return heard.samples
        }
    }
}
