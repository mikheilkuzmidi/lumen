import AVFoundation
import Foundation
import LumenCore

/// Speech as Muse Voice Transcribe takes it: a WAV file of mono 16-bit samples at 16 kHz.
public enum SpokenAudio {
    public static let sampleRate = 16_000.0
    /// What a recording is converted to.
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    /// A WAV file of `samples`.
    public static func wav(_ samples: [Int16]) -> Data {
        let bytes = samples.count * 2
        var data = Data(capacity: 44 + bytes)
        func append<Value: FixedWidthInteger>(_ value: Value) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }

    /// Any audio file AVFoundation reads (a voice memo, an AIFF from `say`, a WAV), as `wav` writes it.
    public static func wav(contentsOf url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LumenError.invalidResponse("The audio file is empty.")
        }
        try file.read(into: buffer)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw LumenError.invalidResponse("The audio can't be converted to 16 kHz mono.")
        }
        return wav(try convert(buffer, with: converter, last: true))
    }

    /// `buffer` in `format`. A recording passes its buffers one by one through the same converter, so the resampling
    /// runs on across them; the `last` one flushes what the converter holds.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, last: Bool) throws -> [Int16] {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var samples: [Int16] = []
        var given = false
        while true {
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, state in
                if given {
                    state.pointee = last ? .endOfStream : .noDataNow
                    return nil
                }
                given = true
                state.pointee = .haveData
                return buffer
            }
            if let failure { throw failure }
            if let channel = output.int16ChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            if status != .haveData { break }
        }
        return samples
    }

    /// How loud `samples` are, 0...1: their root mean square, scaled so speech at a normal distance reads about halfway.
    public static func level(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return Float(min(1, power.squareRoot() / 32_768 * 8))
    }
}
