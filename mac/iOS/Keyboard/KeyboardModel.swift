import MindloomDesign
import MindloomPhoneKit
import Observation
import UIKit
import os

let debugLog = Logger(subsystem: PhoneNames.keyboardLog, category: "debug")

/// The keyboard's state for its panel (PHONE-SPEC §5.13, §7.1–7.2): the voice protocol with the
/// app (`KeyboardVoiceController`), the listening animation (`ListenerModel`, driven by the app's
/// microphone level read at 60 Hz), the talk gestures (hold, tap to latch, slide onto ×), the
/// undo window, and the plain keys.
@MainActor
@Observable
final class KeyboardModel {
  /// Times after release (s), as the in-app speak bar: reset after saving, after a cancel; idle.
  static let savedReset = 0.9 + 3.0
  static let cancelledReset = 1.25
  static let idleAfterReset = 0.3
  /// × becomes hot only this long after the press, within its rect padded by 14 pt.
  static let hotDelay = 0.4
  static let hotPadding: CGFloat = 14

  var width: CGFloat = 402 {
    didSet { if width != oldValue { updateLayout() } }
  }
  private(set) var mic: KeyboardVoiceController.Mic
  private(set) var hasFullAccess: Bool
  private(set) var needsGlobe = false
  /// Opening Mindloom from the key did not work: the key shows one line of instruction.
  var openAppFailed = false
  /// Tap mode: still listening after the finger left; ✓ finishes.
  private(set) var latched = false
  private(set) var hot = false
  /// 「已收好」 may show (the final was inserted).
  private(set) var committed = false
  /// When the labels started cross-fading back (reset).
  private(set) var resetAt: TimeInterval?

  let listener: ListenerModel
  @ObservationIgnored private weak var input: UIInputViewController?
  @ObservationIgnored private let channel: VoiceChannel?
  @ObservationIgnored private var controller: KeyboardVoiceController!
  @ObservationIgnored private var ticker: Timer?
  @ObservationIgnored private var levelTimer: Timer?
  @ObservationIgnored private var deleteTimer: Timer?
  @ObservationIgnored private var pressAt: TimeInterval?
  @ObservationIgnored private var holding = false
  /// The finger that ended tap mode is still down: its release belongs to that tap.
  @ObservationIgnored private var swallowNextUp = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .light)
  @ObservationIgnored private let success = UINotificationFeedbackGenerator()

  /// DEBUG: a frozen PHONE-SPEC keyboard state for the screenshot harness.
  private(set) var frozen: FrozenKeyboard?
  @ObservationIgnored private var debugObservation: PhoneSignalObservation?

  init(input: UIInputViewController) {
    self.input = input
    let fullAccess = input.hasFullAccess
    hasFullAccess = fullAccess
    channel = fullAccess ? PhoneLink.voiceChannel() : nil
    mic = channel == nil ? .needsFullAccess : .needsSession
    listener = ListenerModel(layout: Self.layout(width: 402))
    let host = KeyboardTextHost(
      mark: { [weak input] text in
        input?.textDocumentProxy.setMarkedText(
          text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
      },
      insert: { [weak input] text in
        guard let proxy = input?.textDocumentProxy else { return }
        proxy.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        proxy.unmarkText()
      },
      clearMarked: { [weak input] in
        guard let proxy = input?.textDocumentProxy else { return }
        proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        proxy.unmarkText()
      },
      textBeforeCursor: { [weak input] in input?.textDocumentProxy.documentContextBeforeInput },
      deleteBackward: { [weak input] count in
        for _ in 0..<count { input?.textDocumentProxy.deleteBackward() }
      })
    controller = KeyboardVoiceController(
      channel: channel, signaling: DarwinSignaling.shared, host: host,
      haptic: { [weak self] in self?.play($0) })
    controller.onChange = { [weak self] in self?.controllerChanged() }
    controller.onOutcome = { [weak self] in self?.outcome($0) }
  }

  static func layout(width: CGFloat) -> ListenerLayout {
    .phoneKeyboard(
      width: width, height: KeyboardViewController.panelHeight,
      rest: CGPoint(x: width / 2 - 39, y: 102))
  }

  private func updateLayout() {
    let layout = Self.layout(width: width)
    if listener.layout != layout { listener.layout = layout }
  }

  /// The × circle in panel coordinates.
  var cancelRect: CGRect { CGRect(x: 13, y: 87, width: 40, height: 40) }

  // MARK: - Lifecycle

  func appear() {
    guard let input else { return }
    hasFullAccess = input.hasFullAccess
    needsGlobe = input.needsInputModeSwitchKey
    controller.appear()
    controllerChanged()
    try? channel?.writeKeyboardStatus(
      KeyboardStatus(hasFullAccess: true, seenAt: Date().timeIntervalSince1970))
    impact.prepare()
    #if DEBUG
      loadFrozen()
      if debugObservation == nil {
        debugObservation = DarwinSignaling.shared.observe(FrozenKeyboard.signal) { [weak self] in
          self?.loadFrozen()
        }
      }
    #endif
  }

  func disappear() {
    controller.disappear()
    stopTicker()
    stopLevel()
    deleteUp()
    holding = false
    latched = false
    hot = false
    committed = false
    resetAt = nil
    listener.reset()
  }

  func textChanged() {}

  // MARK: - The speak key

  func down(at point: CGPoint) {
    guard frozen == nil else { return }
    let now = ListenerModel.now()
    if latched {
      controller.pressDown()
      latched = false
      swallowNextUp = true
      release(at: now)
      return
    }
    guard !holding else { return }
    if listener.pressedAt != nil { settlePrevious() }
    guard controller.pressDown() else { return }
    generation += 1
    holding = true
    hot = false
    committed = false
    resetAt = nil
    pressAt = now
    listener.press(at: now)
    startLevel()
    impact.impactOccurred()
  }

  func move(to point: CGPoint) {
    guard holding, let pressAt else { return }
    let over = cancelRect.insetBy(dx: -Self.hotPadding, dy: -Self.hotPadding).contains(point)
    let isHot = over && ListenerModel.now() - pressAt > Self.hotDelay
    if isHot != hot {
      hot = isHot
      if isHot { UISelectionFeedbackGenerator().selectionChanged() }
    }
  }

  func up(at point: CGPoint, moved: CGFloat, cancelled: Bool = false) {
    if swallowNextUp {
      swallowNextUp = false
      controller.pressUp()
      return
    }
    guard holding else { return }
    holding = false
    if hot || cancelled {
      cancel()
      return
    }
    if controller.pressUp(moved: Double(moved)) {
      latched = true
    } else {
      release(at: ListenerModel.now())
    }
  }

  /// ✓ (tap mode).
  func done() {
    guard latched else { return }
    latched = false
    controller.done()
    release(at: ListenerModel.now())
  }

  /// × : nothing goes into the field.
  func cancel() {
    guard listener.pressedAt != nil, !listener.isCancelled else { return }
    holding = false
    latched = false
    hot = false
    controller.cancel()
    let now = ListenerModel.now()
    listener.cancel(at: now)
    stopLevel()
    schedule(after: Self.cancelledReset) { $0.beginReset() }
  }

  /// 「撤销」.
  func undo() {
    guard committed, resetAt == nil else { return }
    controller.undo()
    committed = false
    beginReset()
  }

  private func release(at now: TimeInterval) {
    listener.release(at: now)
    stopLevel()
  }

  private func outcome(_ outcome: KeyboardVoiceController.Outcome) {
    switch outcome {
    case .inserted:
      committed = true
      success.notificationOccurred(.success)
      let releasedAt = listener.releasedAt ?? ListenerModel.now()
      let wait = max(0.5, releasedAt + Self.savedReset - ListenerModel.now())
      schedule(after: wait) { $0.beginReset() }
    case .nothing:
      // Never for a press still under the finger (or latched): that belongs to an older utterance.
      guard !holding, !latched, listener.pressedAt != nil, !listener.isCancelled else { return }
      holding = false
      latched = false
      hot = false
      listener.cancel(at: ListenerModel.now())
      stopLevel()
      schedule(after: Self.cancelledReset) { $0.beginReset() }
    case .cancelled:
      break
    }
  }

  private func beginReset() {
    guard resetAt == nil, listener.pressedAt != nil else { return }
    resetAt = ListenerModel.now()
    controller.settle()
    let token = generation
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.idleAfterReset))
      guard let self, self.generation == token else { return }
      self.listener.reset()
      self.resetAt = nil
      self.committed = false
    }
  }

  /// A new press while the last result shows: start over (the last item leaves when its window
  /// ends in the app).
  private func settlePrevious() {
    controller.settle()
    resetAt = nil
    committed = false
    listener.reset()
  }

  private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor (KeyboardModel) -> Void)
  {
    let token = generation
    Task { [weak self] in
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      guard let self, self.generation == token else { return }
      body(self)
    }
  }

  // MARK: - Plain keys

  func insert(_ text: String) {
    input?.textDocumentProxy.insertText(text)
    UIDevice.current.playInputClick()
  }

  /// Delete: once on touch, then repeating while held (after 0.48 s, every 0.09 s).
  func deleteDown() {
    deleteOnce()
    deleteTimer?.invalidate()
    deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.48, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.deleteOnce() }
        }
      }
    }
  }

  func deleteUp() {
    deleteTimer?.invalidate()
    deleteTimer = nil
  }

  private func deleteOnce() {
    input?.textDocumentProxy.deleteBackward()
    UIDevice.current.playInputClick()
  }

  func advanceToNextInputMode() {
    input?.advanceToNextInputMode()
  }

  // MARK: - Updates

  private func controllerChanged() {
    mic = controller.display.mic
    if controller.needsTicks { startTicker() } else { stopTicker() }
    // The session ended under the finger: back to rest.
    if !(mic.isListening || mic == .finishing), holding {
      holding = false
      latched = false
    }
  }

  private func startTicker() {
    guard ticker == nil else { return }
    ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.controller.tick() }
    }
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
  }

  /// The app's raw level ℓ at 60 Hz; the listener runs the envelope and the spring itself.
  private func startLevel() {
    guard levelTimer == nil, let channel else { return }
    levelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.listener.submitLevel(normalized: Double(channel.readLevel()))
      }
    }
  }

  private func stopLevel() {
    levelTimer?.invalidate()
    levelTimer = nil
    listener.submitLevel(normalized: 0)
  }

  private func play(_ haptic: KeyboardVoiceController.Haptic) {
    switch haptic {
    case .problem: success.notificationOccurred(.warning)
    default: break
    }
  }

  // MARK: - DEBUG frozen states

  #if DEBUG
    private func loadFrozen() {
      let raw = channel?.readDebugKeyboardScreen()
      debugLog.notice(
        "frozen: \(raw ?? "nil", privacy: .public) channel: \(self.channel != nil, privacy: .public)")
      let next = raw.flatMap(FrozenKeyboard.init(state:))
      guard next != frozen else { return }
      frozen = next
      listener.reset()
      listener.levelTrack = nil
      guard let next else { return }
      next.prepare(listener)
      // The host's text context arrives a moment after the keyboard appears.
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(0.4))
        guard let self, self.frozen == next else { return }
        next.writeHostText(self.input?.textDocumentProxy)
      }
    }
  #endif
}

extension KeyboardVoiceController.Mic {
  var isListening: Bool {
    if case .listening = self { return true }
    return false
  }
}
