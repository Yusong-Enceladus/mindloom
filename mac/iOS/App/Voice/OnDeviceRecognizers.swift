@preconcurrency import AVFoundation
import Foundation
import MindloomPhoneKit
import Speech
import os

/// Which on-device recognizer the phone uses for Chinese, best first
/// (PHONE-CONTRACT §2): SpeechAnalyzer with SpeechTranscriber, then
/// SpeechAnalyzer with DictationTranscriber (the model behind the system's
/// own dictation), then SFSpeechRecognizer restricted to on-device
/// recognition. Nothing here ever uses a server recognizer.
enum RecognizerChoice: Equatable, Sendable {
  case speechTranscriber(Locale)
  case dictationTranscriber(Locale)
  case legacyOnDevice(Locale)
  /// DEBUG builds only: a scripted transcript for simulator screens.
  case debugScripted
  case unavailable

  var kindName: String {
    switch self {
    case .speechTranscriber: "speech-transcriber"
    case .dictationTranscriber: "dictation-transcriber"
    case .legacyOnDevice: "sf-on-device"
    case .debugScripted: "debug-scripted"
    case .unavailable: "none"
    }
  }

  static let chinese = Locale(identifier: "zh-CN")

  var localeID: String {
    switch self {
    case .speechTranscriber(let locale), .dictationTranscriber(let locale),
      .legacyOnDevice(let locale):
      locale.identifier
    case .debugScripted, .unavailable: "-"
    }
  }

  /// Every recognizer this device claims for zh-CN, best first. A claim is
  /// not a guarantee (the simulator claims DictationTranscriber but has no
  /// model for it), so the session tries them in order.
  static func candidates(locale: Locale = chinese) async -> [RecognizerChoice] {
    var list: [RecognizerChoice] = []
    if SpeechTranscriber.isAvailable,
      let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    {
      list.append(.speechTranscriber(supported))
    }
    if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
      list.append(.dictationTranscriber(supported))
    }
    if let legacy = SFSpeechRecognizer(locale: locale), legacy.supportsOnDeviceRecognition {
      list.append(.legacyOnDevice(locale))
    }
    return list
  }

  /// The best claimed recognizer for zh-CN.
  static func probe(locale: Locale = chinese) async -> RecognizerChoice {
    await candidates(locale: locale).first ?? .unavailable
  }

  /// A plain report for diagnostics and the honest-limits notes: what each
  /// recognizer says about zh-CN on this device.
  static func diagnostics(locale: Locale = chinese) async -> [String: String] {
    var report: [String: String] = [:]
    report["speech_transcriber_available"] = String(SpeechTranscriber.isAvailable)
    report["speech_transcriber_supported"] =
      await SpeechTranscriber.supportedLocale(equivalentTo: locale)?.identifier ?? "none"
    report["speech_transcriber_supported_count"] = String(
      await SpeechTranscriber.supportedLocales.count)
    report["speech_transcriber_installed"] =
      await SpeechTranscriber.installedLocales.map(\.identifier).sorted().joined(separator: ",")
    report["dictation_transcriber_supported"] =
      await DictationTranscriber.supportedLocale(equivalentTo: locale)?.identifier ?? "none"
    let legacy = SFSpeechRecognizer(locale: locale)
    report["sf_recognizer"] = legacy == nil ? "none" : "present"
    report["sf_on_device"] = String(legacy?.supportsOnDeviceRecognition ?? false)
    report["sf_available"] = String(legacy?.isAvailable ?? false)
    return report
  }
}

enum RecognizerSetupError: Error, Equatable {
  case unavailable
  case speechDenied
  case modelNotInstalled
}

// MARK: - SpeechAnalyzer (SpeechTranscriber or DictationTranscriber)

/// One analyzer module for an utterance.
enum TranscriberModule: @unchecked Sendable {
  case speech(SpeechTranscriber)
  case dictation(DictationTranscriber)

  var module: any SpeechModule {
    switch self {
    case .speech(let transcriber): transcriber
    case .dictation(let transcriber): transcriber
    }
  }

  static func make(_ choice: RecognizerChoice) -> TranscriberModule? {
    switch choice {
    case .speechTranscriber(let locale):
      .speech(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
    case .dictationTranscriber(let locale):
      .dictation(DictationTranscriber(locale: locale, preset: .progressiveShortDictation))
    default:
      nil
    }
  }

  /// Streams (text, isFinal) pairs until the analyzer finishes.
  func results(_ handle: @escaping @Sendable (String, Bool) async -> Void) async throws {
    switch self {
    case .speech(let transcriber):
      for try await result in transcriber.results {
        await handle(String(result.text.characters), result.isFinal)
      }
    case .dictation(let transcriber):
      for try await result in transcriber.results {
        await handle(String(result.text.characters), result.isFinal)
      }
    }
  }
}

/// Makes sure the on-device model for the choice is installed, downloading
/// it through AssetInventory when needed (`progress` reports 0…1).
enum TranscriberAssets {
  static func ensureInstalled(
    for choice: RecognizerChoice, progress: @escaping @MainActor (Double?) -> Void
  ) async throws {
    guard let module = TranscriberModule.make(choice)?.module else { return }
    if await AssetInventory.status(forModules: [module]) == .installed { return }
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
    else { return }
    await progress(0)
    let watcher = Task { @MainActor in
      while !Task.isCancelled {
        progress(request.progress.fractionCompleted)
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
    defer { watcher.cancel() }
    try await request.downloadAndInstall()
    await progress(1)
  }
}

/// SpeechAnalyzer-based recognizer. Each utterance gets its own analyzer,
/// prepared ahead of time so a key press starts transcribing at once.
@MainActor
final class AnalyzerRecognizer: VoiceRecognizing {
  let choice: RecognizerChoice
  let audio: VoiceAudio
  var kindName: String { choice.kindName }
  private var spare: AnalyzerUtterance?
  private let log = Logger(subsystem: "com.bestasr.phone", category: "recognizer")

  init(choice: RecognizerChoice, audio: VoiceAudio) {
    self.choice = choice
    self.audio = audio
  }

  /// Prepares the first analyzer (loads the model).
  func prepare() async throws {
    spare = try await makeUtterance()
  }

  func beginUtterance(onPartial: @escaping @MainActor (String) -> Void) throws
    -> any VoiceUtterance
  {
    guard let utterance = spare else { throw RecognizerSetupError.unavailable }
    spare = nil
    utterance.begin(onPartial: onPartial)
    audio.utteranceDidBegin(utterance)
    Task { [weak self] in
      guard let self else { return }
      self.spare = try? await self.makeUtterance()
    }
    return utterance
  }

  private func makeUtterance() async throws -> AnalyzerUtterance {
    guard let module = TranscriberModule.make(choice) else {
      throw RecognizerSetupError.unavailable
    }
    let format = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [module.module], considering: audio.inputFormat)
    guard let format else { throw RecognizerSetupError.unavailable }
    let analyzer = SpeechAnalyzer(
      modules: [module.module],
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
    try await analyzer.prepareToAnalyze(in: format)
    return AnalyzerUtterance(analyzer: analyzer, module: module, format: format, audio: audio)
  }
}

/// One utterance through SpeechAnalyzer. Buffers are converted to the
/// analyzer's format on the audio thread and streamed in; they exist only
/// in memory and are released as soon as the analyzer has read them.
@MainActor
final class AnalyzerUtterance: VoiceUtterance, AudioSink {
  private let analyzer: SpeechAnalyzer
  private let module: TranscriberModule
  private nonisolated let converter: BufferConverter
  private let stream: AsyncStream<AnalyzerInput>
  private nonisolated let continuation: AsyncStream<AnalyzerInput>.Continuation
  private weak var audio: VoiceAudio?
  private var analysisTask: Task<Void, Never>?
  private var resultsTask: Task<Void, Never>?
  private let transcript = TranscriptAccumulator()

  init(
    analyzer: SpeechAnalyzer, module: TranscriberModule, format: AVAudioFormat, audio: VoiceAudio
  ) {
    self.analyzer = analyzer
    self.module = module
    self.converter = BufferConverter(target: format)
    (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    self.audio = audio
  }

  func begin(onPartial: @escaping @MainActor (String) -> Void) {
    let transcript = transcript
    resultsTask = Task { [module] in
      try? await module.results { text, isFinal in
        let current = transcript.update(text, isFinal: isFinal)
        await MainActor.run { onPartial(current) }
      }
    }
    analysisTask = Task { [analyzer, stream] in
      try? await analyzer.start(inputSequence: stream)
    }
  }

  /// Audio thread.
  nonisolated func append(_ buffer: AVAudioPCMBuffer) {
    guard let converted = converter.convert(buffer) else { return }
    continuation.yield(AnalyzerInput(buffer: converted))
  }

  func finish() async -> String? {
    audio?.utteranceDidEnd(self)
    continuation.finish()
    do {
      try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
      resultsTask?.cancel()
      return nil
    }
    await resultsTask?.value
    return transcript.text
  }

  func cancel() {
    audio?.utteranceDidEnd(self)
    continuation.finish()
    resultsTask?.cancel()
    let analyzer = analyzer
    Task { await analyzer.cancelAndFinishNow() }
  }
}

/// Finalized text plus the current volatile guess.
final class TranscriptAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var finalized = ""
  private var volatile = ""

  func update(_ text: String, isFinal: Bool) -> String {
    lock.lock()
    defer { lock.unlock() }
    if isFinal {
      finalized += text
      volatile = ""
    } else {
      volatile = text
    }
    return finalized + volatile
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Converts microphone buffers to the recognizer's format. Used from the
/// audio thread only.
final class BufferConverter: @unchecked Sendable {
  let target: AVAudioFormat
  private var converter: AVAudioConverter?

  init(target: AVAudioFormat) {
    self.target = target
  }

  func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    if buffer.format == target { return buffer }
    if converter == nil || converter?.inputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: target)
      converter?.primeMethod = .none
    }
    guard let converter else { return nil }
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 64)
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      return nil
    }
    let provided = InputFlag()
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, outStatus in
      if provided.value {
        outStatus.pointee = .noDataNow
        return nil
      }
      provided.value = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0 else { return nil }
    return output
  }

  private final class InputFlag: @unchecked Sendable {
    var value = false
  }
}

// MARK: - SFSpeechRecognizer, on device only

@MainActor
final class LegacyOnDeviceRecognizer: VoiceRecognizing {
  let kindName = RecognizerChoice.legacyOnDevice(RecognizerChoice.chinese).kindName
  let recognizer: SFSpeechRecognizer
  let audio: VoiceAudio

  init?(locale: Locale, audio: VoiceAudio) {
    guard let recognizer = SFSpeechRecognizer(locale: locale),
      recognizer.supportsOnDeviceRecognition
    else { return nil }
    recognizer.defaultTaskHint = .dictation
    self.recognizer = recognizer
    self.audio = audio
  }

  /// Speech calls the authorization handler on a background queue, so the
  /// handler must not be main-actor isolated.
  nonisolated static func authorize() async -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return true
    case .denied, .restricted: return false
    default:
      return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
          continuation.resume(returning: status == .authorized)
        }
      }
    }
  }

  func beginUtterance(onPartial: @escaping @MainActor (String) -> Void) throws
    -> any VoiceUtterance
  {
    let utterance = LegacyUtterance(recognizer: recognizer, audio: audio, onPartial: onPartial)
    audio.utteranceDidBegin(utterance)
    return utterance
  }
}

@MainActor
final class LegacyUtterance: VoiceUtterance, AudioSink {
  /// Thread-safe per Speech: buffers are appended from the audio thread.
  private nonisolated(unsafe) let request = SFSpeechAudioBufferRecognitionRequest()
  private var task: SFSpeechRecognitionTask?
  private weak var audio: VoiceAudio?
  private var latest = ""
  /// The last recognition error (domain#code), for diagnostics.
  private(set) var lastErrorCode: String?
  private var done: CheckedContinuation<String?, Never>?
  private var result: String??

  /// Speech calls the result handler on the recognizer's queue, which is
  /// the main queue, so everything here stays on the main actor.
  init(
    recognizer: SFSpeechRecognizer, audio: VoiceAudio,
    onPartial: @escaping @MainActor (String) -> Void
  ) {
    self.audio = audio
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    request.taskHint = .dictation
    recognizer.queue = .main
    task = recognizer.recognitionTask(with: request) { [weak self] recognized, error in
      MainActor.assumeIsolated {
        guard let self else { return }
        if let recognized {
          let text = recognized.bestTranscription.formattedString
          self.latest = text
          onPartial(text)
          if recognized.isFinal { self.complete(text) }
        } else if let error = error as NSError? {
          // Content-free: the domain and code only.
          Logger(subsystem: "com.bestasr.phone", category: "recognizer").error(
            "on-device recognition error \(error.domain, privacy: .public) \(error.code, privacy: .public)"
          )
          self.lastErrorCode = "\(error.domain)#\(error.code)"
          self.complete(self.latest.isEmpty ? nil : self.latest)
        }
      }
    }
  }

  /// Audio thread.
  nonisolated func append(_ buffer: AVAudioPCMBuffer) {
    request.append(buffer)
  }

  private func complete(_ text: String?) {
    if result == nil { result = .some(text) }
    let waiter = done
    done = nil
    waiter?.resume(returning: text)
  }

  func finish() async -> String? {
    audio?.utteranceDidEnd(self)
    request.endAudio()
    let timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard let self, !Task.isCancelled else { return }
      self.complete(self.latest)
    }
    defer { timeout.cancel() }
    if let result { return result }
    return await withCheckedContinuation { continuation in
      if let result {
        continuation.resume(returning: result)
      } else {
        done = continuation
      }
    }
  }

  func cancel() {
    audio?.utteranceDidEnd(self)
    task?.cancel()
    complete(nil)
  }
}
