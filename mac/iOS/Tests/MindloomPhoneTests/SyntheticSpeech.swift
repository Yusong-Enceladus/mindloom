@preconcurrency import AVFoundation
import Foundation
import XCTest

/// Synthetic speech for the recognition tests, made with the system's own
/// text-to-speech at test time, so no audio file is ever committed (the
/// repository's privacy scan refuses audio) and no real voice is involved.
enum SyntheticSpeech {
  static let mandarinSentence = "明天下午三点在三楼会议室开会，记得带上季度预算表。"
  static let englishSentence = "The meeting moves to three p m tomorrow in room four."

  /// Writes `text` spoken by a `language` voice to a CAF file in `directory`.
  /// Throws `XCTSkip` when this device has no voice for the language.
  static func makeFile(_ text: String, language: String, in directory: URL) async throws -> URL {
    guard let voice = AVSpeechSynthesisVoice(language: language) else {
      throw XCTSkip("No \(language) text-to-speech voice on this device")
    }
    let url = directory.appendingPathComponent("synthetic-\(language)-\(UUID().uuidString).caf")
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    let synthesizer = AVSpeechSynthesizer()
    let sink = Sink(url: url)
    // Some systems never send the empty "done" buffer; stop waiting after 20 s.
    let timeout = Task {
      try? await Task.sleep(for: .seconds(20))
      sink.finish()
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      sink.onDone = { continuation.resume() }
      synthesizer.write(utterance, toBufferCallback: callback(sink))
    }
    timeout.cancel()
    withExtendedLifetime(synthesizer) {}
    guard sink.framesWritten > 0 else {
      throw XCTSkip("Text-to-speech produced no audio for \(language) on this device")
    }
    return url
  }

  /// Built outside any actor: the synthesizer calls it on its own queue.
  private static func callback(_ sink: Sink) -> AVSpeechSynthesizer.BufferCallback {
    { buffer in sink.take(buffer) }
  }

  /// Collects the synthesizer's buffers into a file. The synthesizer calls
  /// back on its own queue; the lock keeps the file and the flag consistent.
  private final class Sink: @unchecked Sendable {
    let url: URL
    var onDone: (@Sendable () -> Void)?
    private(set) var framesWritten: AVAudioFramePosition = 0
    private var file: AVAudioFile?
    private var finished = false
    private let lock = NSLock()

    init(url: URL) {
      self.url = url
    }

    func finish() {
      lock.lock()
      defer { lock.unlock() }
      finishLocked()
    }

    /// Closes the file and reports once.
    private func finishLocked() {
      guard !finished else { return }
      finished = true
      file = nil
      onDone?()
    }

    func take(_ buffer: AVAudioBuffer) {
      lock.lock()
      defer { lock.unlock() }
      guard !finished else { return }
      guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
        finishLocked()
        return
      }
      if file == nil {
        file = try? AVAudioFile(
          forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat,
          interleaved: pcm.format.isInterleaved)
      }
      if (try? file?.write(from: pcm)) != nil {
        framesWritten += AVAudioFramePosition(pcm.frameLength)
      }
    }
  }
}
