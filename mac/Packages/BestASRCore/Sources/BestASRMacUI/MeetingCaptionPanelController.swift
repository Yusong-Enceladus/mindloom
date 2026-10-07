import AppKit
import Foundation
import SwiftUI

// The meeting's caption strip (ALIGNMENT 收2-3, v12 1C): while a meeting is
// recorded, a small strip at the bottom of the screen shows the last two
// lines of its live text, like the dictation HUD a panel that never takes
// the focus; the user can drag it and close it. When the meeting ends it
// says it is saved and, once the whole recording has been recognised again,
// shows the recomputed text for a few seconds. The App supplies the SwiftUI
// content (`makeContent`, the package's `MeetingCaptionView`).

/// One line of the strip.
public struct MeetingCaptionLine: Equatable, Sendable {
  /// 「说话人 A」, 「我」; nil when the line names nobody.
  public let speaker: String?
  public let words: String
  /// Still being recognised (drawn lighter).
  public let pending: Bool

  public init(speaker: String? = nil, words: String, pending: Bool = false) {
    self.speaker = speaker
    self.words = words
    self.pending = pending
  }
}

/// The last lines of a meeting's live text. The meeting runtime writes one
/// line per turn: 「说话人 A  …」 or 「我  …」 (two spaces after the name), and
/// while a sentence is being recognised a last 「正在识别  …」 line; before
/// anyone is told apart, the text is one running line.
public enum MeetingCaptionLines {
  static let pendingLabel = "正在识别"

  public static func last(_ count: Int = 2, of text: String) -> [MeetingCaptionLine] {
    guard count > 0 else { return [] }
    let lines =
      text
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return lines.suffix(count).map(line).filter { !$0.words.isEmpty }
  }

  static func line(_ raw: String) -> MeetingCaptionLine {
    guard let gap = raw.range(of: "  ") else { return MeetingCaptionLine(words: raw) }
    let head = String(raw[..<gap.lowerBound])
    let rest = raw[gap.upperBound...].trimmingCharacters(in: .whitespaces)
    if head == pendingLabel { return MeetingCaptionLine(words: rest, pending: true) }
    if head == "我" || (head.hasPrefix("说话人 ") && head.count <= 12) {
      return MeetingCaptionLine(speaker: head, words: rest)
    }
    return MeetingCaptionLine(words: raw)
  }
}

/// What the strip shows, observed by its view.
@MainActor
public final class MeetingCaptionPresentation: ObservableObject {
  public enum Stage: Equatable, Sendable {
    case listening
    case paused
    /// Ended and saved; the whole recording is being recognised again.
    case saving
    /// The recomputed text (shown for a few seconds).
    case saved
    /// Saved; it becomes text once the recognition models are ready.
    case waitingForModels
    /// Saved; recognising it failed (it can be tried again).
    case failed
  }

  @Published public internal(set) var stage: Stage = .listening
  /// At most two.
  @Published public internal(set) var lines: [MeetingCaptionLine] = []

  public init() {}

  /// The few words right of the lines: 「已暂停」, 「正在转成文字」, 「已收好」.
  public var status: String? {
    switch stage {
    case .listening, .waitingForModels, .failed: nil
    case .paused: "已暂停"
    case .saving: "正在转写"
    case .saved: "已保存"
    }
  }

  /// The orange dot of a recording (as on the menu bar's capsule).
  public var live: Bool { stage == .listening }

  /// The lines for a stage: the live text's last two, the recomputed text's
  /// last two, or what happened in two plain lines.
  static func lines(for stage: Stage, text: String) -> [MeetingCaptionLine] {
    switch stage {
    case .listening, .paused, .saving, .saved:
      return MeetingCaptionLines.last(2, of: text)
    case .waitingForModels:
      return [
        MeetingCaptionLine(words: "录音已保存"),
        MeetingCaptionLine(words: "识别模型就绪后开始转写"),
      ]
    case .failed:
      return [
        MeetingCaptionLine(words: "无法转写，录音已保存"),
        MeetingCaptionLine(words: "可以在“历史”中重试"),
      ]
    }
  }
}

/// Where the user put the strip, kept across meetings by the App.
public struct MeetingCaptionPlacement {
  public var load: () -> CGPoint?
  public var save: (CGPoint) -> Void

  public init(load: @escaping () -> CGPoint?, save: @escaping (CGPoint) -> Void) {
    self.load = load
    self.save = save
  }

  /// Nothing kept (tests).
  public static var none: MeetingCaptionPlacement { .init(load: { nil }, save: { _ in }) }
}

/// The caption strip's panel: non-activating (it never takes the focus from
/// the meeting App), on every Space and over full-screen Apps, mouse events
/// on (drag anywhere, ✕ closes).
@MainActor
public final class MeetingCaptionPanelController: NSObject {
  public let panel: NonActivatingRecordingPanel
  public let presentation = MeetingCaptionPresentation()
  /// Builds the strip's view once (the App's `MeetingCaptionView` host).
  public var makeContent: ((MeetingCaptionPresentation) -> AnyView)? {
    didSet { installContent() }
  }
  public var placement: MeetingCaptionPlacement
  /// ✕ was clicked; true when it was while the meeting records (the App
  /// turns the strip off until 显示字幕), false on an ending (only that
  /// ending is put away).
  public var onClose: (@MainActor (_ turnsOff: Bool) -> Void)?
  public private(set) var isShown = false

  public nonisolated static let panelSize = CGSize(width: 600, height: 64)
  /// The strip's bottom edge above the bottom of the screen's visible area
  /// (above the Dock).
  public nonisolated static let bottomInset: CGFloat = 16
  /// How long an ending stays: the recomputed text, or what happened.
  public var savedSeconds = 4.0
  public var noticeSeconds = 5.0

  private var hideTask: Task<Void, Never>?
  private var placing = false
  private var moveObserver: NSObjectProtocol?

  public init(placement: MeetingCaptionPlacement = .none) {
    self.placement = placement
    panel = NonActivatingRecordingPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isMovable = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.ignoresMouseEvents = false
    panel.animationBehavior = .utilityWindow
    panel.setAccessibilityIdentifier("mindloom.meetingCaptions")
    panel.setAccessibilityLabel("会议字幕")
    // A drag is the window server's: wherever the panel ends up is kept,
    // except where this controller put it.
    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: panel, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.moved() }
    }
  }

  /// Shows a stage with the meeting's text: the live text while it records
  /// (and while it is being saved), the recomputed text once saved. An
  /// ending (saved, waiting for the models, failed) goes by itself.
  public func update(_ stage: MeetingCaptionPresentation.Stage, text: String = "") {
    hideTask?.cancel()
    hideTask = nil
    let lines = MeetingCaptionPresentation.lines(for: stage, text: text)
    if presentation.stage != stage { presentation.stage = stage }
    // While saving, the live lines stay as they were when nothing new came.
    if stage != .saving || !lines.isEmpty, presentation.lines != lines {
      presentation.lines = lines
    }
    if !isShown {
      position()
      panel.orderFrontRegardless()
      isShown = true
    }
    switch stage {
    case .saved: hide(after: savedSeconds)
    case .waitingForModels, .failed: hide(after: noticeSeconds)
    case .listening, .paused, .saving: break
    }
  }

  public func hide() {
    hideTask?.cancel()
    hideTask = nil
    guard isShown else { return }
    panel.orderOut(nil)
    isShown = false
  }

  /// ✕: hides it and tells the App.
  public func close() {
    let turnsOff = [.listening, .paused].contains(presentation.stage)
    hide()
    onClose?(turnsOff)
  }

  /// The user dragged the strip: where it is now is kept.
  public func moved() {
    guard !placing, isShown else { return }
    placement.save(panel.frame.origin)
  }

  private func hide(after seconds: Double) {
    hideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  private func installContent() {
    guard let makeContent else { return }
    let host = FirstMouseHostingView(rootView: makeContent(presentation))
    host.frame = NSRect(origin: .zero, size: Self.panelSize)
    host.autoresizingMask = [.width, .height]
    panel.contentView = host
  }

  private func position() {
    let mouse = NSEvent.mouseLocation
    let screens = NSScreen.screens
    let active =
      screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens.first
    guard let active else { return }
    let frame = Self.frame(
      saved: placement.load(), visibleFrames: screens.map(\.visibleFrame),
      active: active.visibleFrame)
    placing = true
    panel.setFrame(frame, display: true)
    placing = false
  }

  /// The strip's frame: where the user left it when that place is still on
  /// a screen (pulled inside it), else centred at the bottom of the active
  /// screen's visible area.
  public nonisolated static func frame(
    saved: CGPoint?, visibleFrames: [CGRect], active: CGRect
  ) -> CGRect {
    let size = panelSize
    if let saved {
      let centre = CGPoint(x: saved.x + size.width / 2, y: saved.y + size.height / 2)
      if let screen = visibleFrames.first(where: { $0.contains(centre) }) {
        let x = min(max(saved.x, screen.minX), screen.maxX - size.width)
        let y = min(max(saved.y, screen.minY), screen.maxY - size.height)
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
      }
    }
    return CGRect(
      x: (active.midX - size.width / 2).rounded(), y: (active.minY + bottomInset).rounded(),
      width: size.width, height: size.height)
  }
}

/// The strip's host: a click goes to the strip at once (its window never
/// becomes key, so every click is a first one).
final class FirstMouseHostingView: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
