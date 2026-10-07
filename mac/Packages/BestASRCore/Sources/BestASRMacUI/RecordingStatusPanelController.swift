import AppKit
import BestASRDictation
import Foundation
import MindloomDesign
import SwiftUI

public final class NonActivatingRecordingPanel: NSPanel {
  public override var canBecomeKey: Bool { false }
  public override var canBecomeMain: Bool { false }
}

/// What the dictation HUD shows for one rendered snapshot.
public enum RecordingCapsuleMode: Equatable, Sendable {
  case hidden
  case listening
  case paused
  case processing
  /// The take ended. `notice` nil: it was typed in (or its answer is shown
  /// in its own panel) and the HUD closes quietly; otherwise the one line
  /// the HUD says in the capsule's place.
  case finished(notice: FnHUDPresentation.Notice?)
  /// Esc (or a chord macOS owns): closes quietly.
  case cancelling

  public static func resolve(
    _ snapshot: DictationSessionSnapshot,
    facts: FnHUDTakeFacts = FnHUDTakeFacts()
  ) -> RecordingCapsuleMode {
    switch snapshot.phase {
    case .preparing, .recording: .listening
    case .paused: .paused
    case .finalizing, .recognizing, .polishing, .inserting: .processing
    case .completed, .failedRecoverable:
      .finished(notice: FnHUDPresentation.Notice.ending(for: snapshot, facts: facts))
    case .cancelling: .cancelling
    case .idle, .cancelled: .hidden
    }
  }

  var isActiveCapture: Bool { self == .listening || self == .paused }
}

/// What the App knows about a finished take beyond its snapshot.
public struct FnHUDTakeFacts: Equatable, Sendable {
  /// The take's words were put on the clipboard (it was not typed in).
  public var copied: Bool
  /// What was copied is the live draft (processing failed before the end).
  public var copiedDraft: Bool
  /// A translation was asked for and this language is not installed: the
  /// words went in as said, and the system's download is offered next.
  public var untranslatedLanguage: String?
  /// Demo mode (ALIGNMENT 根-10): the take's words reached the owner, so it
  /// leaves the demo library; the HUD says so (review v12-B #7). A demo take
  /// whose words did not reach the owner stays and says what any take says.
  public var leavesLibrary: Bool

  public init(
    copied: Bool = false, copiedDraft: Bool = false, untranslatedLanguage: String? = nil,
    leavesLibrary: Bool = false
  ) {
    self.copied = copied
    self.copiedDraft = copiedDraft
    self.untranslatedLanguage = untranslatedLanguage
    self.leavesLibrary = leavesLibrary
  }
}

/// What letting go of the dictation key means (d54; ALIGNMENT 收1-21, decided
/// 10/5): held at least 0.35 s it is push-to-talk and the release ends the
/// take; a shorter tap leaves the take listening hands-free until the key is
/// tapped again (which ends it) or Esc (which cancels it). A short tap never
/// drops the take.
public enum DictationKeyRelease: Equatable, Sendable {
  case endsTake
  case keepsListening

  public static let holdThreshold: Duration = .milliseconds(350)

  public static func after(held duration: Duration, threshold: Duration = holdThreshold) -> Self {
    duration >= threshold ? .endsTake : .keepsListening
  }

  /// How long the key was held: by the key events' own times when both are
  /// known, so main-thread work queued between press and release (the HUD's
  /// first install, starting the microphone) never turns a tap into a hold
  /// (review v12-B #11); else by when the two were handled.
  public static func heldDuration(
    pressedAt: TimeInterval?, releasedAt: TimeInterval?, handledApart: Duration
  ) -> Duration {
    if let pressedAt, let releasedAt, releasedAt >= pressedAt, releasedAt - pressedAt < 3_600 {
      return .milliseconds(Int64(((releasedAt - pressedAt) * 1_000).rounded()))
    }
    return handledApart
  }
}

/// The fn HUD's words, observed by the HUD's view (MAC-SPEC §8; v12 B1).
@MainActor
public final class FnHUDPresentation: ObservableObject {
  public enum Hint: Equatable, Sendable {
    /// 「麦克风没有打开 · 去设置」.
    case microphoneOff
    /// Mindloom Preview beside the user's bestASR App, which holds fn.
    case fnTaken
  }

  /// The one line a finished take says in the capsule's place (ALIGNMENT
  /// 收1-13): 「已复制 · ⌘V 粘贴」, 「没有听到」, or one plain sentence.
  public struct Notice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      /// Not typed in; the words are on the clipboard.
      case copied
      /// No speech in the take.
      case nothingHeard
      /// Something went wrong, said in one sentence.
      case failed
      /// Typed in, with one thing to know (the language was not installed).
      case note
    }

    public let kind: Kind
    /// An SF Symbol name.
    public let symbol: String
    public let text: String
    /// What the user can do, after 「 · 」 (「⌘V 粘贴」).
    public let detail: String?
    /// How long it stays.
    public let seconds: Double

    public init(kind: Kind, symbol: String, text: String, detail: String? = nil, seconds: Double) {
      self.kind = kind
      self.symbol = symbol
      self.text = text
      self.detail = detail
      self.seconds = seconds
    }

    public static let copied = Notice(
      kind: .copied, symbol: "doc.on.clipboard", text: "已拷贝", detail: "⌘V 粘贴", seconds: 2.5)
    public static let copiedDraft = Notice(
      kind: .copied, symbol: "doc.on.clipboard", text: "未能完成转写，已拷贝识别出的部分", detail: "⌘V 粘贴",
      seconds: 3.6)
    public static let nothingHeard = Notice(
      kind: .nothingHeard, symbol: "mic.slash", text: "未检测到语音", seconds: 2.0)
    public static let failed = Notice(
      kind: .failed, symbol: "exclamationmark.circle", text: "无法转写，录音已保存。可以在“历史”中重试",
      seconds: 3.6)
    public static let notTypedIn = Notice(
      kind: .failed, symbol: "exclamationmark.circle", text: "未能输入文字，文字已保存在“历史”中", seconds: 3.6)
    /// The App asked for the words and they were not seen in the field, and
    /// they are not on the clipboard (something else was copied since): the
    /// words may have gone in, so this does not say they did not.
    public static let unconfirmedNotCopied = Notice(
      kind: .failed, symbol: "questionmark.circle", text: "无法确认文字是否已输入，文字已保存在“历史”中",
      seconds: 3.6)

    public static func untranslated(_ language: String) -> Notice {
      Notice(kind: .note, symbol: "translate", text: "\(language)尚未下载，已输入原文", seconds: 3.0)
    }

    /// Demo mode, typed in: the take leaves the demo library.
    public static let demoTypedIn = Notice(
      kind: .note, symbol: "theatermasks", text: "演示中，此段不保存到历史", seconds: 2.2)
    /// Demo mode, copied: the words are on the clipboard and the take leaves
    /// the demo library.
    public static let demoCopied = Notice(
      kind: .copied, symbol: "doc.on.clipboard", text: "已拷贝；演示中，此段不保存到历史",
      detail: "⌘V 粘贴", seconds: 3.2)

    /// How a finished take ends. Typed in: quietly (nil). Never a quiet
    /// close — which reads as success — when nothing was typed in, except an
    /// 指令 whose answer is shown in its own panel.
    public static func ending(for snapshot: DictationSessionSnapshot, facts: FnHUDTakeFacts)
      -> Notice?
    {
      switch snapshot.phase {
      case .completed where snapshot.insertion?.inserted == true:
        return facts.untranslatedLanguage.map(untranslated)
          ?? (facts.leavesLibrary ? demoTypedIn : nil)
      case .completed:
        if snapshot.insertion?.failureReason == .nothingToInsert { return nil }
        guard facts.copied else {
          return snapshot.insertion?.failureReason == .unconfirmed
            ? unconfirmedNotCopied : notTypedIn
        }
        if facts.copiedDraft { return copiedDraft }
        return facts.leavesLibrary ? demoCopied : copied
      case .failedRecoverable where snapshot.failure?.isSilentTake == true:
        return nothingHeard
      case .failedRecoverable:
        guard facts.copied else { return failed }
        return facts.copiedDraft ? copiedDraft : copied
      default:
        return nil
      }
    }
  }

  /// The target language of 翻译 (「英」), or 「指令」, on the left of the
  /// capsule while the take listens (ALIGNMENT 收1-9, 收1-10).
  public struct Badge: Equatable, Sendable {
    public let text: String
    /// 「未下载」 when the language is not installed on this Mac.
    public let note: String?
    /// The spoken label (「翻译成英语」).
    public let label: String

    public init(text: String, note: String? = nil, label: String) {
      self.text = text
      self.note = note
      self.label = label
    }

    public static let command = Badge(text: "指令", label: "指令")

    public static func translation(into language: String, ready: Bool) -> Badge {
      Badge(
        text: shortName(language), note: ready ? nil : "未下载",
        label: ready ? "翻译成\(language)" : "翻译成\(language)，\(language)尚未下载")
    }

    /// 「英语」 → 「英」, 「简体中文」 → 「简」.
    public static func shortName(_ language: String) -> String {
      switch language {
      case "简体中文": "简"
      case "繁体中文": "繁"
      default: language.first.map(String.init) ?? language
      }
    }
  }

  /// The caption above the HUD is on (口述时显示文字).
  @Published public internal(set) var captionShown = false
  /// Words already committed (`ink`), then words still pending (`ink2`).
  @Published public internal(set) var committed = ""
  @Published public internal(set) var pending = ""
  /// Where `committed`, once it is the final text, differs from the live
  /// caption (offsets in characters; `CaptionRevision`).
  @Published public internal(set) var revised: [Range<Int>] = []
  @Published public internal(set) var hint: Hint?
  @Published public internal(set) var notice: Notice?
  @Published public internal(set) var badge: Badge?
  /// The kit's listener: pressed, released and fed the microphone level.
  public let listener: ListenerModel

  init(listener: ListenerModel) { self.listener = listener }
}

/// The Mac fn HUD (MAC-SPEC §8, Mac r2; v12 B1): a borderless, click-through
/// panel whose capsule sits 102 pt above the bottom of the active screen;
/// the kit's knot ↔ line crossfade with one voice arch fed by the input
/// level; the words above it while the take listens (口述时显示文字, on by
/// default, also when a text field has focus), replaced by the final text at
/// the end; the target language or 「指令」 on its left. How the take ends is
/// said in the capsule's place: typed in → it closes quietly; only copied →
/// 「已复制 · ⌘V 粘贴」 for 2.5 s; nothing heard → 「没有听到」; an error → one
/// plain sentence. No controls: fn finishes, Esc cancels.
///
/// Nothing here asks Accessibility anything: the press only shows the HUD.
///
/// The App supplies the SwiftUI content (`makeContent`, the package's
/// `FnHUDView` over `presentation`); without it nothing is drawn.
@MainActor
public final class RecordingStatusPanelController: NSObject {
  public let panel: NonActivatingRecordingPanel
  public private(set) var renderedSnapshot = DictationSessionSnapshot()
  public private(set) var renderedLiveText = ""
  /// The live draft the caption showed last while the take was being heard.
  private var liveDraft = ""
  public private(set) var renderedMode = RecordingCapsuleMode.hidden
  public let presentation: FnHUDPresentation
  /// Builds the HUD's view once (the App's `FnHUDView` host).
  public var makeContent: ((FnHUDPresentation) -> AnyView)? {
    didSet { installContent() }
  }
  /// 设置 › 通用 › 口述时显示文字 (on by default): the words show above the
  /// HUD during every take.
  public var showsCaptions = true
  /// The take's mode on the capsule's left (翻译 → 「英」, 指令); applied at
  /// the next render, which the App makes as soon as ⇧ or Space changes it.
  public var badge: FnHUDPresentation.Badge?

  private let onOpenRecord: @MainActor () -> Void
  private var hideTask: Task<Void, Never>?
  private var hintTask: Task<Void, Never>?

  /// The panel (holds the 520 pt caption and the capsule's shadow) and where
  /// the capsule's centre sits in it; must match the package's
  /// `FnHUDGeometry`.
  public static let panelSize = CGSize(width: 600, height: 172)
  public static let hudCentreFromTop: CGFloat = 124
  public static let hudAboveScreenBottom: CGFloat = 102
  public static let listenerCanvas = CGSize(width: 240, height: 96)

  public init(onOpenRecord: @escaping @MainActor () -> Void = {}) {
    self.onOpenRecord = onOpenRecord
    presentation = FnHUDPresentation(
      listener: ListenerModel(layout: .macHUD(size: Self.listenerCanvas)))
    panel = NonActivatingRecordingPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    configurePanel()
  }

  // MARK: - Rendering

  public func render(
    _ snapshot: DictationSessionSnapshot,
    liveText: String = "",
    facts: FnHUDTakeFacts = FnHUDTakeFacts()
  ) {
    let previous = renderedMode
    renderedSnapshot = snapshot
    renderedLiveText = liveText
    // What the live caption showed, before the final text replaces it.
    if [.recording, .paused, .finalizing, .recognizing].contains(snapshot.phase) {
      liveDraft = liveText
    }
    renderedMode = RecordingCapsuleMode.resolve(snapshot, facts: facts)
    let listener = presentation.listener
    switch renderedMode {
    case .listening, .paused:
      if !previous.isActiveCapture || listener.pressedAt == nil || listener.releasedAt != nil {
        begin()
      }
      presentation.badge = badge
      words(liveText, committed: false)
    case .processing:
      if listener.pressedAt != nil, listener.releasedAt == nil { listener.release() }
      presentation.badge = badge
      words(liveText, committed: false)
    case .finished(let notice):
      // The same ending rendered again (a status refresh) changes nothing.
      guard previous != renderedMode else { return }
      // Only a take the HUD showed says how it ended: a record finished
      // from the window (a retry) does not pop the HUD.
      let live = previous.isActiveCapture || previous == .processing
      finish(text: liveText, notice: live ? notice : nil)
    case .cancelling:
      guard previous != .cancelling else { return }
      cancelTake()
    case .hidden:
      if listener.pressedAt != nil, listener.releasedAt == nil {
        cancelTake()
      } else if presentation.hint == nil, presentation.notice == nil, hideTask == nil {
        orderOut()
      }
    }
  }

  /// The live microphone level as the capture reports it: 0…1 for
  /// −50…−10 dBFS (`AVAudioEngineMicrophoneCapture.normalizedLevel`); turned
  /// back into dBFS for the listener's own gate and span.
  public func updateInputLevel(_ level: Float) {
    presentation.listener.submitLevel(dBFS: Self.dBFS(fromNormalized: level))
  }

  public nonisolated static func dBFS(fromNormalized level: Float) -> Double {
    level <= 0 ? -120 : Double(min(level, 1)) * 40 - 50
  }

  /// The live level as RMS dBFS (gate −50 dB, span 34 dB).
  public func updateInputLevel(dBFS: Double) {
    presentation.listener.submitLevel(dBFS: dBFS)
  }

  /// A hint capsule at the HUD's place (M19: 3.6 s).
  public func showHint(_ hint: FnHUDPresentation.Hint) {
    hideTask?.cancel()
    hideTask = nil
    presentation.listener.reset()
    presentation.captionShown = false
    presentation.notice = nil
    presentation.badge = nil
    presentation.hint = hint
    // Only 去设置 takes a click.
    panel.ignoresMouseEvents = hint != .microphoneOff
    orderFront()
    hintTask?.cancel()
    hintTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(3.6))
      guard !Task.isCancelled, let self else { return }
      withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.26)) {
        self.presentation.hint = nil
      }
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      self.panel.ignoresMouseEvents = true
      if !self.renderedMode.isActiveCapture, self.presentation.notice == nil { self.orderOut() }
    }
  }

  public func dismiss() {
    hideTask?.cancel()
    hideTask = nil
    hintTask?.cancel()
    hintTask = nil
    presentation.listener.reset()
    presentation.hint = nil
    presentation.notice = nil
    presentation.badge = nil
    presentation.captionShown = false
    panel.orderOut(nil)
  }

  // MARK: - Stages

  private func begin() {
    hideTask?.cancel()
    hideTask = nil
    hintTask?.cancel()
    presentation.hint = nil
    presentation.notice = nil
    panel.ignoresMouseEvents = true
    presentation.listener.reset()
    presentation.listener.press()
    presentation.committed = ""
    presentation.pending = ""
    presentation.revised = []
    liveDraft = ""
    presentation.captionShown = showsCaptions
    orderFront()
  }

  private func words(_ text: String, committed: Bool) {
    guard presentation.captionShown else { return }
    let trimmed = Self.latestSentence(text, limit: 60)
    if committed {
      presentation.committed = trimmed
      presentation.pending = ""
      // Compared with the end of the live draft the caption last showed.
      presentation.revised = CaptionRevision.revisedRanges(
        live: String(liveDraft.suffix(trimmed.count * 2 + 8)), final: trimmed)
    } else {
      presentation.committed = ""
      presentation.pending = trimmed
      presentation.revised = []
    }
  }

  /// The take ended: the line crossfades back to the knot; the caption shows
  /// the final text (none when nothing was heard); the notice, if any, takes
  /// the capsule's place. All of it goes after 1.6 s, or the notice's time.
  private func finish(text: String, notice: FnHUDPresentation.Notice?) {
    let listener = presentation.listener
    if listener.pressedAt != nil, listener.releasedAt == nil { listener.release() }
    presentation.badge = nil
    if presentation.captionShown {
      let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if notice?.kind == .nothingHeard || said.isEmpty {
        presentation.captionShown = false
      } else {
        words(text, committed: true)
      }
    }
    if let notice {
      presentation.hint = nil
      presentation.notice = notice
      panel.ignoresMouseEvents = true
      orderFront()
    }
    scheduleHide(after: max(1.6, notice?.seconds ?? 0))
  }

  /// Esc: the line goes, the caption goes, nothing is said.
  private func cancelTake() {
    let listener = presentation.listener
    if listener.pressedAt != nil, listener.releasedAt == nil { listener.cancel() }
    presentation.captionShown = false
    presentation.badge = nil
    presentation.notice = nil
    scheduleHide(after: 1.25)
  }

  private func scheduleHide(after seconds: Double) {
    hideTask?.cancel()
    hideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, let self else { return }
      self.hideTask = nil
      guard !self.renderedMode.isActiveCapture else { return }
      withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24)) {
        self.presentation.captionShown = false
        self.presentation.notice = nil
      }
      try? await Task.sleep(for: .milliseconds(260))
      guard !Task.isCancelled, !self.renderedMode.isActiveCapture else { return }
      self.presentation.listener.reset()
      if self.presentation.hint == nil { self.orderOut() }
    }
  }

  // MARK: - Panel

  private func configurePanel() {
    panel.isFloatingPanel = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    panel.isMovableByWindowBackground = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.animationBehavior = .none
    panel.setAccessibilityIdentifier("bestASR.recordingPanel")
    panel.setAccessibilityLabel("Mindloom")
  }

  private func installContent() {
    guard let makeContent else { return }
    let host = NSHostingView(rootView: makeContent(presentation))
    host.frame = NSRect(origin: .zero, size: Self.panelSize)
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
  }

  private func orderFront() {
    position()
    panel.orderFrontRegardless()
  }

  private func orderOut() {
    panel.orderOut(nil)
  }

  /// Centred on the active screen (the one with the pointer), the capsule's
  /// centre 102 pt above the screen's bottom edge.
  private func position() {
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    guard let frame = screen?.frame else { return }
    let size = Self.panelSize
    let originY = frame.minY + Self.hudAboveScreenBottom - (size.height - Self.hudCentreFromTop)
    panel.setFrame(
      NSRect(x: (frame.midX - size.width / 2).rounded(), y: originY.rounded(), width: size.width,
        height: size.height),
      display: true)
  }

  /// The tail of the live draft: its last sentence, or its last `limit`
  /// characters.
  public nonisolated static func latestSentence(_ text: String, limit: Int = 40) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    let separators = CharacterSet(charactersIn: "。！？!?.\n")
    let pieces = trimmed.components(separatedBy: separators)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let last = pieces.last ?? trimmed
    return last.count > limit ? String(last.suffix(limit)) : last
  }
}
