#if DEBUG
  @preconcurrency import AVFoundation
  import Foundation
  import MindloomPhoneKit

  /// DEBUG builds only. `-MindloomDebugScriptedTranscript <text>` makes each
  /// utterance "hear" that text, a few characters at a time, while the
  /// DEBUG audio file (`-MindloomVoiceFile`) drives the waveform. It exists
  /// because the iOS simulator has no on-device speech models for any
  /// language, so simulator screens cannot show real recognition. Everything
  /// around it (the Darwin signals, the App Group files, the keyboard's
  /// insertion, sealing and the outbox) is the real code path. Never
  /// compiled into Release builds.
  @MainActor
  final class DebugScriptedRecognizer: VoiceRecognizing {
    let kindName = RecognizerChoice.debugScripted.kindName
    let text: String
    let audio: VoiceAudio

    init(text: String, audio: VoiceAudio) {
      self.text = text
      self.audio = audio
    }

    static func scriptedText(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
      guard let index = arguments.firstIndex(of: "-MindloomDebugScriptedTranscript"),
        index + 1 < arguments.count
      else { return nil }
      let text = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }

    func beginUtterance(onPartial: @escaping @MainActor (String) -> Void) throws
      -> any VoiceUtterance
    {
      let utterance = DebugScriptedUtterance(text: text, audio: audio, onPartial: onPartial)
      audio.utteranceDidBegin(utterance)
      return utterance
    }
  }

  @MainActor
  final class DebugScriptedUtterance: VoiceUtterance, AudioSink {
    private let text: String
    private weak var audio: VoiceAudio?
    private var shown = 0
    private var ticker: Task<Void, Never>?

    init(text: String, audio: VoiceAudio, onPartial: @escaping @MainActor (String) -> Void) {
      self.text = text
      self.audio = audio
      let characters = Array(text)
      ticker = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(450))
        var count = 0
        while !Task.isCancelled, count < characters.count {
          count = min(characters.count, count + 2)
          self?.shown = count
          onPartial(String(characters[0..<count]))
          try? await Task.sleep(for: .milliseconds(170))
        }
      }
    }

    /// The audio is only used for the level meter; it is dropped here.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async -> String? {
      ticker?.cancel()
      audio?.utteranceDidEnd(self)
      try? await Task.sleep(for: .milliseconds(250))
      return text
    }

    func cancel() {
      ticker?.cancel()
      audio?.utteranceDidEnd(self)
    }
  }
#endif
