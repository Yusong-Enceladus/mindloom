@preconcurrency import AVFoundation
import Foundation
import MindloomPhoneKit
import Observation
import UIKit
import os

/// The app's voice (PHONE-SPEC §7.3–7.4): the session the keyboard uses (on for 10 minutes of no
/// use, or while charging), and the in-app speak bar, which works without a session (the microphone
/// is open only while listening). One recognizer and one audio engine serve both.
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

  /// Microphone permission as the screens show it.
  enum Microphone: Equatable {
    case undetermined
    case granted
    case denied
  }

  private(set) var status: Status = .off
  private(set) var aliveUntil: Date?
  private(set) var recognizerName: String?
  private(set) var isListening = false
  private(set) var microphone: Microphone = VoiceSessionModel.currentMicrophone()
  /// The device is charging (battery state charging or full).
  private(set) var isCharging = false
  /// Finals produced in this session (count only; never the text).
  private(set) var finalsThisSession = 0
  /// Runs on every heartbeat while the session is alive.
  var onTick: (@MainActor () -> Void)?
  /// The session started or ended (for the Live Activity).
  var onSessionChange: (@MainActor () -> Void)?
  /// The keyboard inserted a final (keep it for the Mac) / took one back.
  var onKeyboardInserted: (@MainActor (VoiceText, Date) -> Void)?
  var onKeyboardWithdrawn: (@MainActor (Int) -> Void)?

  let channel: VoiceChannel
  let settings: PhoneSettings
  private let core: VoiceSessionCore
  private let source: VoiceAudio.Source
  private var audio: VoiceAudio?
  private var recognizer: (any VoiceRecognizing)?
  @ObservationIgnored private var preparing: Task<Unchecked<(any VoiceRecognizing)?>, Never>?
  @ObservationIgnored private var preparingToken: UUID?
  /// Why the last recognizer setup failed (shown by the keyboard until the next start).
  @ObservationIgnored private var lastSetupProblem: VoiceProblem?
  private var localOpen = 0
  private var ticker: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private let log = Logger(subsystem: PhoneNames.appLog, category: "voice-session")

  init(
    channel: VoiceChannel, settings: PhoneSettings,
    signaling: any PhoneSignaling = DarwinSignaling.shared
  ) {
    self.channel = channel
    self.settings = settings
    self.core = VoiceSessionCore(
      channel: channel, signaling: signaling,
      idleTimeout: TimeInterval(settings.idleMinutes * 60))
    self.source = Self.launchSource()
    core.onChange = { [weak self] in self?.coreChanged() }
    core.onFinal = { [weak self] _ in self?.finalsThisSession += 1 }
    core.onKeyboardInserted = { [weak self] final, at in self?.onKeyboardInserted?(final, at) }
    core.onKeyboardWithdrawn = { [weak self] seq in self?.onKeyboardWithdrawn?(seq) }
    core.scrubExpiredFinals()
    // A state file left alive by a previous run is stale: say so at once.
    if channel.readState()?.isAlive(at: Date()) == true {
      core.start(recognizer: StaleRecognizer())
      core.end(reason: .failed)
    }
    core.setMicrophoneDenied(microphone == .denied)
    UIDevice.current.isBatteryMonitoringEnabled = true
    isCharging = Self.chargingNow()
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.batteryChanged() }
      })
  }

  var isAlive: Bool { status == .live }

  /// The Live Activity (Dynamic Island, Lock Screen) shows the session and its 「结束」. Without it
  /// (Live Activities off, or a build without the widget) the app shows its own 「结束」 and the
  /// session never stays on for charging: an open microphone always has a visible off switch.
  var indicatorShown = false {
    didSet {
      guard indicatorShown != oldValue else { return }
      if !indicatorShown { core.touch() }
      aliveUntil = core.aliveUntil
    }
  }

  /// 「充电时保持开启」 applies now.
  var staysOnForCharging: Bool {
    isCharging && settings.stayOnWhileCharging && indicatorShown
  }

  /// Seconds left before the session ends by itself; nil while it stays on for charging.
  var endsAt: Date? {
    guard isAlive else { return nil }
    if staysOnForCharging { return nil }
    return aliveUntil
  }

  // MARK: - Permission

  static func currentMicrophone() -> Microphone {
    #if DEBUG
      if let forced = DebugLaunch.microphone { return forced }
    #endif
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return .granted
    case .denied: return .denied
    default: return .undetermined
    }
  }

  /// Rereads the permission (on becoming active). Turning the microphone off in iOS Settings ends
  /// the session at once (PHONE-SPEC §7.2).
  func refreshMicrophone() {
    microphone = Self.currentMicrophone()
    if microphone == .denied, isAlive { core.end(reason: .interrupted) }
    core.setMicrophoneDenied(microphone == .denied)
  }

  /// Shows the system microphone alert when the answer is not known yet.
  @discardableResult
  func requestMicrophone() async -> Bool {
    if microphone == .granted { return true }
    #if DEBUG
      if DebugLaunch.microphone != nil { return microphone == .granted }
    #endif
    let granted = await VoiceAudio.requestMicrophone()
    microphone = Self.currentMicrophone()
    core.setMicrophoneDenied(microphone == .denied)
    if granted { prewarm() }
    return granted
  }

  // MARK: - The session (keyboard)

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
      guard await requestMicrophone() else { return fail(.microphoneDenied) }
    }
    do {
      try ensureAudioRunning()
    } catch {
      log.error("audio start failed: \(String(describing: error), privacy: .public)")
      // The status leaves .starting first, so the microphone is really released.
      fail(source == .microphone ? .microphoneDenied : .recognizerUnavailable)
      stopAudioIfIdle()
      return
    }
    guard let recognizer = await ensureRecognizer() else {
      fail(lastSetupProblem ?? .recognizerUnavailable)
      stopAudioIfIdle()
      return
    }
    // A speak-bar press may have ended while the recognizer was loading.
    do {
      try ensureAudioRunning()
    } catch {
      fail(.recognizerUnavailable)
      stopAudioIfIdle()
      return
    }
    core.idleTimeout = TimeInterval(settings.idleMinutes * 60)
    core.start(recognizer: recognizer)
    status = .live
    startTicker()
    onSessionChange?()
  }

  func end() {
    core.end(reason: .user)
  }

  /// Something happened in the app (a press on the speak bar): push the idle end back.
  func touch() {
    core.touch()
    aliveUntil = core.aliveUntil
  }

  /// 自动结束 changed: applies at once and restarts the countdown.
  func setIdleMinutes(_ minutes: Int) {
    settings.idleMinutes = minutes
    core.idleTimeout = TimeInterval(settings.idleMinutes * 60)
    aliveUntil = core.aliveUntil
    onSessionChange?()
  }

  func setStayOnWhileCharging(_ on: Bool) {
    settings.stayOnWhileCharging = on
    if !on { core.touch() }
    aliveUntil = core.aliveUntil
    onSessionChange?()
  }

  // MARK: - In-app utterances (the speak bar)

  /// Opens an utterance for the speak bar. The microphone starts at once (and keeps what is said
  /// while the recognizer gets ready); without a session it stops again when the utterance ends.
  /// Returns nil when the microphone is not allowed.
  func beginLocalUtterance(onPartial: @escaping @MainActor (String) -> Void) -> LocalUtterance? {
    guard microphone == .granted || source != .microphone else { return nil }
    do {
      try ensureAudioRunning()
    } catch {
      log.error("audio start failed: \(String(describing: error), privacy: .public)")
      stopAudioIfIdle()
      return nil
    }
    guard let audio else { return nil }
    audio.router.arm()
    localOpen += 1
    isListening = true
    touch()
    let utterance = LocalUtterance()
    // A press is never left open: whatever happens to the touch or the app, the utterance and the
    // microphone close after the core's maximum (plus a margin for the talk controller's own cap).
    utterance.cap = Task { [weak utterance] in
      try? await Task.sleep(for: .seconds(VoiceSessionCore.defaultMaximumUtterance + 10))
      guard !Task.isCancelled, let utterance, !utterance.isClosed else { return }
      utterance.cancel()
    }
    utterance.opening = Task { [weak self] () -> Unchecked<(any VoiceUtterance)?> in
      guard let self, let recognizer = await self.ensureRecognizer() else { return Unchecked(nil) }
      guard !utterance.isCancelled else { return Unchecked(nil) }
      return Unchecked(try? recognizer.beginUtterance(onPartial: onPartial))
    }
    utterance.onClose = { [weak self] in
      guard let self else { return }
      self.audio?.router.disarm()
      self.localOpen = max(0, self.localOpen - 1)
      self.isListening = self.localOpen > 0 || self.core.isListening
      self.touch()
      self.stopAudioIfIdle()
    }
    return utterance
  }

  /// The audio level (dBFS per buffer, audio thread) for the listening animation.
  func setLevelHandler(_ handler: (@Sendable (Double) -> Void)?) {
    levelHandler = handler
    audio?.meter.setHandler(handler)
  }

  @ObservationIgnored private var levelHandler: (@Sendable (Double) -> Void)?

  // MARK: - Audio and recognizer

  /// Loads the recognizer ahead of the first press (no microphone, and never a permission alert:
  /// the system speech recognizer, which needs one, is only set up on a press).
  func prewarm() {
    guard microphone == .granted || source != .microphone else { return }
    #if DEBUG
      if DebugLaunch.screen != nil { return }
    #endif
    if audio == nil { makeAudio() }
    Task { _ = await ensureRecognizer(quietly: true) }
  }

  private func makeAudio() {
    let audio = VoiceAudio(channel: channel, source: source)
    audio.onInterruption = { [weak self] began, recovered in
      self?.interrupted(began: began, recovered: recovered)
    }
    audio.meter.setHandler(levelHandler)
    self.audio = audio
  }

  private func ensureAudioRunning() throws {
    if audio == nil { makeAudio() }
    guard let audio, !audio.isRunning else { return }
    try audio.start()
  }

  private func stopAudioIfIdle() {
    guard !isAlive, !isStartingUp, localOpen == 0 else { return }
    audio?.stop()
  }

  /// `start()` is between its first step and the live session (the microphone must stay up).
  private var isStartingUp: Bool {
    switch status {
    case .starting, .preparingModel: true
    default: false
    }
  }

  private func ensureRecognizer(quietly: Bool = false) async -> (any VoiceRecognizing)? {
    if let recognizer { return recognizer }
    if let preparing {
      if let made = await preparing.value.value { return made }
      if quietly || recognizer != nil { return recognizer }
    }
    guard let audio else { return nil }
    let task = Task { @MainActor [weak self] () -> Unchecked<(any VoiceRecognizing)?> in
      guard let self else { return Unchecked(nil) }
      var choices = Self.debugChoices() ?? []
      if choices.isEmpty { choices = await RecognizerChoice.candidates() }
      if quietly {
        choices = choices.filter {
          if case .legacyOnDevice = $0 { return false }
          return true
        }
      }
      var modelMissing = false
      for choice in choices {
        // SFSpeechRecognizer asks for the Speech Recognition consent, whose system text says
        // Apple processes speech. It is only a fallback for a device without an on-device
        // analyzer for Chinese, never for an analyzer whose model is merely not downloaded yet
        // (offline first start): then the session waits for the model instead.
        if case .legacyOnDevice = choice, modelMissing { continue }
        do {
          let made = try await self.makeRecognizer(choice, audio: audio)
          self.log.info("recognizer \(made.kindName, privacy: .public)")
          return Unchecked(made)
        } catch RecognizerSetupError.modelNotInstalled {
          modelMissing = true
          self.log.error("recognizer \(choice.kindName, privacy: .public): model not installed")
        } catch {
          self.log.error(
            "recognizer \(choice.kindName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
          )
        }
      }
      self.lastSetupProblem = modelMissing ? .preparingModel : .recognizerUnavailable
      return Unchecked(nil)
    }
    // Only the caller that made this task clears it: a quiet prewarm resuming after a press
    // must not drop the press's own preparation.
    let token = UUID()
    preparing = task
    preparingToken = token
    let made = await task.value.value
    if preparingToken == token {
      preparing = nil
      preparingToken = nil
    }
    if let recognizer { return recognizer }
    if made == nil && quietly { return nil }
    if made != nil { lastSetupProblem = nil }
    recognizer = made
    recognizerName = made?.kindName
    return made
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

  private var isUnavailable: Bool {
    if case .unavailable = status { return true }
    return false
  }

  private func makeRecognizer(_ choice: RecognizerChoice, audio: VoiceAudio) async throws
    -> any VoiceRecognizing
  {
    switch choice {
    case .speechTranscriber, .dictationTranscriber:
      do {
        try await TranscriberAssets.ensureInstalled(for: choice) { [weak self] progress in
          guard let self, self.isStartingUp else { return }
          self.status = .preparingModel(progress)
        }
      } catch {
        log.error("model download failed: \(String(describing: error), privacy: .public)")
        throw RecognizerSetupError.modelNotInstalled
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
    if problem == .microphoneDenied {
      microphone = Self.currentMicrophone()
      core.setMicrophoneDenied(microphone == .denied)
    }
  }

  /// A call (or another app) took the microphone; `recovered` says whether the engine really runs
  /// again afterwards. If it does not, the session ends honestly instead of looking ready.
  private func interrupted(began: Bool, recovered: Bool) {
    if began {
      core.handleStop()
      core.report(problem: .interrupted)
    } else if recovered {
      core.report(problem: nil)
    } else {
      log.error("audio did not restart after an interruption")
      if core.isAlive { core.end(reason: .interrupted) }
      audio?.stop()
      audio = nil
      recognizer = nil
      recognizerName = nil
    }
  }

  private func coreChanged() {
    aliveUntil = core.aliveUntil
    isListening = core.isListening || localOpen > 0
    if !core.isAlive, status == .live {
      // Ended (idle, by the user, or failed): release the microphone so the
      // system indicator goes off.
      ticker?.cancel()
      ticker = nil
      status = .off
      finalsThisSession = 0
      // The Live Activity's end is started (with background time) before the audio goes: once the
      // audio is released iOS may suspend a background app at any moment.
      onSessionChange?()
      stopAudioIfIdle()
      log.info("voice session ended")
    }
  }

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(VoiceState.heartbeatInterval))
        guard let self, !Task.isCancelled else { return }
        // 充电时保持开启: no countdown while charging.
        if self.staysOnForCharging { self.core.touch() }
        self.core.tick()
        self.onTick?()
      }
    }
  }

  private static func chargingNow() -> Bool {
    let state = UIDevice.current.batteryState
    return state == .charging || state == .full
  }

  private func batteryChanged() {
    let charging = Self.chargingNow()
    guard charging != isCharging else { return }
    isCharging = charging
    // Unplugged: the countdown starts from now.
    if !charging { core.touch() }
    aliveUntil = core.aliveUntil
    onSessionChange?()
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
        // Absolute, a bundle resource, or relative to the app's home
        // directory (a file copied into the data container by devicectl).
        let url =
          path.hasPrefix("/")
          ? URL(fileURLWithPath: path)
          : Bundle.main.url(forResource: path, withExtension: nil) ?? homeFile(path)
        if let url {
          let paced =
            UserDefaults.standard.object(forKey: "MindloomVoiceFilePaced") as? Bool ?? true
          return .file(url, paced: paced)
        }
      }
    #endif
    return .microphone
  }

  #if DEBUG
    /// `path` inside the app's home directory, if that file exists.
    static func homeFile(_ path: String) -> URL? {
      let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent(path)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// DEBUG bench only: the next utterance plays `url`.
    func debugPlayNext(_ url: URL) {
      audio?.debugNextFile = url
    }

    /// DEBUG bench only: waits until the open utterance's file was fed.
    func debugWaitForFileFeed() async {
      await audio?.waitForFileFeed()
    }
  #endif
}

/// One press on the speak bar. `finish()` returns the recognised text (nil or empty when nothing
/// was heard); `cancel()` drops everything.
@MainActor
final class LocalUtterance {
  fileprivate var opening: Task<Unchecked<(any VoiceUtterance)?>, Never>?
  fileprivate var onClose: (() -> Void)?
  fileprivate var cap: Task<Void, Never>?
  fileprivate(set) var isCancelled = false
  private var closed = false

  var isClosed: Bool { closed }

  func finish() async -> String? {
    let utterance = await opening?.value.value
    defer { close() }
    guard !isCancelled, let utterance else { return nil }
    return await utterance.finish()
  }

  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    Task { @MainActor in
      let utterance = await opening?.value.value
      utterance?.cancel()
      close()
    }
  }

  private func close() {
    guard !closed else { return }
    closed = true
    cap?.cancel()
    cap = nil
    onClose?()
  }
}

/// Carries a main-actor object out of a main-actor task (both ends are on the main actor).
struct Unchecked<T>: @unchecked Sendable {
  let value: T
  init(_ value: T) { self.value = value }
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
