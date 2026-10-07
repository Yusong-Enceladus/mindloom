import Foundation
import MindloomDesign
import MindloomLink
import MindloomPhoneKit
import Observation
import UIKit

/// The speak bar's talk controller (PHONE-SPEC §7.1): hold to talk, a short tap latches (✓ to
/// finish), sliding onto × cancels; the listening animation (`ListenerModel`) follows the real
/// microphone level; on release the recognised text is committed at +0.35 s as an item held for the
/// undo window (「已收好 · 撤销」), and sent when the window closes at release + 3.9 s.
@MainActor
@Observable
final class TalkController {
  /// Times after release (s): commit, reset after saving, reset after a cancel, idle after reset.
  static let commitDelay = 0.35
  static let savedReset = 0.9 + 3.0
  static let cancelledReset = 1.25
  static let idleAfterReset = 0.3
  /// A press shorter than this, that moved less than `tapSlop`, latches (tap mode).
  static let tapDuration = 0.30
  static let tapSlop: CGFloat = 12
  /// The × becomes hot only this long after the press, within its rect padded by 14 pt.
  static let hotDelay = 0.4
  static let hotPadding: CGFloat = 14

  let listener: ListenerModel
  private let voice: VoiceSessionModel
  private let delivery: DeliveryService

  /// Tap mode: still listening after the finger left; ✓ finishes.
  private(set) var latched = false
  /// The finger is over ×.
  private(set) var hot = false
  /// What has been heard so far (live words above the line).
  private(set) var partial = ""
  /// The committed text (after release).
  private(set) var committed: String?
  /// The item saved by this press (撤销 withdraws it).
  private(set) var savedItemID: String?
  /// When the labels started cross-fading back (reset).
  private(set) var resetAt: TimeInterval?
  /// The id of the item that just appeared (for the list's entrance and scroll to top).
  private(set) var lastSavedID: String?
  /// In screen coordinates, set by the view: the × circle.
  var cancelRect: CGRect = .zero

  private var pressAt: TimeInterval?
  private var startPoint: CGPoint?
  private var moved: CGFloat = 0
  private var holding = false
  private var utterance: LocalUtterance?
  private var generation = 0

  init(listener: ListenerModel, voice: VoiceSessionModel, delivery: DeliveryService) {
    self.listener = listener
    self.voice = voice
    self.delivery = delivery
    voice.setLevelHandler { [listener] db in listener.submitLevel(dBFS: db) }
  }

  /// A press is in progress or its result is still showing.
  var isActive: Bool { listener.pressedAt != nil }
  var isReleased: Bool { listener.releasedAt != nil }
  var isCancelled: Bool { listener.isCancelled }

  // MARK: - Touches

  func down(at point: CGPoint, now: TimeInterval = ListenerModel.now()) {
    if latched {
      finish(now: now)
      return
    }
    if holding { return }
    // A new press during 「已收好」 closes the previous undo window: that item leaves now.
    if isActive { settlePrevious() }
    generation += 1
    holding = true
    latched = false
    hot = false
    moved = 0
    startPoint = point
    partial = ""
    committed = nil
    savedItemID = nil
    resetAt = nil
    pressAt = now
    listener.press(at: now)
    utterance = voice.beginLocalUtterance { [weak self] text in
      guard let self, self.listener.releasedAt == nil || self.committed == nil else { return }
      self.partial = text
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    // A latched (or stuck) press finishes by itself after the same maximum as the keyboard's.
    schedule(after: VoiceSessionCore.defaultMaximumUtterance) { talk in
      guard talk.isActive, !talk.isReleased else { return }
      talk.finish(now: ListenerModel.now())
    }
  }

  /// The app left the foreground: nothing keeps listening behind the user's back. A latched press
  /// finishes (what was said so far is kept, as with ✓); a press whose touch the system took is
  /// cancelled.
  func leaveApp() {
    if latched {
      finish(now: ListenerModel.now())
    } else if holding {
      cancel()
    }
  }

  func move(to point: CGPoint, now: TimeInterval = ListenerModel.now()) {
    guard holding, let startPoint, let pressAt else { return }
    moved = max(moved, hypot(point.x - startPoint.x, point.y - startPoint.y))
    let over = cancelRect.insetBy(dx: -Self.hotPadding, dy: -Self.hotPadding).contains(point)
    let isHot = over && now - pressAt > Self.hotDelay
    if isHot != hot {
      hot = isHot
      if isHot { UISelectionFeedbackGenerator().selectionChanged() }
    }
  }

  func up(at point: CGPoint, cancelled: Bool = false, now: TimeInterval = ListenerModel.now()) {
    guard holding, let pressAt else { return }
    holding = false
    if hot || cancelled {
      cancel(now: now)
    } else if now - pressAt < Self.tapDuration && moved < Self.tapSlop {
      latched = true
    } else {
      finish(now: now)
    }
  }

  /// ✓ (tap mode).
  func done(now: TimeInterval = ListenerModel.now()) {
    guard isActive, !isReleased else { return }
    finish(now: now)
  }

  /// ×.
  func cancel(now: TimeInterval = ListenerModel.now()) {
    guard isActive, !isReleased || !isCancelled else { return }
    holding = false
    latched = false
    hot = false
    listener.cancel(at: now)
    utterance?.cancel()
    utterance = nil
    schedule(after: (listener.releasedAt ?? now) + Self.cancelledReset - now) { $0.beginReset() }
  }

  /// 「撤销」: the item is taken back and the bar resets now.
  func undo() {
    guard let id = savedItemID else { return }
    delivery.withdraw(itemID: id)
    savedItemID = nil
    lastSavedID = nil
    beginReset()
  }

  // MARK: - Release and commit

  private func finish(now: TimeInterval) {
    guard isActive, !isReleased else { return }
    holding = false
    latched = false
    hot = false
    listener.release(at: now)
    let releasedAt = listener.releasedAt ?? now
    let current = utterance
    utterance = nil
    let token = generation
    Task { [weak self] in
      let heard = await current?.finish()
      guard let self else { return }
      let text = PhoneText.finalized(heard ?? "")
      // A new press started while this text was still coming: keep it anyway (no UI of its own).
      guard self.generation == token else {
        if !text.isEmpty { self.keepQuietly(text) }
        return
      }
      if text.isEmpty {
        // Nothing recognised: no 「已收好」, the mark goes back to rest.
        self.listener.cancel(at: ListenerModel.now())
        self.schedule(after: releasedAt + Self.cancelledReset - ListenerModel.now()) {
          $0.beginReset()
        }
        return
      }
      let wait = releasedAt + Self.commitDelay - ListenerModel.now()
      if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
      guard self.generation == token else {
        self.keepQuietly(text)
        return
      }
      self.commit(text, releasedAt: releasedAt)
    }
  }

  /// Keeps an utterance whose moment has passed (a quick next press took the bar): saved and sent
  /// like any other, without the 「已收好」 moment.
  private func keepQuietly(_ text: String) {
    let now = Date()
    let item = PhoneItem(createdAt: now, kind: .text, source: .voice, text: text)
    guard let payload = try? InboxItemPayload.text(text, source: .voice, createdAt: now),
      (try? delivery.collector.collect(item, payloads: [payload])) != nil
    else { return }
    delivery.refresh()
    Task { await delivery.deliver() }
  }

  private func commit(_ text: String, releasedAt: TimeInterval) {
    committed = text
    partial = text
    let resetIn = max(0.5, releasedAt + Self.savedReset - ListenerModel.now())
    let now = Date()
    let item = PhoneItem(createdAt: now, kind: .text, source: .voice, text: text)
    do {
      let payload = try InboxItemPayload.text(text, source: .voice, createdAt: now)
      let saved = try delivery.collector.collect(
        item, payloads: [payload], heldUntil: now.addingTimeInterval(resetIn))
      savedItemID = saved.id
      lastSavedID = saved.id
      delivery.refresh()
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      listener.cancel(at: ListenerModel.now())
    }
    schedule(after: resetIn) { $0.beginReset() }
  }

  // MARK: - Reset

  private func beginReset() {
    guard resetAt == nil, isActive else { return }
    resetAt = ListenerModel.now()
    if let id = savedItemID { delivery.release(itemID: id) }
    savedItemID = nil
    schedule(after: Self.idleAfterReset) { $0.finishReset() }
  }

  private func finishReset() {
    listener.reset()
    resetAt = nil
    partial = ""
    committed = nil
  }

  /// A new press while the last result shows: send the last item now and start over.
  private func settlePrevious() {
    if let id = savedItemID { delivery.release(itemID: id) }
    savedItemID = nil
    resetAt = nil
    utterance?.cancel()
    utterance = nil
    listener.reset()
  }

  private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor (TalkController) -> Void)
  {
    let token = generation
    Task { [weak self] in
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      guard let self, self.generation == token else { return }
      body(self)
    }
  }

  #if DEBUG
    /// DEBUG: sets the state a frozen screenshot shows.
    func debugSet(latched: Bool, partial: String, committed: String?, savedItemID: String?) {
      self.latched = latched
      self.partial = partial
      self.committed = committed
      self.savedItemID = savedItemID
      self.lastSavedID = savedItemID
    }
  #endif
}
