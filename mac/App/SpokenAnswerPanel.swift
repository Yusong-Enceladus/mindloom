import AppKit

/// Shows the answer to a spoken instruction that had nowhere to be written.
///
/// A 指令 is delivered into the field the caret is in, exactly like a
/// dictation. Only when that field will not take it — read-only text, a PDF,
/// nothing focused at all — does the answer appear here instead, which is the
/// rule Typeless states: rewrite editable text, answer questions about
/// read-only text.
///
/// The design follows from what the panel is for. It appears over another
/// app's window while the user is still in that app, so it is a floating
/// surface in the system's HUD material, not a window with a title bar. It is
/// something to read, so the answer is the largest thing on it and the
/// instruction that produced it sits above in the quiet size the reader needs
/// only to confirm they asked the right thing. It carries no 复制 button,
/// because the answer is already on the clipboard by the time the panel
/// opens — a button that repeats what has happened is a button that makes the
/// user wonder whether it happened. What is left is one line saying so, and
/// one way out, which Esc also does.
///
/// It never takes key focus: the caret must stay where the user left it.
@MainActor
final class SpokenAnswerPanelController: NSObject {
  private let panel: NSPanel
  private let surface = NSVisualEffectView()
  private let questionLabel = NSTextField(wrappingLabelWithString: "")
  private let answerLabel = NSTextField(wrappingLabelWithString: "")
  private let answerClip = NSScrollView()
  private let footnote = NSTextField(labelWithString: "")
  private let closeButton = NSButton()
  private var escapeMonitor: Any?
  private var outsideClickMonitor: Any?

  private static let width: CGFloat = 460
  private static let padding: CGFloat = 18
  private static let bottomInset: CGFloat = 58
  /// Past this the answer scrolls. Half the shortest common screen is as much
  /// of someone else's window as this is entitled to cover.
  private static let maximumAnswerHeight: CGFloat = 320

  private var contentWidth: CGFloat { Self.width - Self.padding * 2 }

  override init() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 140),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()
    configure()
  }

  private func configure() {
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.setAccessibilityIdentifier("bestASR.answerPanel")

    surface.material = .hudWindow
    surface.blendingMode = .behindWindow
    surface.state = .active
    surface.wantsLayer = true
    surface.layer?.cornerRadius = 14
    surface.layer?.cornerCurve = .continuous
    surface.layer?.borderWidth = 1
    surface.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    surface.maskImage = Self.roundedMask(radius: 14)
    panel.contentView = surface

    questionLabel.font = .systemFont(ofSize: 11, weight: .medium)
    questionLabel.textColor = .secondaryLabelColor
    questionLabel.maximumNumberOfLines = 2
    questionLabel.lineBreakMode = .byTruncatingTail
    questionLabel.setAccessibilityIdentifier("bestASR.answerPanel.question")
    questionLabel.setAccessibilityLabel("你说的话")
    surface.addSubview(questionLabel)

    answerLabel.font = .systemFont(ofSize: 15)
    answerLabel.textColor = .labelColor
    // A paragraph read at a glance over someone else's window needs a little
    // more air between lines than a form field does.
    answerLabel.usesSingleLineMode = false
    answerLabel.cell?.wraps = true
    answerLabel.isSelectable = true
    answerLabel.allowsEditingTextAttributes = false
    answerLabel.setAccessibilityIdentifier("bestASR.answerPanel.answer")
    answerLabel.setAccessibilityLabel("回答")

    answerClip.drawsBackground = false
    answerClip.hasVerticalScroller = true
    answerClip.autohidesScrollers = true
    answerClip.scrollerStyle = .overlay
    answerClip.documentView = answerLabel
    surface.addSubview(answerClip)

    footnote.font = .systemFont(ofSize: 11)
    footnote.textColor = .tertiaryLabelColor
    footnote.stringValue = "已复制 · ⌘V 粘贴"
    footnote.setAccessibilityIdentifier("bestASR.answerPanel.footnote")
    surface.addSubview(footnote)

    closeButton.isBordered = false
    closeButton.bezelStyle = .regularSquare
    closeButton.imagePosition = .imageOnly
    closeButton.image = NSImage(
      systemSymbolName: "xmark", accessibilityDescription: "关闭")
    closeButton.contentTintColor = .tertiaryLabelColor
    closeButton.target = self
    closeButton.action = #selector(closePressed)
    closeButton.setAccessibilityIdentifier("bestASR.answerPanel.close")
    closeButton.setAccessibilityLabel("关闭")
    closeButton.toolTip = "关闭（esc）"
    surface.addSubview(closeButton)
  }

  /// `question` is what the user said; it is shown so an answer arriving a
  /// second later is not mysterious.
  func present(answer: String, question: String) {
    questionLabel.stringValue = question.trimmingCharacters(in: .whitespacesAndNewlines)
    answerLabel.attributedStringValue = Self.answerText(answer)
    layout()
    panel.orderFrontRegardless()
    installMonitors()
  }

  func dismiss() {
    removeMonitors()
    panel.orderOut(nil)
  }

  var isVisible: Bool { panel.isVisible }

  /// Test seam: the laid-out geometry, so the measurement that used to clip
  /// every answer to a line and a half can be asserted rather than looked at.
  var laidOutGeometry: (panelHeight: CGFloat, visibleAnswer: CGFloat, answerContent: CGFloat) {
    (panel.frame.height, answerClip.frame.height, answerLabel.frame.height)
  }

  static var maximumAnswerContentHeight: CGFloat { maximumAnswerHeight }

  /// Test seam for rendering the laid-out panel to an image.
  var snapshotView: NSView? { panel.contentView }

  private func layout() {
    let padding = Self.padding
    let width = contentWidth

    // Measured the only way that is reliable for a wrapping label: fix the
    // width it is allowed, then ask what height it needs. The previous
    // version asked a text view's layout manager after setting
    // `widthTracksTextView`, which silently put the container back to the
    // view's width — zero at that point — and clipped every answer to a line
    // and a half.
    questionLabel.preferredMaxLayoutWidth = width - 22
    answerLabel.preferredMaxLayoutWidth = width
    let questionHeight = questionLabel.fittingSize.height
    let answerContentHeight = answerLabel.fittingSize.height
    let answerHeight = min(Self.maximumAnswerHeight, answerContentHeight)
    let footnoteHeight = footnote.fittingSize.height

    let totalHeight =
      padding + questionHeight + 12 + answerHeight + 12 + footnoteHeight + padding

    // AppKit's origin is bottom-left, so the panel is laid out upwards.
    footnote.frame = NSRect(
      x: padding, y: padding, width: width, height: footnoteHeight)
    answerClip.frame = NSRect(
      x: padding, y: padding + footnoteHeight + 12, width: width, height: answerHeight)
    answerLabel.frame = NSRect(
      x: 0, y: 0, width: width, height: max(answerHeight, answerContentHeight))
    questionLabel.frame = NSRect(
      x: padding, y: totalHeight - padding - questionHeight,
      width: width - 22, height: questionHeight)
    closeButton.frame = NSRect(
      x: Self.width - padding - 16, y: totalHeight - padding - 16, width: 16, height: 16)

    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    panel.setFrame(
      NSRect(
        x: (screen.midX - Self.width / 2).rounded(),
        y: (screen.minY + Self.bottomInset).rounded(),
        width: Self.width,
        height: totalHeight.rounded()
      ),
      display: true
    )
    surface.maskImage = Self.roundedMask(radius: 14)
    answerClip.documentView?.scroll(
      NSPoint(x: 0, y: max(0, answerContentHeight - answerHeight)))
  }

  /// Esc closes it — the same key that discards a dictation — and so does a
  /// click anywhere else, because the panel is over the window the user is
  /// about to go back to working in.
  private func installMonitors() {
    removeMonitors()
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard event.keyCode == 53 else { return event }
      self?.dismiss()
      return nil
    }
    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, self.panel.isVisible else { return }
        // A global monitor sees only clicks outside this process's windows,
        // and the panel belongs to this process, so anything it hears is
        // somewhere else.
        guard !NSMouseInRect(
          NSEvent.mouseLocation, self.panel.frame, false)
        else { return }
        self.dismiss()
      }
    }
  }

  private func removeMonitors() {
    if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    escapeMonitor = nil
    outsideClickMonitor = nil
  }

  @objc private func closePressed() {
    dismiss()
  }

  /// A paragraph read at a glance over someone else's window needs a little
  /// more air between its lines than a form field does.
  private static func answerText(_ answer: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 2.5
    return NSAttributedString(
      string: answer,
      attributes: [
        .font: NSFont.systemFont(ofSize: 15),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph,
      ]
    )
  }

  /// A vibrancy view clips to its mask, not to its layer's corner radius.
  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(
      top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}
