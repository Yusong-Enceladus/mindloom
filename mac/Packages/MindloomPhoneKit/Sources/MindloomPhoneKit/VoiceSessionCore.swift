import Foundation

/// An on-device recognizer as the voice session sees it. The app's
/// implementations (SpeechAnalyzer / SpeechTranscriber, or SFSpeechRecognizer
/// on device only) own the audio: while an utterance is open, microphone
/// buffers go to it; at every other moment they are dropped.
@MainActor
public protocol VoiceRecognizing: AnyObject {
  /// Diagnostic name, for example `speech-transcriber`.
  var kindName: String { get }
  /// Opens a new utterance. `onPartial` receives the running transcript.
  func beginUtterance(onPartial: @escaping @MainActor (String) -> Void) throws
    -> any VoiceUtterance
}

/// One held-key utterance.
@MainActor
public protocol VoiceUtterance: AnyObject {
  /// Stops taking audio and returns the final transcript, or nil when
  /// recognition failed.
  func finish() async -> String?
  /// Stops and drops everything (the session ended mid-utterance).
  func cancel()
}

/// The app's half of the keyboard ↔ app voice protocol (PHONE-CONTRACT §2),
/// independent of AVFoundation so it can be tested with a fake recognizer.
///
/// - `start(recognizer:)` opens a session: `voice/state.json` says it is
///   alive until 10 minutes after the last use, and the app keeps the
///   microphone running (the system mic indicator is on) so a key press
///   starts transcription at once.
/// - `.start` from the keyboard opens an utterance with the next `seq`;
///   `.stop` closes it. Partials go to `voice/partial.json` + `.partial`, the
///   final to `voice/final.json` + `.final`, always in `seq` order.
/// - `tick()` (every few seconds) writes the heartbeat, ends an idle
///   session, stops an utterance left open too long and blanks old finals.
@MainActor
public final class VoiceSessionCore {
  public enum Phase: Equatable, Sendable {
    case off
    case ready
    case listening(seq: Int)
  }

  public enum EndReason: String, Sendable {
    case user
    case idle
    case interrupted
    case failed
  }

  public static let defaultIdleTimeout: TimeInterval = 10 * 60
  /// A toggled-on key that is never tapped off stops by itself.
  public static let defaultMaximumUtterance: TimeInterval = 3 * 60
  /// Finals stay readable this long; the keyboard reads them within
  /// milliseconds.
  public static let defaultFinalRetention: TimeInterval = 60

  public private(set) var phase: Phase = .off
  public private(set) var aliveUntil: Date?
  public private(set) var seq: Int
  /// Utterances released but not yet final.
  public private(set) var finishingCount = 0
  public private(set) var lastEndReason: EndReason?
  public private(set) var problem: VoiceProblem?

  /// Called after every change the UI may show.
  public var onChange: (@MainActor () -> Void)?
  /// Called after a final is published.
  public var onFinal: (@MainActor (VoiceText) -> Void)?

  private let channel: VoiceChannel
  private let signaling: any PhoneSignaling
  private let clock: @Sendable () -> Date
  private let idleTimeout: TimeInterval
  private let maximumUtterance: TimeInterval
  private let finalRetention: TimeInterval

  private var recognizer: (any VoiceRecognizing)?
  private var utterance: (any VoiceUtterance)?
  private var listeningSince: Date?
  private var lastFinish: Task<Void, Never>?
  private var finals: VoiceFinals
  private var observations: [PhoneSignalObservation] = []
  /// Bumped on every `start`/`end` so late finishes of an ended session are
  /// not published into a new one.
  private var generation = 0

  public init(
    channel: VoiceChannel,
    signaling: any PhoneSignaling,
    clock: @escaping @Sendable () -> Date = { Date() },
    idleTimeout: TimeInterval = VoiceSessionCore.defaultIdleTimeout,
    maximumUtterance: TimeInterval = VoiceSessionCore.defaultMaximumUtterance,
    finalRetention: TimeInterval = VoiceSessionCore.defaultFinalRetention
  ) {
    self.channel = channel
    self.signaling = signaling
    self.clock = clock
    self.idleTimeout = idleTimeout
    self.maximumUtterance = maximumUtterance
    self.finalRetention = finalRetention
    self.seq = channel.highestSeq()
    self.finals = channel.readFinals() ?? VoiceFinals()
  }

  public var isAlive: Bool { phase != .off }

  public var isListening: Bool {
    if case .listening = phase { return true }
    return false
  }

  /// Opens (or refreshes) the session with a prepared recognizer whose
  /// audio input is already running.
  public func start(recognizer: any VoiceRecognizing) {
    if phase != .off, self.recognizer === recognizer {
      touch()
      publishState()
      return
    }
    if phase != .off { end(reason: .user) }
    generation += 1
    self.recognizer = recognizer
    problem = nil
    lastEndReason = nil
    phase = .ready
    aliveUntil = clock().addingTimeInterval(idleTimeout)
    observations = [
      signaling.observe(PhoneSignal.voiceStart) { [weak self] in self?.handleStart() },
      signaling.observe(PhoneSignal.voiceStop) { [weak self] in self?.handleStop() },
    ]
    publishState()
  }

  /// Ends the session: the open utterance is dropped, transcripts are
  /// removed from the App Group, and the state says "no session".
  public func end(reason: EndReason = .user) {
    guard phase != .off else { return }
    generation += 1
    utterance?.cancel()
    utterance = nil
    listeningSince = nil
    lastFinish?.cancel()
    lastFinish = nil
    finishingCount = 0
    for observation in observations { observation.cancel() }
    observations = []
    recognizer = nil
    phase = .off
    aliveUntil = nil
    lastEndReason = reason
    channel.removePartial()
    if finals.scrub(before: .infinity) { try? channel.writeFinals(finals) }
    channel.writeLevel(0)
    publishState()
  }

  /// Blanks finals older than the retention window. The app calls this at
  /// launch, so a transcript left by a run the system ended is not kept.
  public func scrubExpiredFinals() {
    let cutoff = clock().timeIntervalSince1970 - finalRetention
    if finals.scrub(before: cutoff) { try? channel.writeFinals(finals) }
    if let partial = channel.readPartial(), (partial.at ?? 0) < cutoff, !isListening {
      channel.removePartial()
    }
  }

  /// Records a problem the keyboard should explain (the session is not
  /// usable). Pass nil to clear it.
  public func report(problem: VoiceProblem?) {
    self.problem = problem
    publishState()
  }

  /// Extends the idle timer (the user did something in the app).
  public func touch() {
    guard phase != .off else { return }
    aliveUntil = clock().addingTimeInterval(idleTimeout)
  }

  // MARK: - Keyboard commands

  public func handleStart() {
    guard phase == .ready, let recognizer else { return }
    seq += 1
    let number = seq
    let session = generation
    do {
      utterance = try recognizer.beginUtterance { [weak self] text in
        guard let self, self.generation == session else { return }
        self.publishPartial(seq: number, text: text)
      }
    } catch {
      publishFinal(seq: number, text: nil)
      publishState()
      return
    }
    phase = .listening(seq: number)
    listeningSince = clock()
    touch()
    publishState()
  }

  public func handleStop() {
    guard case .listening(let number) = phase, let current = utterance else { return }
    utterance = nil
    listeningSince = nil
    phase = .ready
    channel.writeLevel(0)
    touch()
    publishState()
    finishingCount += 1
    let previous = lastFinish
    let session = generation
    lastFinish = Task { @MainActor [weak self] in
      let text = await current.finish()
      // Finals are published in the order the utterances were spoken.
      await previous?.value
      guard let self, self.generation == session else { return }
      self.finishingCount -= 1
      self.publishFinal(seq: number, text: text)
      self.touch()
      self.publishState()
    }
  }

  /// Waits until every released utterance has its final (tests, and the
  /// app before it ends a session on purpose).
  public func waitForFinals() async {
    await lastFinish?.value
  }

  // MARK: - Timer

  /// Heartbeat and timeouts; the app calls this every
  /// `VoiceState.heartbeatInterval` seconds while a session is alive.
  public func tick() {
    guard phase != .off else { return }
    let now = clock()
    if let since = listeningSince, now.timeIntervalSince(since) >= maximumUtterance {
      handleStop()
    }
    if phase == .ready, finishingCount == 0, let aliveUntil, now >= aliveUntil {
      end(reason: .idle)
      return
    }
    if finals.scrub(before: now.timeIntervalSince1970 - finalRetention) {
      try? channel.writeFinals(finals)
    }
    publishState()
  }

  // MARK: - Publishing

  private func publishState() {
    let now = clock()
    let state = VoiceState(
      sessionAliveUntil: phase == .off ? 0 : (aliveUntil ?? now).timeIntervalSince1970,
      recording: isListening,
      seq: seq,
      heartbeatAt: now.timeIntervalSince1970,
      recognizer: phase == .off ? nil : recognizer?.kindName,
      problem: problem)
    try? channel.writeState(state)
    signaling.post(PhoneSignal.voiceHeartbeat)
    onChange?()
  }

  private func publishPartial(seq number: Int, text: String) {
    guard number > finals.seq else { return }
    try? channel.writePartial(
      VoiceText(seq: number, text: text, at: clock().timeIntervalSince1970))
    signaling.post(PhoneSignal.voicePartial)
  }

  private func publishFinal(seq number: Int, text: String?) {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let outcome: VoiceOutcome = text == nil ? .failed : (trimmed.isEmpty ? .empty : .text)
    let final = VoiceText(
      seq: number, text: outcome == .text ? trimmed : "", outcome: outcome,
      at: clock().timeIntervalSince1970)
    finals.append(final)
    try? channel.writeFinals(finals)
    if let partial = channel.readPartial(), partial.seq <= number { channel.removePartial() }
    signaling.post(PhoneSignal.voiceFinal)
    onFinal?(final)
  }
}
