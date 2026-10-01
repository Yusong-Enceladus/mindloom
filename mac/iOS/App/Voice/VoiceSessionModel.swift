@preconcurrency import AVFoundation
import Foundation
import MindloomPhoneKit
import Observation
import os

/// The app's voice session (PHONE-CONTRACT §2), as the home screen shows it:
/// permissions, choosing the on-device recognizer, installing its model,
/// running the microphone, the 10-minute idle end, and the heartbeat that
/// tells the keyboard the session is alive.
@MainActor
@Observable
final class VoiceSessionModel {
  enum Status: Equatable {
    case off
    case starting
    /// Downloading the on-device Chinese model (0…1 when known).
    case preparingModel(Double?)
    case live
    case unavailable(VoiceProblem)
  }

  private(set) var status: Status = .off
  private(set) var aliveUntil: Date?
  private(set) var recognizerName: String?
  private(set) var isListening = false
  /// Finals produced in this session (count only; never the text).
  private(set) var finalsThisSession = 0
  /// Runs on every heartbeat while the session is alive.
  var onTick: (@MainActor () -> Void)?

  let channel: VoiceChannel
  private let core: VoiceSessionCore
  private let source: VoiceAudio.Source
  private var audio: VoiceAudio?
  private var recognizer: (any VoiceRecognizing)?
  private var ticker: Task<Void, Never>?
  private let log = Logger(subsystem: "com.bestasr.phone", category: "voice-session")

  init(channel: VoiceChannel, signaling: any PhoneSignaling = DarwinSignaling.shared) {
    self.channel = channel
    self.core = VoiceSessionCore(channel: channel, signaling: signaling)
    self.source = Self.launchSource()
    core.onChange = { [weak self] in self?.coreChanged() }
    core.onFinal = { [weak self] _ in self?.finalsThisSession += 1 }
    core.scrubExpiredFinals()
    // A state file left alive by a previous run is stale: say so at once.
    if channel.readState()?.isAlive(at: Date()) == true {
      core.start(recognizer: StaleRecognizer())
      core.end(reason: .failed)
    }
  }

  var isAlive: Bool { status == .live }

  /// Starts (or refreshes) the session. Safe to call repeatedly.
  func start() async {
    if status == .live {
      core.touch()
      core.tick()
      return
    }
    guard status == .off || isUnavailable else { return }
    status = .starting
    if source == .microphone {
      guard await VoiceAudio.requestMicrophone() else {
        return fail(.microphoneDenied)
      }
    }
    let audio = VoiceAudio(channel: channel, source: source)
    audio.onInterruption = { [weak self] began in self?.interrupted(began) }
    do {
      try audio.start()
    } catch {
      log.error("audio start failed: \(String(describing: error), privacy: .public)")
      return fail(source == .microphone ? .microphoneDenied : .recognizerUnavailable)
    }
    self.audio = audio
    var lastError: Error = RecognizerSetupError.unavailable
    var choices = Self.debugChoices() ?? []
    if choices.isEmpty { choices = await RecognizerChoice.candidates() }
    for choice in choices {
      do {
        let recognizer = try await makeRecognizer(choice, audio: audio)
        log.info("recognizer \(recognizer.kindName, privacy: .public)")
        self.recognizer = recognizer
        recognizerName = recognizer.kindName
        core.start(recognizer: recognizer)
        status = .live
        startTicker()
        return
      } catch {
        log.error(
          "recognizer \(choice.kindName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
        lastError = error
      }
    }
    audio.stop()
    fail(
      lastError as? RecognizerSetupError == .speechDenied ? .speechDenied : .recognizerUnavailable)
  }

  /// DEBUG only: `-MindloomDebugScriptedTranscript <text>` replaces
  /// recognition with a script (the simulator has no on-device speech
  /// models). Never compiled into Release builds.
  private static func debugChoices() -> [RecognizerChoice]? {
    #if DEBUG
      if DebugScriptedRecognizer.scriptedText() != nil { return [.debugScripted] }
    #endif
    return nil
  }

  func end() {
    core.end(reason: .user)
  }

  /// Something happened in the app: push the idle end back.
  func touch() {
    core.touch()
    aliveUntil = core.aliveUntil
  }

  private var isUnavailable: Bool {
    if case .unavailable = status { return true }
    return false
  }

  private func makeRecognizer(_ choice: RecognizerChoice, audio: VoiceAudio) async throws
    -> any VoiceRecognizing
  {
    switch choice {
    case .speechTranscriber, .dictationTranscriber:
      try await TranscriberAssets.ensureInstalled(for: choice) { [weak self] progress in
        self?.status = .preparingModel(progress)
      }
      let recognizer = AnalyzerRecognizer(choice: choice, audio: audio)
      try await recognizer.prepare()
      return recognizer
    case .legacyOnDevice(let locale):
      guard await LegacyOnDeviceRecognizer.authorize() else {
        throw RecognizerSetupError.speechDenied
      }
      guard let recognizer = LegacyOnDeviceRecognizer(locale: locale, audio: audio) else {
        throw RecognizerSetupError.unavailable
      }
      return recognizer
    case .debugScripted:
      #if DEBUG
        if let text = DebugScriptedRecognizer.scriptedText() {
          return DebugScriptedRecognizer(text: text, audio: audio)
        }
      #endif
      throw RecognizerSetupError.unavailable
    case .unavailable:
      throw RecognizerSetupError.unavailable
    }
  }

  private func fail(_ problem: VoiceProblem) {
    status = .unavailable(problem)
    recognizerName = nil
  }

  private func interrupted(_ began: Bool) {
    if began {
      core.handleStop()
      core.report(problem: .interrupted)
    } else {
      core.report(problem: nil)
    }
  }

  private func coreChanged() {
    aliveUntil = core.aliveUntil
    isListening = core.isListening
    if !core.isAlive, status == .live {
      // Ended (idle, by the user, or failed): release the microphone so the
      // system indicator goes off.
      ticker?.cancel()
      ticker = nil
      audio?.stop()
      audio = nil
      recognizer = nil
      recognizerName = nil
      status = .off
      finalsThisSession = 0
      log.info("voice session ended")
    }
  }

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(VoiceState.heartbeatInterval))
        guard let self, !Task.isCancelled else { return }
        self.core.tick()
        self.onTick?()
      }
    }
  }

  // MARK: - DEBUG audio-file hook

  /// `-MindloomVoiceFile <path>` (DEBUG builds only) feeds that file into
  /// every utterance instead of the microphone; `-MindloomVoiceFilePaced NO`
  /// feeds it as fast as possible.
  static func launchSource(arguments: [String] = ProcessInfo.processInfo.arguments)
    -> VoiceAudio.Source
  {
    #if DEBUG
      if let index = arguments.firstIndex(of: "-MindloomVoiceFile"), index + 1 < arguments.count {
        let path = arguments[index + 1]
        let url =
          path.hasPrefix("/")
          ? URL(fileURLWithPath: path)
          : Bundle.main.url(forResource: path, withExtension: nil)
        if let url {
          let paced =
            UserDefaults.standard.object(forKey: "MindloomVoiceFilePaced") as? Bool ?? true
          return .file(url, paced: paced)
        }
      }
    #endif
    return .microphone
  }
}

/// Stands in for a recognizer only to write a clean "no session" state over
/// a stale file at launch.
@MainActor
private final class StaleRecognizer: VoiceRecognizing {
  let kindName = "none"

  func beginUtterance(onPartial: @escaping @MainActor (String) -> Void) throws
    -> any VoiceUtterance
  {
    throw RecognizerSetupError.unavailable
  }
}
