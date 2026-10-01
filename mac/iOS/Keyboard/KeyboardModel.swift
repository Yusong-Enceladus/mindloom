import Combine
import MindloomPhoneKit
import UIKit

/// The keyboard's state for its SwiftUI view: the voice controller (the
/// protocol with the app), the input level for the waveform, and the plain
/// keys (space, delete, return).
@MainActor
final class KeyboardModel: ObservableObject {
  @Published private(set) var display: KeyboardVoiceController.Display
  @Published private(set) var level: Double = 0
  @Published private(set) var returnLabel = "换行"
  @Published private(set) var needsGlobe = true
  @Published private(set) var hasFullAccess: Bool
  /// Set when opening the app from the keyboard did not work: the key then
  /// shows the one-line instruction instead.
  @Published var openAppFailed = false

  private weak var input: UIInputViewController?
  private let channel: VoiceChannel?
  private let container: URL?
  private var controller: KeyboardVoiceController!
  private var ticker: Timer?
  private var levelTimer: Timer?
  private var deleteTimer: Timer?
  private let impact = UIImpactFeedbackGenerator(style: .medium)
  private let soft = UIImpactFeedbackGenerator(style: .soft)
  private let notification = UINotificationFeedbackGenerator()

  init(input: UIInputViewController) {
    self.input = input
    let fullAccess = input.hasFullAccess
    self.hasFullAccess = fullAccess
    let container = fullAccess ? PhoneAppGroup.containerURL() : nil
    self.container = container
    let channel = container.flatMap {
      try? VoiceChannel(directory: PhoneAppGroup.voiceDirectory(in: $0))
    }
    self.channel = channel
    let collector = fullAccess ? try? InboxCollector.appGroup() : nil
    self.display = KeyboardVoiceController.Display(
      mic: channel == nil ? .needsFullAccess : .needsSession, transcript: "",
      transcriptIsLive: false, notice: nil, collected: nil)
    controller = KeyboardVoiceController(
      channel: channel,
      signaling: DarwinSignaling.shared,
      insert: { [weak self] text in self?.input?.textDocumentProxy.insertText(text) },
      collect: { text in collector?.collectKeyboardText(text) ?? .failed },
      collectedCount: { collector?.collectedCount() },
      haptic: { [weak self] in self?.play($0) })
    controller.onChange = { [weak self] in self?.controllerChanged() }
  }

  // MARK: - Lifecycle

  func appear() {
    guard let input else { return }
    hasFullAccess = input.hasFullAccess
    needsGlobe = input.needsInputModeSwitchKey
    updateReturnKey()
    controller.appear()
    controllerChanged()
    if let container {
      try? KeyboardStatus(hasFullAccess: true, seenAt: Date().timeIntervalSince1970)
        .write(to: container)
    }
    impact.prepare()
  }

  func disappear() {
    controller.disappear()
    stopTimers()
  }

  func textChanged() {
    updateReturnKey()
  }

  // MARK: - Mic key

  func pressDown() { controller.pressDown() }
  func pressUp() { controller.pressUp() }
  func pressCancelled() { controller.pressCancelled() }

  // MARK: - Plain keys

  func insertSpace() {
    input?.textDocumentProxy.insertText(" ")
    UIDevice.current.playInputClick()
  }

  func insertReturn() {
    input?.textDocumentProxy.insertText("\n")
    UIDevice.current.playInputClick()
  }

  /// Delete: once on touch, then repeating while held.
  func deleteDown() {
    deleteOnce()
    deleteTimer?.invalidate()
    deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) {
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

  // MARK: - Updates

  private func controllerChanged() {
    display = controller.display
    if controller.needsTicks { startTicker() } else { stopTicker() }
    if case .listening = display.mic { startLevel() } else { stopLevel() }
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

  private func startLevel() {
    guard levelTimer == nil else { return }
    levelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let channel = self.channel else { return }
        let target = Double(channel.readLevel())
        self.level = self.level * 0.55 + target * 0.45
      }
    }
  }

  private func stopLevel() {
    levelTimer?.invalidate()
    levelTimer = nil
    level = 0
  }

  private func stopTimers() {
    stopTicker()
    stopLevel()
    deleteUp()
  }

  private func updateReturnKey() {
    switch input?.textDocumentProxy.returnKeyType ?? .default {
    case .send: returnLabel = "发送"
    case .search, .google, .yahoo: returnLabel = "搜索"
    case .go, .route: returnLabel = "前往"
    case .done: returnLabel = "完成"
    case .next: returnLabel = "下一项"
    case .join: returnLabel = "加入"
    case .continue: returnLabel = "继续"
    default: returnLabel = "换行"
    }
  }

  private func play(_ haptic: KeyboardVoiceController.Haptic) {
    switch haptic {
    case .start: impact.impactOccurred(intensity: 0.9)
    case .stop: soft.impactOccurred()
    case .inserted: notification.notificationOccurred(.success)
    case .problem: notification.notificationOccurred(.warning)
    }
  }
}
