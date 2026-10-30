import LumenCore
import LumenMeta
import LumenVoice
import SwiftUI

enum StudioVoice {
    /// Muse Voice Transcribe with the person's own key, as the rest of Studio's Meta calls.
    @MainActor static func instruction(allowKeychainInteraction: Bool = true) -> VoiceInstruction {
        VoiceInstruction { wav in
            let key = try StudioKeychain.runtimeKey(allowInteraction: allowKeychainInteraction)
            return try await MetaTranscriber(configuration: MetaConfiguration(apiKey: key)).transcribe(wav: wav)
        }
    }

    /// The words heard, after what the field already says.
    static func adding(_ words: String, to field: String) -> String {
        let kept = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? words : kept + " " + words
    }
}

/// The microphone beside an instruction, as Photoeditor's: grey at rest; red while it listens, with how long and how
/// loud; a spinner while Muse Voice Transcribe writes it down. Return stops it, Esc throws it away.
struct StudioMicButton: View {
    let voice: VoiceInstruction
    var disabled = false
    let heard: (String) -> Void
    let failed: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            if voice.isTranscribing {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: StudioStyle.control, height: StudioStyle.control)
                    .accessibilityLabel("Writing down what was said")
            } else if voice.isRecording {
                Button { voice.toggle(heard: heard) } label: {
                    ZStack {
                        Circle().fill(StudioStyle.danger.opacity(0.22)).scaleEffect(0.7 + 0.6 * CGFloat(voice.level))
                        Image(systemName: "mic.fill").font(.system(size: 12)).foregroundStyle(StudioStyle.danger)
                    }
                    .frame(width: StudioStyle.control, height: StudioStyle.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help("Stop and write it down (Return)")
                .accessibilityLabel("Stop listening")
                Text(Duration.seconds(voice.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(StudioStyle.value).foregroundStyle(StudioStyle.danger).fixedSize()
                Button("Cancel") { voice.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain).font(StudioStyle.label).foregroundStyle(StudioStyle.textSecondary)
            } else {
                StudioIconButton(symbol: "mic", help: "Speak the instruction") { voice.toggle(heard: heard) }
                    .disabled(disabled)
            }
        }
        .onChange(of: voice.failure) { _, failure in
            guard let failure else { return }
            failed(failure)
            voice.dismissFailure()
        }
    }
}
