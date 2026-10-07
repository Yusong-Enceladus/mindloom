import Foundation

/// What happened when the keyboard tried to collect a final into the outbox (older keyboards;
/// keyboard speech is now kept for the Mac by the app, see `VoiceAck`).
public enum CollectResult: Equatable, Sendable {
  case collected
  /// There is no pairing yet: the text was typed but not collected.
  case notPaired
  case failed
}

/// How the keyboard writes into the host's field (`textDocumentProxy`), injected so the rules
/// can be tested without UIKit (PHONE-SPEC §5.13 "Text into the host").
@MainActor
public struct KeyboardTextHost {
  /// `setMarkedText(text, selectedRange: (text.count, 0))`: the live words, underlined by the host.
  public var mark: (String) -> Void
  /// `setMarkedText(final)` then `unmarkText()`: the final replaces the marked text.
  public var insert: (String) -> Void
  /// `setMarkedText("")` then `unmarkText()`.
  public var clearMarked: () -> Void
  /// `documentContextBeforeInput`.
  public var textBeforeCursor: () -> String?
  /// `deleteBackward()` this many times.
  public var deleteBackward: (Int) -> Void

  public init(
    mark: @escaping (String) -> Void, insert: @escaping (String) -> Void,
    clearMarked: @escaping () -> Void, textBeforeCursor: @escaping () -> String?,
    deleteBackward: @escaping (Int) -> Void
  ) {
    self.mark = mark
    self.insert = insert
    self.clearMarked = clearMarked
    self.textBeforeCursor = textBeforeCursor
    self.deleteBackward = deleteBackward
  }
}

/// The keyboard's half of the voice protocol (PHONE-CONTRACT §2, PHONE-SPEC §7.1–7.2), without
/// UIKit so every rule can be tested:
///
/// - **Hold to talk:** a press posts `.start`; the live words go into the field as marked text;
///   releasing posts `.stop` and the final replaces the marked text (with 「。」), committed no
///   earlier than release + 0.35 s.
/// - **Tap to latch:** a press shorter than 0.30 s that moved less than 12 pt keeps listening;
///   the next press (or ✓) finishes.
/// - **Cancel (×):** posts `.cancel`; the marked text is removed and nothing is inserted.
/// - Every `.stop` expects one final. Finals newer than the last one handled are inserted in
///   order. A final this keyboard did not ask for (an older one, or one from another keyboard
///   instance) is never inserted.
/// - Each inserted final is acknowledged in `voice/ack`; the **app** then keeps it for the Mac
///   when 「键盘说的话也送到 Mac」 is on. 「撤销」 within the window deletes the text from the field
///   (if it is still right before the cursor) and acknowledges the withdrawal.
/// - Without a live session the key says 「轻点开启语音」; with the microphone off in iOS Settings
///   it says 「麦克风没有打开 去设置」; without Full Access the keyboard cannot reach the app.
@MainActor
public final class KeyboardVoiceController {
  public enum Mic: Equatable, Sendable {
    /// Full Access is off: the keyboard cannot reach the app.
    case needsFullAccess
    /// No live voice session: open the app to start one.
    case needsSession
    /// The microphone is off in iOS Settings.
    case microphoneDenied
    /// The session exists but cannot take dictation.
    case unavailable(VoiceProblem)
    case ready
    /// Listening; `toggle` is true after a short tap (tap again or ✓ to finish).
    case listening(toggle: Bool)
    /// Released; waiting for the final text.
    case finishing
  }

  public enum Haptic: Equatable, Sendable {
    case start
    case stop
    case inserted
    case problem
  }

  /// How a press ended, for the listening animation: 「已收好」 only after `.inserted`.
  public enum Outcome: Equatable, Sendable {
    case inserted(String)
    /// Nothing was heard (or recognition failed, or no final came): the mark goes back to rest.
    case nothing
    /// The user cancelled (×).
    case cancelled
  }

  public struct Display: Equatable, Sendable {
    public var mic: Mic
    /// The live transcript while speaking, then the text just inserted.
    public var transcript: String
    /// True while `transcript` is live (not yet final).
    public var transcriptIsLive: Bool
    /// Why nothing was inserted (diagnostics and VoiceOver; the panel shows no notice line).
    public var notice: String?

    public init(
      mic: Mic, transcript: String = "", transcriptIsLive: Bool = false, notice: String? = nil
    ) {
      self.mic = mic
      self.transcript = transcript
      self.transcriptIsLive = transcriptIsLive
      self.notice = notice
    }
  }

  /// A press shorter than this (that moved less than `tapSlop`) latches.
  public nonisolated static let tapThreshold: TimeInterval = 0.30
  public nonisolated static let tapSlop: Double = 12
  /// The final is committed no earlier than this after the release (PHONE-SPEC §7.1).
  public nonisolated static let commitDelay: TimeInterval = 0.35
  /// 「撤销」 stays possible this long after the commit (release + 0.9 + 3.0 − 0.35).
  public nonisolated static let undoWindow: TimeInterval = 3.55
  /// The app must confirm a start this fast, or the session is gone.
  public nonisolated static let startAcknowledgeTimeout: TimeInterval = 2.5
  /// A released utterance must become final this fast.
  public nonisolated static let finalTimeout: TimeInterval = 15

  public private(set) var display: Display {
    didSet { if display != oldValue { onChange?() } }
  }

  public var onChange: (@MainActor () -> Void)?
  public var onOutcome: (@MainActor (Outcome) -> Void)?

  private let channel: VoiceChannel?
  private let signaling: any PhoneSignaling
  private let clock: @Sendable () -> Date
  private let host: KeyboardTextHost
  private let after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
  private let haptic: @MainActor (Haptic) -> Void

  private var pressStartedAt: Date?
  private var ignoreNextRelease = false
  private var pending = 0
  private var lastFinalSeq = 0
  private var startRequestedAt: Date?
  private var seqBeforeStart = 0
  private var startAcknowledged = false
  private var stopSentAt: Date?
  private var releasedAt: Date?
  private var ack = VoiceAck()
  /// The last insertion that 「撤销」 may still take back.
  private var undoable: (seq: Int, text: String, at: Date)?
  private var observations: [PhoneSignalObservation] = []

  /// - Parameters:
  ///   - channel: nil when the keyboard cannot reach the app (no Full Access).
  ///   - after: runs a body after a delay (the commit delay); tests run it at once.
  public init(
    channel: VoiceChannel?,
    signaling: any PhoneSignaling,
    clock: @escaping @Sendable () -> Date = { Date() },
    host: KeyboardTextHost,
    after: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void =
      KeyboardVoiceController.dispatchAfter,
    haptic: @escaping @MainActor (Haptic) -> Void = { _ in }
  ) {
    self.channel = channel
    self.signaling = signaling
    self.clock = clock
    self.host = host
    self.after = after
    self.haptic = haptic
    self.display = Display(mic: channel == nil ? .needsFullAccess : .needsSession)
  }

  public static func dispatchAfter(
    _ delay: TimeInterval, _ body: @escaping @MainActor () -> Void
  ) {
    guard delay > 0 else { return body() }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      body()
    }
  }

  // MARK: - Lifecycle

  /// The keyboard appeared: start observing and read the current state. Finals already in the
  /// channel are old and are never inserted.
  public func appear() {
    guard let channel else {
      display.mic = .needsFullAccess
      return
    }
    lastFinalSeq = max(lastFinalSeq, channel.readFinals()?.seq ?? 0)
    ack = channel.readAck() ?? VoiceAck()
    if observations.isEmpty {
      observations = [
        signaling.observe(PhoneSignal.voiceHeartbeat) { [weak self] in self?.refreshState() },
        signaling.observe(PhoneSignal.voicePartial) { [weak self] in self?.handlePartial() },
        signaling.observe(PhoneSignal.voiceFinal) { [weak self] in self?.handleFinals() },
      ]
    }
    refreshState()
  }

  /// The keyboard went away: an open utterance is stopped so the app does not keep transcribing;
  /// its final is not inserted anywhere (the field is gone).
  public func disappear() {
    switch display.mic {
    case .listening:
      signaling.post(PhoneSignal.voiceCancel)
      host.clearMarked()
    case .finishing:
      // The partial must not stay behind as marked text (the host may commit it).
      host.clearMarked()
    default:
      if display.transcriptIsLive { host.clearMarked() }
    }
    pending = 0
    pressStartedAt = nil
    ignoreNextRelease = false
    undoable = nil
    for observation in observations { observation.cancel() }
    observations = []
    if channel != nil { display.mic = .needsSession }
  }

  // MARK: - The speak key

  /// Touch down on the speak key. Returns true when listening started (the animation presses).
  @discardableResult
  public func pressDown() -> Bool {
    guard channel != nil else { return false }
    switch display.mic {
    case .ready, .finishing:
      guard sessionIsAlive() else {
        display.mic = idleMic(channel?.readState())
        return false
      }
      undoable = nil
      seqBeforeStart = channel?.readState()?.seq ?? 0
      startAcknowledged = false
      startRequestedAt = clock()
      pressStartedAt = clock()
      signaling.post(PhoneSignal.voiceStart)
      display.mic = .listening(toggle: false)
      display.transcript = ""
      display.transcriptIsLive = true
      display.notice = nil
      haptic(.start)
      return true
    case .listening(toggle: true):
      ignoreNextRelease = true
      sendStop()
      return false
    default:
      return false
    }
  }

  /// Touch up. `moved` is how far the finger travelled (pt). Returns true when the press latched
  /// (tap mode: still listening).
  @discardableResult
  public func pressUp(moved: Double = 0) -> Bool {
    if ignoreNextRelease {
      ignoreNextRelease = false
      return false
    }
    guard case .listening(toggle: false) = display.mic, let started = pressStartedAt else {
      return false
    }
    pressStartedAt = nil
    if clock().timeIntervalSince(started) < Self.tapThreshold, moved < Self.tapSlop {
      display.mic = .listening(toggle: true)
      return true
    }
    sendStop()
    return false
  }

  /// ✓ in tap mode.
  public func done() {
    guard case .listening = display.mic else { return }
    ignoreNextRelease = false
    sendStop()
  }

  /// × (or the touch was cancelled by the system): nothing is inserted.
  public func cancel() {
    guard case .listening = display.mic else { return }
    signaling.post(PhoneSignal.voiceCancel)
    host.clearMarked()
    ignoreNextRelease = false
    pressStartedAt = nil
    startRequestedAt = nil
    display.transcript = ""
    display.transcriptIsLive = false
    display.mic = idleMic(channel?.readState())
    onOutcome?(.cancelled)
  }

  /// 「撤销」: removes the text just inserted (if it is still right before the cursor) and tells the
  /// app to take the item back. Returns false when the window has closed.
  @discardableResult
  public func undo() -> Bool {
    guard let undoable, clock().timeIntervalSince(undoable.at) <= Self.undoWindow + 0.5 else {
      return false
    }
    self.undoable = nil
    if host.textBeforeCursor()?.hasSuffix(undoable.text) == true {
      host.deleteBackward(undoable.text.count)
    }
    ack.withdraw(undoable.seq)
    try? channel?.writeAck(ack)
    signaling.post(PhoneSignal.voiceAck)
    display.transcript = ""
    return true
  }

  /// The undo window closed (the key went back to 「按住说话」).
  public func settle() {
    undoable = nil
  }

  public var canUndo: Bool { undoable != nil }

  private func sendStop() {
    signaling.post(PhoneSignal.voiceStop)
    pending += 1
    stopSentAt = clock()
    releasedAt = clock()
    startRequestedAt = nil
    pressStartedAt = nil
    display.mic = .finishing
    haptic(.stop)
  }

  // MARK: - Signals from the app

  public func refreshState() {
    guard let channel else { return }
    let state = channel.readState()
    if let state, state.recording, state.seq > seqBeforeStart { startAcknowledged = true }
    switch display.mic {
    case .listening, .finishing:
      if state?.microphoneDenied == true || !(state?.isAlive(at: clock()) ?? false) {
        // The session ended under the finger (idle, 结束, microphone revoked).
        host.clearMarked()
        pending = 0
        pressStartedAt = nil
        ignoreNextRelease = false
        display.transcript = ""
        display.transcriptIsLive = false
        display.mic = idleMic(state)
        onOutcome?(.nothing)
      }
    default:
      display.mic = idleMic(state)
    }
  }

  public func handlePartial() {
    guard let partial = channel?.readPartial(), partial.seq > lastFinalSeq else { return }
    if partial.seq > seqBeforeStart { startAcknowledged = true }
    switch display.mic {
    case .listening:
      guard partial.seq > seqBeforeStart else { return }
      display.transcript = partial.text
      display.transcriptIsLive = true
      host.mark(partial.text)
    case .finishing:
      display.transcript = partial.text
      display.transcriptIsLive = true
      host.mark(partial.text)
    default:
      break
    }
  }

  public func handleFinals() {
    guard let finals = channel?.readFinals() else { return }
    for final in finals.entries where final.seq > lastFinalSeq {
      lastFinalSeq = final.seq
      if pending > 0 {
        pending -= 1
        if final.seq <= seqBeforeStart {
          // An utterance older than the newest press: it must not touch that press's live words,
          // animation or outcome.
          deliverOlder(final)
        } else {
          deliver(final)
        }
      } else if case .listening = display.mic, final.seq > seqBeforeStart {
        // The app ended this utterance by itself (it failed to start, or it ran too long): it is
        // over even though the key is still down.
        pressStartedAt = nil
        startRequestedAt = nil
        ignoreNextRelease = false
        display.mic = idleMic(channel?.readState())
        deliver(final)
      }
    }
    if pending == 0, display.mic == .finishing {
      stopSentAt = nil
      display.mic = idleMic(channel?.readState())
    }
  }

  private func deliver(_ final: VoiceText) {
    let text = PhoneTextRules.finalized(final.text)
    switch final.outcome ?? (text.isEmpty ? .empty : .text) {
    case .text where !text.isEmpty:
      let wait = (releasedAt ?? clock()).addingTimeInterval(Self.commitDelay)
        .timeIntervalSince(clock())
      after(max(0, wait)) { [weak self] in self?.commit(text, seq: final.seq) }
    case .failed:
      host.clearMarked()
      display.transcript = ""
      display.transcriptIsLive = false
      display.notice = KeyboardCopy.recognitionFailed
      haptic(.problem)
      onOutcome?(.nothing)
    default:
      host.clearMarked()
      display.transcript = ""
      display.transcriptIsLive = false
      display.notice = KeyboardCopy.heardNothing
      onOutcome?(.nothing)
    }
  }

  /// The final of an utterance released before the newest press: its text still goes into the
  /// field (before the live words) and to the app, quietly.
  private func deliverOlder(_ final: VoiceText) {
    let text = PhoneTextRules.finalized(final.text)
    guard final.outcome ?? (text.isEmpty ? .empty : .text) == .text, !text.isEmpty else { return }
    let wait = (releasedAt ?? clock()).addingTimeInterval(Self.commitDelay)
      .timeIntervalSince(clock())
    after(max(0, wait)) { [weak self] in self?.commitOlder(text, seq: final.seq) }
  }

  private func commitOlder(_ text: String, seq: Int) {
    host.insert(text)
    if display.transcriptIsLive, !display.transcript.isEmpty { host.mark(display.transcript) }
    ack.insert(seq, at: clock().timeIntervalSince1970)
    try? channel?.writeAck(ack)
    signaling.post(PhoneSignal.voiceAck)
  }

  private func commit(_ text: String, seq: Int) {
    // A new press came during the commit delay: this text no longer owns the key.
    if seq <= seqBeforeStart {
      commitOlder(text, seq: seq)
      return
    }
    host.insert(text)
    display.transcript = text
    display.transcriptIsLive = false
    display.notice = nil
    let now = clock()
    undoable = (seq, text, now)
    ack.insert(seq, at: now.timeIntervalSince1970)
    try? channel?.writeAck(ack)
    signaling.post(PhoneSignal.voiceAck)
    haptic(.inserted)
    onOutcome?(.inserted(text))
  }

  // MARK: - Timeouts

  /// Called about twice a second while listening, finishing or ready.
  public func tick() {
    let now = clock()
    if case .listening = display.mic, !startAcknowledged, let requested = startRequestedAt,
      now.timeIntervalSince(requested) >= Self.startAcknowledgeTimeout
    {
      refreshState()
      if !startAcknowledged, case .listening = display.mic {
        // The app never took the start: the session is gone.
        signaling.post(PhoneSignal.voiceStop)
        startRequestedAt = nil
        pressStartedAt = nil
        ignoreNextRelease = false
        host.clearMarked()
        display.transcript = ""
        display.transcriptIsLive = false
        display.notice = KeyboardCopy.appNotResponding
        display.mic = idleMic(channel?.readState())
        haptic(.problem)
        onOutcome?(.nothing)
        return
      }
    }
    if display.mic == .finishing, let stopped = stopSentAt,
      now.timeIntervalSince(stopped) >= Self.finalTimeout
    {
      handleFinals()
      if display.mic == .finishing {
        pending = 0
        stopSentAt = nil
        host.clearMarked()
        display.transcriptIsLive = false
        display.notice = KeyboardCopy.noFinal
        display.mic = idleMic(channel?.readState())
        onOutcome?(.nothing)
      }
    }
    if display.mic == .ready, !sessionIsAlive() { display.mic = idleMic(channel?.readState()) }
  }

  /// Whether the controller wants `tick()` calls.
  public var needsTicks: Bool {
    switch display.mic {
    case .listening, .finishing, .ready: true
    default: false
    }
  }

  // MARK: - Helpers

  private func sessionIsAlive() -> Bool {
    channel?.readState()?.isAlive(at: clock()) ?? false
  }

  private func idleMic(_ state: VoiceState?) -> Mic {
    guard channel != nil else { return .needsFullAccess }
    if state?.microphoneDenied == true { return .microphoneDenied }
    guard let state, state.isAlive(at: clock()) else { return .needsSession }
    if let problem = state.problem {
      return problem == .microphoneDenied ? .microphoneDenied : .unavailable(problem)
    }
    return .ready
  }
}

/// The keyboard's fixed strings (PHONE-SPEC §6.4; short, plain, no exclamation marks).
public enum KeyboardCopy {
  public static let holdToTalk = "按住说话"
  public static let saved = "已保存"
  public static let undo = "撤销"
  public static let openApp = "轻点开启语音"
  public static let microphoneOff = "未允许访问麦克风"
  public static let openSettings = "打开设置"
  /// Shown when opening the app from the keyboard is not possible (PHONE-SPEC §5.10 footer).
  public static let needsFullAccess = "打开“允许完全访问”后，才能将口述发送到 Mac。"
  public static let space = "空格"
  public static let newline = "换行"
  public static let delete = "删除"
  public static let cancel = "取消"
  public static let finish = "完成"
  public static let recognitionFailed = "未能识别这句话，请再说一次"
  public static let heardNothing = "未能听清，请再说一次"
  public static let appNotResponding = "Mindloom 没有响应。请打开 Mindloom 后重试"
  public static let noFinal = "未收到文字，请再说一次"

  public static func problem(_ problem: VoiceProblem) -> String {
    switch problem {
    case .microphoneDenied: microphoneOff
    case .speechDenied: "未允许语音识别"
    case .recognizerUnavailable: "这台 iPhone 暂时无法在本机识别中文"
    case .preparingModel: "正在准备中文语音，请稍候"
    case .interrupted: "麦克风正被占用。请结束通话后重试"
    }
  }
}
