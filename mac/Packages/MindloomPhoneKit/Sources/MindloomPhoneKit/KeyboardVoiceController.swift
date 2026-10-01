import Foundation

/// What happened when the keyboard tried to collect a final into the outbox.
public enum CollectResult: Equatable, Sendable {
  case collected
  /// There is no pairing yet: the text was typed but not collected.
  case notPaired
  case failed
}

/// The keyboard's half of the voice protocol (PHONE-CONTRACT §2), without
/// UIKit so every rule can be tested:
///
/// - **Hold to talk:** a press posts `.start`; releasing after
///   `tapThreshold` posts `.stop`.
/// - **Tap to toggle:** releasing sooner keeps listening; the next press
///   posts `.stop`.
/// - Every `.stop` expects one final. Finals newer than the last one handled
///   are inserted in order, and each inserted final becomes one outbox item.
///   A final this keyboard did not ask for (an older one, or one from another
///   keyboard instance) is never inserted.
/// - Without a live session the mic key says "打开织机开始语音"; without
///   full access it asks for it; when the app reports a problem it says so.
@MainActor
public final class KeyboardVoiceController {
  public enum Mic: Equatable, Sendable {
    /// Full access is off: the keyboard cannot reach the App Group.
    case needsFullAccess
    /// No live voice session: open the app to start one.
    case needsSession
    /// The session exists but cannot take dictation.
    case unavailable(VoiceProblem)
    case ready
    /// Listening; `toggle` is true after a short tap (tap again to stop).
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

  public struct Display: Equatable, Sendable {
    public var mic: Mic
    /// The live transcript while speaking, then the text just inserted.
    public var transcript: String
    /// True while `transcript` is live (not yet final).
    public var transcriptIsLive: Bool
    /// A one-line message (why nothing was inserted, and so on).
    public var notice: String?
    /// "已收进织机 · N"; nil when the phone is not paired.
    public var collected: Int?

    public init(
      mic: Mic, transcript: String = "", transcriptIsLive: Bool = false, notice: String? = nil,
      collected: Int? = nil
    ) {
      self.mic = mic
      self.transcript = transcript
      self.transcriptIsLive = transcriptIsLive
      self.notice = notice
      self.collected = collected
    }
  }

  public static let tapThreshold: TimeInterval = 0.35
  /// The app must confirm a start this fast, or the session is gone.
  public static let startAcknowledgeTimeout: TimeInterval = 2.5
  /// A released utterance must become final this fast.
  public static let finalTimeout: TimeInterval = 15

  public private(set) var display: Display {
    didSet { if display != oldValue { onChange?() } }
  }

  public var onChange: (@MainActor () -> Void)?

  private let channel: VoiceChannel?
  private let signaling: any PhoneSignaling
  private let clock: @Sendable () -> Date
  private let insert: @MainActor (String) -> Void
  private let collect: @MainActor (String) -> CollectResult
  private let collectedCount: @MainActor () -> Int?
  private let haptic: @MainActor (Haptic) -> Void

  private var pressStartedAt: Date?
  private var ignoreNextRelease = false
  private var pending = 0
  private var lastFinalSeq = 0
  private var startRequestedAt: Date?
  private var seqBeforeStart = 0
  private var startAcknowledged = false
  private var stopSentAt: Date?
  private var observations: [PhoneSignalObservation] = []

  /// - Parameters:
  ///   - channel: nil when full access is off (no App Group).
  ///   - insert: `textDocumentProxy.insertText`.
  ///   - collect: seals the text into the outbox.
  public init(
    channel: VoiceChannel?,
    signaling: any PhoneSignaling,
    clock: @escaping @Sendable () -> Date = { Date() },
    insert: @escaping @MainActor (String) -> Void,
    collect: @escaping @MainActor (String) -> CollectResult,
    collectedCount: @escaping @MainActor () -> Int?,
    haptic: @escaping @MainActor (Haptic) -> Void = { _ in }
  ) {
    self.channel = channel
    self.signaling = signaling
    self.clock = clock
    self.insert = insert
    self.collect = collect
    self.collectedCount = collectedCount
    self.haptic = haptic
    self.display = Display(
      mic: channel == nil ? .needsFullAccess : .needsSession, transcript: "",
      transcriptIsLive: false, notice: nil, collected: nil)
  }

  // MARK: - Lifecycle

  /// The keyboard appeared: start observing and read the current state.
  /// Finals already on disk are old and are never inserted.
  public func appear() {
    guard let channel else {
      display.mic = .needsFullAccess
      return
    }
    lastFinalSeq = max(lastFinalSeq, channel.readFinals()?.seq ?? 0)
    if observations.isEmpty {
      observations = [
        signaling.observe(PhoneSignal.voiceHeartbeat) { [weak self] in self?.refreshState() },
        signaling.observe(PhoneSignal.voicePartial) { [weak self] in self?.handlePartial() },
        signaling.observe(PhoneSignal.voiceFinal) { [weak self] in self?.handleFinals() },
      ]
    }
    display.collected = collectedCount()
    refreshState()
  }

  /// The keyboard went away: an open utterance is stopped so the app does
  /// not keep transcribing.
  public func disappear() {
    if case .listening = display.mic { sendStop() }
    for observation in observations { observation.cancel() }
    observations = []
  }

  // MARK: - The mic key

  public func pressDown() {
    guard channel != nil else { return }
    switch display.mic {
    case .ready, .finishing:
      guard sessionIsAlive() else {
        display.mic = .needsSession
        return
      }
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
    case .listening(toggle: true):
      ignoreNextRelease = true
      sendStop()
    default:
      break
    }
  }

  public func pressUp() {
    if ignoreNextRelease {
      ignoreNextRelease = false
      return
    }
    guard case .listening(toggle: false) = display.mic, let started = pressStartedAt else { return }
    pressStartedAt = nil
    if clock().timeIntervalSince(started) < Self.tapThreshold {
      display.mic = .listening(toggle: true)
    } else {
      sendStop()
    }
  }

  /// The touch left the key and was cancelled by the system.
  public func pressCancelled() {
    if case .listening = display.mic { sendStop() }
    ignoreNextRelease = false
    pressStartedAt = nil
  }

  private func sendStop() {
    signaling.post(PhoneSignal.voiceStop)
    pending += 1
    stopSentAt = clock()
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
      break
    default:
      display.mic = idleMic(state)
    }
  }

  public func handlePartial() {
    guard let partial = channel?.readPartial(), partial.seq > lastFinalSeq else { return }
    if partial.seq > seqBeforeStart { startAcknowledged = true }
    switch display.mic {
    case .listening, .finishing:
      display.transcript = partial.text
      display.transcriptIsLive = true
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
        deliver(final)
      } else if case .listening = display.mic, final.seq > seqBeforeStart {
        // The app ended this utterance by itself (it failed to start, or
        // it ran too long): it is over even though the key is still down.
        pressStartedAt = nil
        startRequestedAt = nil
        ignoreNextRelease = false
        deliver(final)
        display.mic = idleMic(channel?.readState())
      }
    }
    if pending == 0, display.mic == .finishing {
      stopSentAt = nil
      display.mic = idleMic(channel?.readState())
    }
  }

  private func deliver(_ final: VoiceText) {
    switch final.outcome ?? (final.text.isEmpty ? .empty : .text) {
    case .text where !final.text.isEmpty:
      insert(final.text)
      display.transcript = final.text
      display.transcriptIsLive = false
      switch collect(final.text) {
      case .collected:
        display.notice = nil
      case .notPaired:
        display.notice = KeyboardCopy.notPaired
      case .failed:
        display.notice = KeyboardCopy.notCollected
      }
      display.collected = collectedCount()
      haptic(.inserted)
    case .failed:
      display.transcript = ""
      display.transcriptIsLive = false
      display.notice = KeyboardCopy.recognitionFailed
      haptic(.problem)
    default:
      display.transcript = ""
      display.transcriptIsLive = false
      display.notice = KeyboardCopy.heardNothing
    }
  }

  // MARK: - Timeouts

  /// Called about twice a second while listening or finishing.
  public func tick() {
    let now = clock()
    if case .listening = display.mic, !startAcknowledged, let requested = startRequestedAt,
      now.timeIntervalSince(requested) >= Self.startAcknowledgeTimeout
    {
      refreshState()
      if !startAcknowledged {
        // The app never took the start: the session is gone.
        signaling.post(PhoneSignal.voiceStop)
        startRequestedAt = nil
        pressStartedAt = nil
        ignoreNextRelease = false
        display.transcript = ""
        display.transcriptIsLive = false
        display.notice = KeyboardCopy.appNotResponding
        display.mic = idleMic(channel?.readState())
        haptic(.problem)
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
        display.transcriptIsLive = false
        display.notice = KeyboardCopy.noFinal
        display.mic = idleMic(channel?.readState())
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
    guard let state, state.isAlive(at: clock()) else { return .needsSession }
    if let problem = state.problem { return .unavailable(problem) }
    return .ready
  }
}

/// The keyboard's fixed strings (short, plain, no exclamation marks).
public enum KeyboardCopy {
  public static let openApp = "打开织机开始语音"
  public static let openAppDetail = "开一次，10 分钟内随时按住说话"
  /// Shown when opening the app from the keyboard is not possible.
  public static let openAppInstruction = "先打开「织机」点「开始语音」，再回来按住说话"
  public static let needsFullAccess = "请在设置里为织机键盘打开「允许完全访问」"
  public static let holdToTalk = "按住说话"
  public static let holdToTalkDetail = "松开就写进去 · 轻点可连续说"
  public static let releaseToFinish = "松开结束"
  public static let tapToFinish = "轻点结束"
  public static let finishing = "正在写入…"
  public static let notPaired = "还没连接 Mac，这句没有收进织机"
  public static let notCollected = "这句已写入，但没能收进织机"
  public static let recognitionFailed = "这句没能识别，请再说一次"
  public static let heardNothing = "没听清，请再说一次"
  public static let appNotResponding = "织机没有响应，请打开织机重新开始语音"
  public static let noFinal = "没有收到文字，请再说一次"
  public static func collected(_ count: Int) -> String { "已收进织机 · \(count)" }
  public static let notPairedStatus = "未连接 Mac"

  public static func problem(_ problem: VoiceProblem) -> String {
    switch problem {
    case .microphoneDenied: "织机没有麦克风权限，请在设置里打开"
    case .speechDenied: "织机没有语音识别权限，请在设置里打开"
    case .recognizerUnavailable: "这台手机暂时不能在本机识别中文"
    case .preparingModel: "正在准备中文语音，请稍候"
    case .interrupted: "麦克风被占用，结束通话后再试"
    }
  }
}
