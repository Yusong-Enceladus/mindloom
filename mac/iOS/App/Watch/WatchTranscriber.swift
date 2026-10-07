@preconcurrency import AVFoundation
import Foundation
import MindloomPhoneKit
import Speech
import os

/// Transcribes a recording from Apple Watch on this iPhone (WATCH-005), with the same on-device
/// recognizers, in the same order, as the speak bar (`RecognizerChoice`): SpeechTranscriber, then
/// DictationTranscriber, then SFSpeechRecognizer restricted to on-device recognition. Nothing here
/// uses a server recognizer.
enum WatchTranscriber {
  enum Outcome: Equatable, Sendable {
    /// The recognized text, cleaned by the phone's text rules (empty when nothing was said).
    case text(String)
    /// No recognizer could run now (no model yet, no permission, the system refused): this
    /// recording, and every other one, waits for the next run.
    case notNow
    /// A recognizer ran on this file and failed (or ran past its time): counted against this
    /// recording only, which is tried again after a pause and marked failed after a few tries.
    case failed
    /// The file does not read as audio (cut inside its first frame): it never will.
    case unreadable
    /// The run was cancelled (the background time ended): nothing is counted.
    case cancelled
  }

  private static let log = Logger(subsystem: PhoneNames.appLog, category: "watch")

  /// Seconds of audio in the file, read from the file itself (nil when it does not read as
  /// audio or has none).
  static func length(of url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url), file.length > 0,
      file.fileFormat.sampleRate > 0
    else { return nil }
    return Double(file.length) / file.fileFormat.sampleRate
  }

  /// How long a recognizer may take on this file: twice the longer of the file's own length and
  /// the watch's figure (which can be 0), plus a minute. Nil when the file does not read as audio.
  static func timeLimit(for url: URL, seconds: Double) -> Double? {
    guard let length = length(of: url) else { return nil }
    return 2 * max(1, max(seconds.isFinite ? seconds : 0, length)) + 60
  }

  /// `seconds` is the recording's length from the watch (see `timeLimit`).
  static func transcribe(_ url: URL, seconds: Double) async -> Outcome {
    guard let limit = timeLimit(for: url, seconds: seconds) else { return .unreadable }
    #if DEBUG
      if let scripted = UserDefaults.standard.string(forKey: "MindloomWatchScriptedText") {
        return .text(PhoneText.finalized(scripted))
      }
    #endif
    var ranAndFailed = false
    for choice in await RecognizerChoice.candidates() {
      do {
        guard let heard = try await transcribe(url, limit: limit, with: choice) else {
          continue
        }
        return .text(PhoneText.finalized(heard))
      } catch is CancellationError {
        return .cancelled
      } catch TranscriptionError.notReady {
        log.notice("watch transcription: \(choice.kindName, privacy: .public) not ready")
      } catch {
        ranAndFailed = true
        log.error(
          "watch transcription with \(choice.kindName, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      }
    }
    if Task.isCancelled { return .cancelled }
    return ranAndFailed ? .failed : .notNow
  }

  /// Nil when this recognizer does not apply here.
  private static func transcribe(_ url: URL, limit: Double, with choice: RecognizerChoice)
    async throws -> String?
  {
    switch choice {
    case .speechTranscriber(let locale):
      try await install(choice)
      let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
      return try await analyze(url, limit: limit, module: .speech(transcriber))
    case .dictationTranscriber(let locale):
      try await install(choice)
      let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
      return try await analyze(url, limit: limit, module: .dictation(transcriber))
    case .legacyOnDevice(let locale):
      // Never asks for permission from here (this may run in the background); the speak bar asks.
      guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
      return try await legacy(url, locale: locale)
    case .debugScripted, .unavailable:
      return nil
    }
  }

  /// The recognizer's model: a failure here is the recognizer not being ready, not the file.
  private static func install(_ choice: RecognizerChoice) async throws {
    do {
      try await TranscriberAssets.ensureInstalled(for: choice) { _ in }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TranscriptionError.notReady
    }
  }

  enum TranscriptionError: Error {
    case didNotFinish
    /// The recognizer's model is not installed and could not be installed now.
    case notReady
  }

  /// The whole file through SpeechAnalyzer; the finalized results joined. The file is read in
  /// pieces and converted to the analyzer's own format as it asks for more (the recording's AAC at
  /// 24 kHz is not a format the modules take directly). Bounded by `limit` seconds (`timeLimit`).
  private static func analyze(_ url: URL, limit: Double, module: TranscriberModule) async throws
    -> String
  {
    let file = try AVAudioFile(forReading: url)
    guard
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [module.module], considering: file.processingFormat)
    else { throw TranscriptionError.notReady }
    let analyzer = SpeechAnalyzer(
      modules: [module.module],
      options: SpeechAnalyzer.Options(priority: .utility, modelRetention: .whileInUse))
    do {
      try await analyzer.prepareToAnalyze(in: format)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // The analyzer, not the file.
      throw TranscriptionError.notReady
    }
    let transcript = TranscriptAccumulator()
    let results = Task {
      try await module.results { text, isFinal in _ = transcript.update(text, isFinal: isFinal) }
    }
    let input = FileInput(file: file, converter: BufferConverter(target: format))
    let finished = await Deadline.race(seconds: limit) { () -> Bool in
      do {
        if let last = try await analyzer.analyzeSequence(input) {
          try await analyzer.finalizeAndFinish(through: last)
        } else {
          await analyzer.cancelAndFinishNow()
        }
        try await results.value
        return true
      } catch {
        return false
      }
    }
    guard finished == true, !Task.isCancelled else {
      results.cancel()
      await analyzer.cancelAndFinishNow()
      throw Task.isCancelled ? CancellationError() : TranscriptionError.didNotFinish
    }
    return transcript.text
  }

  /// The file as analyzer input, one converted piece per request: nothing more of the recording is
  /// in memory than the analyzer is working on. Read by the analyzer only.
  private struct FileInput: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput
    let file: AVAudioFile
    let converter: BufferConverter
    static let frames: AVAudioFrameCount = 8192

    struct Iterator: AsyncIteratorProtocol {
      let file: AVAudioFile
      let converter: BufferConverter

      mutating func next() async throws -> AnalyzerInput? {
        while file.framePosition < file.length {
          try Task.checkCancellation()
          guard
            let buffer = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat, frameCapacity: FileInput.frames)
          else { return nil }
          try file.read(into: buffer, frameCount: FileInput.frames)
          if buffer.frameLength == 0 { return nil }
          if let converted = converter.convert(buffer) { return AnalyzerInput(buffer: converted) }
        }
        return nil
      }
    }

    func makeAsyncIterator() -> Iterator { Iterator(file: file, converter: converter) }
  }

  private static func legacy(_ url: URL, locale: Locale) async throws -> String? {
    guard let recognizer = SFSpeechRecognizer(locale: locale),
      recognizer.supportsOnDeviceRecognition
    else { return nil }
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.addsPunctuation = true
    request.taskHint = .dictation
    request.shouldReportPartialResults = false
    return try await withCheckedThrowingContinuation { continuation in
      let once = OnceFlag()
      _ = recognizer.recognitionTask(with: request) { result, error in
        if let result, result.isFinal {
          if once.claim() {
            continuation.resume(returning: result.bestTranscription.formattedString)
          }
        } else if let error {
          guard once.claim() else { return }
          // "No speech detected" (kAFAssistantErrorDomain 1110): nothing was said.
          let ns = error as NSError
          if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 {
            continuation.resume(returning: "")
          } else {
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if done { return false }
      done = true
      return true
    }
  }
}
