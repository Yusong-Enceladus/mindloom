import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog

private let deliveryLogger = Logger(subsystem: "com.bestasr.app", category: "delivery")

/// Puts text where the keyboard is, by the one route every application
/// accepts — ⌘V — and reports what the application did with it.
///
/// There is no other route. An accessibility write was the primary route
/// for a year; the applications this user dictates into either do not
/// expose a writable field (WeChat) or accept the write and ignore it
/// (Electron editors), so it delivered 2 dictations in 30 days while the
/// machinery around it decided the fate of the other 650. One route means
/// one truth signal and no decision about which route to take.
///
/// Before ⌘V there are three instantaneous observations: may this app post
/// keystrokes, is the target still in front, is a password field listening.
/// After ⌘V there are two, in order. First: did the application ask the
/// pasteboard for the text — nothing lands without that, so a silent
/// application is a miss (System Settings with no field). Second, only where
/// the application names a focused element that shows text: did that text
/// change — because Chromium asks for the pasteboard on ⌘V even when the
/// keyboard rests on a button, and only the field can say whether the words
/// arrived. An application that names no focused element at all (WeChat) is
/// judged by the first observation alone.
///
/// Between ⌘V and the pasteboard request this app does nothing to the
/// target: see `PromisedPasteboardText` for the mutual wait that rule
/// prevents. The second observation is made only after the first resolves.
@MainActor
public final class TextDeliverer {
  private let reader: TargetReader

  public init(reader: TargetReader = TargetReader()) {
    self.reader = reader
  }

  /// How long an application gets to take the paste. A landing read arrives
  /// within tens of milliseconds; the window only bounds the miss.
  public static let pasteWindowSeconds: TimeInterval = 0.4
  /// How long a field gets to show the pasted text after taking it.
  public static let fieldUpdateWindowSeconds: TimeInterval = 0.3

  /// `before` is what the target's focused element showed before this call,
  /// read by the caller (it is also what boundary spacing needs). Nil means
  /// the application names no focused element.
  public func deliver(
    _ text: String, to target: DeliveryTarget, observing before: FocusedText?
  ) async -> DeliveryOutcome {
    guard !text.isEmpty else { return .kept(.nowhere) }
    guard CGPreflightPostEventAccess() else { return report(.kept(.permissionDenied), target) }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    else { return report(.kept(.applicationChanged), target) }
    guard !IsSecureEventInputEnabled() else { return report(.kept(.secureInput), target) }
    guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: Self.pasteVirtualKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: Self.pasteVirtualKey, keyDown: false)
    else { return report(.kept(.permissionDenied), target) }
    down.flags = .maskCommand
    up.flags = .maskCommand

    let pasteboard = NSPasteboard.general
    let prior = PasteboardSnapshot(pasteboard: pasteboard)
    let promise = PromisedPasteboardText(text)
    guard let offeredItem = promise.offer(to: pasteboard) else {
      prior.restore(to: pasteboard)
      return report(.kept(.permissionDenied), target)
    }
    let offeredChangeCount = pasteboard.changeCount
    let posted = Date()
    down.postToPid(target.processIdentifier)
    up.postToPid(target.processIdentifier)

    let taken = await promise.awaitRequest(after: posted, timeout: Self.pasteWindowSeconds)
    var fieldChanged: Bool?
    if taken, let before {
      fieldChanged = await reader.textChanged(
        since: before, in: target.processIdentifier, within: Self.fieldUpdateWindowSeconds)
    }
    let waited = Int(Date().timeIntervalSince(posted) * 1000)
    let landed = Self.verdict(taken: taken, fieldChanged: fieldChanged)
    if landed {
      // Restore the borrowed clipboard only while this offer still owns it.
      // A user copy made during field verification belongs to the user now.
      prior.restore(to: pasteboard, ifOwnedBy: offeredChangeCount)
      return report(
        .delivered(evidence: fieldChanged == nil ? .pasteboard : .field, waitMilliseconds: waited),
        target)
    }
    // Nothing took it, or something took it and put it nowhere. Leave the
    // words on the clipboard as plain text: ⌘V is what the capsule now offers.
    // Materialize the existing item without invalidating a pending consumer's
    // reference. A newer clipboard owner is left untouched: stale items reject writes.
    _ = offeredItem.setString(text, forType: .string)
    return report(
      .kept(.nowhere), target, waited: waited, evidence: taken ? "read-unchanged" : "unread")
  }

  /// The decision, on its own so it can be read and tested without a
  /// pasteboard: a paste landed if the text was taken and, where a field
  /// could be watched, the field changed.
  nonisolated static func verdict(taken: Bool, fieldChanged: Bool?) -> Bool {
    guard taken else { return false }
    return fieldChanged ?? true
  }

  static let pasteVirtualKey: CGKeyCode = 9

  private func report(
    _ outcome: DeliveryOutcome, _ target: DeliveryTarget, waited: Int? = nil,
    evidence: String = "-"
  ) -> DeliveryOutcome {
    let bundle = target.bundleIdentifier ?? "-"
    switch outcome {
    case .delivered(let proof, let wait):
      deliveryLogger.notice(
        "delivery app=\(bundle, privacy: .public) outcome=delivered evidence=\(proof.rawValue, privacy: .public) wait_ms=\(wait, privacy: .public)"
      )
    case .kept(let reason):
      deliveryLogger.notice(
        "delivery app=\(bundle, privacy: .public) outcome=kept reason=\(reason.rawValue, privacy: .public) evidence=\(evidence, privacy: .public) wait_ms=\(waited ?? 0, privacy: .public)"
      )
    }
    return outcome
  }
}
