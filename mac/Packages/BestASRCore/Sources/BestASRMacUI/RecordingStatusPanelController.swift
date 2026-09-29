import AppKit
import BestASRDictation
import Foundation

public final class NonActivatingRecordingPanel: NSPanel {
  public override var canBecomeKey: Bool { false }
  public override var canBecomeMain: Bool { false }
}

/// What the dictation capsule shows for one rendered snapshot.
public enum RecordingCapsuleMode: Equatable, Sendable {
  case hidden
  case listening
  case paused
  case processing
  case inserted
  case message(symbol: String, text: String, opensRecord: Bool)

  public static func resolve(
    _ snapshot: DictationSessionSnapshot,
    compactStatus: String
  ) -> RecordingCapsuleMode {
    switch snapshot.phase {
    case .preparing, .recording: .listening
    case .paused: .paused
    case .finalizing, .recognizing, .polishing, .inserting: .processing
    case .completed where snapshot.insertion?.inserted == true: .inserted
    case .completed:
      .message(
        symbol: "doc.on.clipboard",
        text: compactStatus.isEmpty ? "已保存到资料库" : compactStatus,
        opensRecord: true
      )
    case .failedRecoverable where snapshot.failure?.isSilentTake == true:
      .message(
        symbol: "mic.slash",
        text: compactStatus.isEmpty ? "没有听到说话" : compactStatus,
        opensRecord: false
      )
    case .failedRecoverable:
      .message(
        symbol: "exclamationmark.circle",
        text: compactStatus.isEmpty ? "处理失败，原音已保存" : compactStatus,
        opensRecord: true
      )
    case .cancelling: .message(symbol: "xmark", text: "已取消", opensRecord: false)
    case .idle, .cancelled: .hidden
    }
  }

  var isActiveCapture: Bool { self == .listening || self == .paused }

  var showsResultText: Bool {
    switch self {
    case .inserted: true
    case .message(_, _, let opensRecord): opensRecord
    default: false
    }
  }

  /// How long a finished state stays on screen before the capsule fades.
  var dismissDelay: Duration? {
    switch self {
    case .inserted: .milliseconds(1_800)
    case .message(_, _, let opensRecord): opensRecord ? .seconds(6) : .milliseconds(900)
    default: nil
    }
  }
}

/// Lightweight dictation indicator: a small dark capsule at the bottom centre
/// of the active screen. It never becomes key or main, shows a live input
/// level while listening, and carries no controls at all: everything it could
/// offer is already on the keyboard — the dictation key finishes, Esc cancels,
/// and a result that did not reach its field is already on the clipboard for
/// ⌘V. A button here would ask the user to aim a pointer at a 22-point target
/// at the bottom of the screen while they are speaking.
@MainActor
public final class RecordingStatusPanelController: NSObject {
  public let panel: NonActivatingRecordingPanel
  public private(set) var renderedSnapshot = DictationSessionSnapshot()
  public private(set) var renderedLiveText = ""
  public private(set) var renderedMode = RecordingCapsuleMode.hidden
  /// Off by default: the live subtitle line shows whenever there is draft
  /// text. When on, it appears only while the pointer hovers the capsule.
  public var subtitlesRequireHover = false {
    didSet { if renderedMode != .hidden { layoutCapsule() } }
  }

  private let root = CapsuleRootView()
  private let capsule = CapsuleSurfaceView()
  private let draftBubble = CapsuleSurfaceView()
  private let draftLabel = NSTextField(labelWithString: "")
  private let waveform = CapsuleWaveformView()
  private let processing = CapsuleProcessingView()
  private let iconView = NSImageView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let onOpenRecord: @MainActor () -> Void
  private var hovering = false
  private var hoverExitTask: Task<Void, Never>?
  private var terminalDismissTask: Task<Void, Never>?

  private static let capsuleHeight: CGFloat = 30
  private static let bottomInset: CGFloat = 18
  private static let bubbleGap: CGFloat = 6
  private static let maximumDraftWidth: CGFloat = 420

  public init(
    onOpenRecord: @escaping @MainActor () -> Void = {}
  ) {
    self.onOpenRecord = onOpenRecord
    panel = NonActivatingRecordingPanel(
      contentRect: NSRect(x: 0, y: 0, width: 72, height: Self.capsuleHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    configurePanel()
  }

  /// What the capsule says while it listens. Empty means an ordinary
  /// dictation, which says "正在聆听"; a mode dictation names itself, because
  /// nothing else on screen distinguishes 翻译 or 指令 from writing down what
  /// you said, and the difference only becomes visible once it is too late.
  public var listeningCaption = "" {
    didSet { if renderedMode == .listening { layoutCapsule() } }
  }

  public func render(
    _ snapshot: DictationSessionSnapshot,
    liveText: String = "",
    compactStatus: String = ""
  ) {
    let previousMode = renderedMode
    renderedSnapshot = snapshot
    renderedLiveText = liveText
    renderedMode = RecordingCapsuleMode.resolve(snapshot, compactStatus: compactStatus)
    if renderedMode != previousMode {
      waveform.reset()
      announce(renderedMode)
    }
    updateTerminalDismissal()
    guard renderedMode != .hidden else {
      panel.orderOut(nil)
      return
    }
    layoutCapsule()
    panel.orderFrontRegardless()
  }

  /// Feeds the live microphone level (0...1). Ignored unless listening.
  public func updateInputLevel(_ level: Float) {
    guard renderedMode == .listening else { return }
    waveform.push(level: level)
  }

  public func dismiss() {
    terminalDismissTask?.cancel()
    terminalDismissTask = nil
    processing.stop()
    panel.orderOut(nil)
  }

  /// Test and accessibility hook: behaves as if the pointer entered or left.
  public func setHovering(_ hovering: Bool) {
    hoverExitTask?.cancel()
    hoverExitTask = nil
    guard self.hovering != hovering else { return }
    self.hovering = hovering
    guard renderedMode != .hidden else { return }
    layoutCapsule()
  }

  // MARK: - Layout

  private func configurePanel() {
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isMovableByWindowBackground = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.setAccessibilityIdentifier("bestASR.recordingPanel")

    root.wantsLayer = true
    root.onHoverChange = { [weak self] inside in self?.pointerHoverChanged(inside) }
    root.onClick = { [weak self] in self?.capsuleClicked() }
    panel.contentView = root

    draftLabel.font = .systemFont(ofSize: 12)
    draftLabel.textColor = CapsuleSurfaceView.foreground
    draftLabel.lineBreakMode = .byTruncatingHead
    draftLabel.maximumNumberOfLines = 1
    draftLabel.setAccessibilityIdentifier("bestASR.liveTranscript")
    draftLabel.setAccessibilityLabel("本机实时草稿")
    draftBubble.addSubview(draftLabel)
    root.addSubview(draftBubble)

    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.textColor = CapsuleSurfaceView.foreground
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setAccessibilityIdentifier("bestASR.recordingState")
    statusLabel.setAccessibilityLabel("口述状态")
    iconView.contentTintColor = CapsuleSurfaceView.foreground
    iconView.imageScaling = .scaleProportionallyDown

    for view in [waveform, processing, iconView, statusLabel] {
      capsule.addSubview(view)
    }
    capsule.setAccessibilityElement(true)
    capsule.setAccessibilityRole(.group)
    capsule.setAccessibilityLabel("织机口述")
    root.addSubview(capsule)
  }

  private func layoutCapsule() {
    let height = Self.capsuleHeight
    let padding: CGFloat = 8
    let spacing: CGFloat = 6
    var items: [(NSView, CGFloat)] = []

    switch renderedMode {
    case .listening:
      items.append((waveform, 40))
      statusLabel.stringValue = listeningCaption.isEmpty ? "正在聆听" : listeningCaption
      if !listeningCaption.isEmpty {
        items.append((statusLabel, min(240, textWidth(statusLabel))))
      }
    case .paused:
      statusLabel.stringValue = "已暂停"
      iconView.image = Self.symbol("pause.fill")
      items += [(iconView, 12), (statusLabel, textWidth(statusLabel))]
    case .processing:
      statusLabel.stringValue = "正在整理"
      items.append((processing, 28))
    case .inserted:
      statusLabel.stringValue = "已输入"
      iconView.image = Self.symbol("checkmark")
      items.append((iconView, 14))
    case .message(let symbol, let text, _):
      statusLabel.stringValue = text
      iconView.image = Self.symbol(symbol)
      items += [(iconView, 14), (statusLabel, min(300, textWidth(statusLabel)))]
    case .hidden:
      break
    }
    if renderedMode == .processing { processing.start() } else { processing.stop() }

    let visible = Set(items.map { ObjectIdentifier($0.0) })
    for view in capsule.subviews { view.isHidden = !visible.contains(ObjectIdentifier(view)) }
    let contentWidth =
      items.map(\.1).reduce(0, +) + spacing * CGFloat(max(0, items.count - 1))
    let capsuleWidth = max(height, contentWidth + padding * 2)
    var x = padding
    for (view, width) in items {
      let itemHeight = view is NSTextField ? 16 : min(height - 8, max(14, width))
      view.frame = NSRect(
        x: x, y: (height - itemHeight) / 2, width: width, height: itemHeight)
      x += width + spacing
    }
    capsule.setAccessibilityValue(statusLabel.stringValue)

    let draft = renderedLiveText.trimmingCharacters(in: .whitespacesAndNewlines)
    // While listening this is the live draft; once finished it is the text
    // that was actually inserted or kept, so the user sees the final wording.
    let showsDraft =
      (renderedMode.isActiveCapture || renderedMode.showsResultText)
      && (hovering || !subtitlesRequireHover) && !draft.isEmpty
    draftLabel.stringValue = Self.latestSentence(draft)
    let draftWidth = showsDraft ? min(Self.maximumDraftWidth, textWidth(draftLabel) + 20) : 0
    let bubbleHeight: CGFloat = showsDraft ? 26 : 0

    let panelWidth = max(capsuleWidth, draftWidth)
    let panelHeight = height + (showsDraft ? Self.bubbleGap + bubbleHeight : 0)
    capsule.frame = NSRect(x: (panelWidth - capsuleWidth) / 2, y: 0, width: capsuleWidth, height: height)
    draftBubble.isHidden = !showsDraft
    draftBubble.frame = NSRect(
      x: (panelWidth - draftWidth) / 2, y: height + Self.bubbleGap,
      width: draftWidth, height: bubbleHeight)
    draftLabel.frame = NSRect(x: 10, y: 5, width: max(0, draftWidth - 20), height: 16)

    let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
    panel.setFrame(
      NSRect(
        x: (screenFrame.midX - panelWidth / 2).rounded(),
        y: screenFrame.minY + Self.bottomInset,
        width: panelWidth,
        height: panelHeight
      ),
      display: true
    )
  }

  /// Width the label needs for its current string, including cell insets.
  private func textWidth(_ field: NSTextField) -> CGFloat {
    ceil(field.cell?.cellSize.width ?? field.intrinsicContentSize.width) + 1
  }

  /// The tail of the live draft: its last sentence, or its last 40 characters.
  public nonisolated static func latestSentence(_ text: String) -> String {
    let separators = CharacterSet(charactersIn: "。！？!?.\n")
    let pieces = text.components(separatedBy: separators)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let last = pieces.last ?? text
    return last.count > 40 ? String(last.suffix(40)) : last
  }

  private static func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
  }

  // MARK: - Behaviour

  private func pointerHoverChanged(_ inside: Bool) {
    if inside {
      setHovering(true)
      return
    }
    // Resizing under the pointer can emit a transient exit; debounce it.
    hoverExitTask?.cancel()
    hoverExitTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      self?.setHovering(false)
    }
  }

  private func capsuleClicked() {
    if case .message(_, _, true) = renderedMode {
      onOpenRecord()
    }
  }

  private func announce(_ mode: RecordingCapsuleMode) {
    let text: String
    switch mode {
    case .listening: text = "正在聆听"
    case .paused: text = "已暂停"
    case .processing: text = "正在整理"
    case .inserted: text = "已输入"
    case .message(_, let message, _): text = message
    case .hidden: return
    }
    NSAccessibility.post(
      element: capsule,
      notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
    )
  }

  private func updateTerminalDismissal() {
    terminalDismissTask?.cancel()
    terminalDismissTask = nil
    guard let delay = renderedMode.dismissDelay else { return }
    terminalDismissTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      // Keep a finished result on screen while the pointer is on it, so the
      // final wording can be read before it fades.
      while !Task.isCancelled, self?.hovering == true {
        try? await Task.sleep(for: .milliseconds(400))
      }
      guard !Task.isCancelled else { return }
      self?.processing.stop()
      self?.panel.orderOut(nil)
      self?.terminalDismissTask = nil
    }
  }
}

// MARK: - Views

/// Dark rounded surface shared by the capsule and the draft bubble.
final class CapsuleSurfaceView: NSView {
  static let foreground = NSColor(white: 0.95, alpha: 1)
  private static let fill = NSColor(white: 0.08, alpha: 0.92)
  private static let stroke = NSColor(white: 1, alpha: 0.16)

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    let path = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
    Self.fill.setFill()
    path.fill()
    Self.stroke.setStroke()
    path.lineWidth = 0.5
    path.stroke()
  }
}

/// Tracks the pointer across the whole panel and forwards plain clicks.
final class CapsuleRootView: NSView {
  var onHoverChange: ((Bool) -> Void)?
  var onClick: (() -> Void)?
  private var trackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
  override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
  override func mouseUp(with event: NSEvent) { onClick?() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless symbol button that responds to the first click without
/// activating bestASR.
final class CapsuleIconButton: NSButton {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    imagePosition = .imageOnly
    title = ""
    contentTintColor = CapsuleSurfaceView.foreground
    focusRingType = .none
  }

  required init?(coder: NSCoder) { nil }

  func setSymbol(_ name: String, label: String) {
    image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
    setAccessibilityLabel(label)
    toolTip = label
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Five rounded bars driven by the smoothed microphone level.
final class CapsuleWaveformView: NSView {
  private static let weights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
  private var level: CGFloat = 0
  private var phase: CGFloat = 0

  func reset() {
    level = 0
    phase = 0
    needsDisplay = true
  }

  func push(level newLevel: Float) {
    let target = CGFloat(max(0, min(1, newLevel)))
    // Fast attack, slower release keeps the bars readable.
    level = target > level ? level + (target - level) * 0.6 : level + (target - level) * 0.2
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { phase += 0.9 }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let barWidth: CGFloat = 3
    let count = Self.weights.count
    let gap = (bounds.width - barWidth * CGFloat(count)) / CGFloat(count - 1)
    let minimum: CGFloat = 3
    CapsuleSurfaceView.foreground.setFill()
    for (index, weight) in Self.weights.enumerated() {
      let wobble = 0.8 + 0.2 * sin(phase + CGFloat(index) * 1.3)
      let height = minimum + (bounds.height - minimum) * level * weight * wobble
      let rect = NSRect(
        x: CGFloat(index) * (barWidth + gap),
        y: (bounds.height - height) / 2,
        width: barWidth,
        height: height
      )
      NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
  }
}

/// Three dots that pulse while the dictation is being recognized and inserted.
final class CapsuleProcessingView: NSView {
  private var step = 0
  private var timer: Timer?

  func start() {
    guard timer == nil else { return }
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.step = (self.step + 1) % 3
        self.needsDisplay = true
      }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  override func draw(_ dirtyRect: NSRect) {
    let diameter: CGFloat = 5
    let gap = (bounds.width - diameter * 3) / 2
    for index in 0..<3 {
      let alpha: CGFloat = index == step ? 1 : 0.4
      CapsuleSurfaceView.foreground.withAlphaComponent(alpha).setFill()
      NSBezierPath(
        ovalIn: NSRect(
          x: CGFloat(index) * (diameter + gap),
          y: (bounds.height - diameter) / 2,
          width: diameter,
          height: diameter
        )
      ).fill()
    }
  }
}
