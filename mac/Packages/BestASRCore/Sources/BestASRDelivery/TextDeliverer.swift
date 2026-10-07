import AppKit
import Carbon.HIToolbox
import Foundation
import MindloomIdentity
import OSLog

private let deliveryLogger = Logger(subsystem: MindloomIdentity.logSubsystem, category: "delivery")

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
/// application is a miss (System Settings with no field). Second: does the
/// field that had the keyboard before ⌘V now show the words — because
/// Chromium asks for the pasteboard on ⌘V even when the keyboard rests on a
/// button, and only the field can say whether the words arrived. "Its text
/// changed" is not enough: the words themselves must be seen, in the same
/// element (`LandingEvidence`).
///
/// Only the second observation proves the words were typed in. A paste
/// that was taken and not seen to land is `unconfirmed`, whatever the
/// reason: the application names no focused element (WeChat; Claude or a
/// browser with no caret), the field shows no text, its tree had not caught
/// up, or the field was rebuilt. The words stay on the clipboard and the
/// HUD says 已拷贝 with 「无法确认文字是否已输入」 — never 「写进去了」 on
/// the strength of a pasteboard read alone (2026-10-05, ALIGNMENT 收1-12),
/// and never 「没有找到输入位置」 either, because the words may well have
/// landed (review 10-5c S1). Only a paste nothing asked for is `nowhere` —
/// nothing within the paste window, nor within the late-read window after
/// it: an application busy at ⌘V reads the words when it gets to the
/// keystroke, and they land then (review 10-5d R4).
///
/// The user's own clipboard is borrowed only for the paste window (0.4 s)
/// and put back only when the words were seen to land, and only while the
/// offer still owns the clipboard (收1-14, 收1-15). When the words are left
/// on the clipboard, `lastLease` says which clipboard that was, so a later
/// copy of the same words never replaces something the user copied since
/// (review 10-5c S5).
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

  /// The clipboard this deliverer last left the words on: set when a
  /// delivery borrowed the clipboard and the words were not seen to land,
  /// nil after any other delivery.
  public private(set) var lastLease: ClipboardLease?

  /// How long an application gets to take the paste. A landing read arrives
  /// within tens of milliseconds; the window only bounds the miss.
  public static let pasteWindowSeconds: TimeInterval = 0.4
  /// After a paste window with no read, how much longer a read still counts
  /// as this paste's (review 10-5d R4): ⌘V already went to the target, and
  /// an application busy at that moment handles it later and still types
  /// the words in. Only when nothing reads in this window either is the
  /// verdict 「没有找到输入位置」.
  public nonisolated static let lateReadWindowSeconds: TimeInterval = 1.5
  /// How long a field gets to show the pasted text after taking it.
  public static let fieldUpdateWindowSeconds: TimeInterval = 0.3

  /// `before` is what the target's focused element showed before this call,
  /// read by the caller (it is also what boundary spacing needs). Nil means
  /// the application names no focused element.
  public func deliver(
    _ text: String, to target: DeliveryTarget, observing before: FocusedText?
  ) async -> DeliveryOutcome {
    lastLease = nil
    guard !text.isEmpty else { return .kept(.nowhere) }
    guard CGPreflightPostEventAccess() else { return report(.kept(.permissionDenied), target) }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    else { return report(.kept(.applicationChanged), target) }
    guard !IsSecureEventInputEnabled() else { return report(.kept(.secureInput), target) }
    guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(
        keyboardEventSource: source, virtualKey: Self.pasteVirtualKey, keyDown: true),
      let up = CGEvent(
        keyboardEventSource: source, virtualKey: Self.pasteVirtualKey, keyDown: false)
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
    var takenLate = false
    if !taken {
      takenLate = await promise.awaitRequest(
        after: posted, timeout: Self.lateReadWindowSeconds)
    }
    var wordsSeen: Bool?
    if taken || takenLate, let before {
      wordsSeen = await reader.wordsLanded(
        text, since: before, in: target.processIdentifier, within: Self.fieldUpdateWindowSeconds)
    }
    let waited = Int(Date().timeIntervalSince(posted) * 1000)
    let verdict = Self.verdict(taken: taken, takenLate: takenLate, fieldChanged: wordsSeen)
    let focus = Self.focusName(before)
    if verdict.restoresPriorClipboard {
      // Restore the borrowed clipboard only while this offer still owns it.
      // A user copy made during field verification belongs to the user now.
      prior.restore(to: pasteboard, ifOwnedBy: offeredChangeCount)
      return report(
        .delivered(evidence: .field, waitMilliseconds: waited), target, focus: focus)
    }
    // Nothing took it, or nothing showed where it went. Leave the words on
    // the clipboard as plain text: ⌘V is what the HUD now offers.
    // Materialize the existing item without invalidating a pending
    // consumer's reference. A newer clipboard owner is left untouched: stale
    // items reject writes, and the lease then no longer matches.
    let stillOffered = pasteboard.changeCount == offeredChangeCount
    _ = offeredItem.setString(text, forType: .string)
    lastLease = ClipboardLease(
      changeCount: stillOffered ? pasteboard.changeCount : offeredChangeCount)
    return report(
      .kept(verdict.keptReason ?? .nowhere), target, waited: waited, evidence: verdict.logEvidence,
      focus: focus)
  }

  /// What the application showed at its keyboard focus before ⌘V, for the
  /// log: a field with text or a caret, an element with neither, or none.
  nonisolated static func focusName(_ before: FocusedText?) -> String {
    guard let before else { return "none" }
    return before.exposesText ? "text" : "no-text"
  }

  /// What the two observations after ⌘V add up to.
  enum PasteVerdict: Equatable, Sendable {
    /// Taken, and the watched field shows the words: typed in.
    case landed
    /// Nothing asked for the text, in the paste window or the late-read
    /// window after it.
    case notTaken
    /// Taken, and the watched field does not show the words: the keyboard
    /// on a button (Chromium asks for the text anyway), a field whose tree
    /// had not caught up, a field the application rebuilt or rewrote.
    case takenUnseen
    /// Taken, but the application names no focused element to watch.
    case takenUnwatched
    /// Taken only after the paste window, and the words not seen: the
    /// application was busy at ⌘V and may well have typed them in then.
    case takenLate

    /// Only a paste seen to land gives the user's clipboard back; every
    /// other outcome leaves the words there for ⌘V.
    var restoresPriorClipboard: Bool { self == .landed }

    var keptReason: DeliveryKeptReason? {
      switch self {
      case .landed: nil
      case .notTaken: .nowhere
      case .takenUnseen, .takenUnwatched, .takenLate: .unconfirmed
      }
    }

    var logEvidence: String {
      switch self {
      case .landed: "field"
      case .notTaken: "unread"
      case .takenUnseen: "read-not-seen"
      case .takenUnwatched: "read-unwatched"
      case .takenLate: "read-late"
      }
    }
  }

  /// The decision, on its own so it can be read and tested without a
  /// pasteboard: typed in only when the text was taken and a watched field
  /// shows the words (`fieldChanged` is that observation; nil when no field
  /// could be watched). A pasteboard read with no field to watch is not
  /// proof. `takenLate`: nothing read in the paste window, something did in
  /// the late-read window after it.
  nonisolated static func verdict(
    taken: Bool, takenLate: Bool = false, fieldChanged: Bool?
  ) -> PasteVerdict {
    guard taken || takenLate else { return .notTaken }
    if fieldChanged == true { return .landed }
    guard taken else { return .takenLate }
    return fieldChanged == false ? .takenUnseen : .takenUnwatched
  }

  static let pasteVirtualKey: CGKeyCode = 9

  private func report(
    _ outcome: DeliveryOutcome, _ target: DeliveryTarget, waited: Int? = nil,
    evidence: String = "-", focus: String = "-"
  ) -> DeliveryOutcome {
    let bundle = target.bundleIdentifier ?? "-"
    switch outcome {
    case .delivered(let proof, let wait):
      deliveryLogger.notice(
        "delivery app=\(bundle, privacy: .public) outcome=delivered evidence=\(proof.rawValue, privacy: .public) focus=\(focus, privacy: .public) wait_ms=\(wait, privacy: .public)"
      )
    case .kept(let reason):
      deliveryLogger.notice(
        "delivery app=\(bundle, privacy: .public) outcome=kept reason=\(reason.rawValue, privacy: .public) evidence=\(evidence, privacy: .public) focus=\(focus, privacy: .public) wait_ms=\(waited ?? 0, privacy: .public)"
      )
    }
    return outcome
  }
}

/// The clipboard as a delivery left it when the words were not seen to land:
/// its change count. While the clipboard still has that count, the words on
/// it are the delivery's; once it changed, someone copied something else and
/// that copy belongs to the user (review 10-5c S5).
public struct ClipboardLease: Equatable, Sendable {
  public let changeCount: Int

  public init(changeCount: Int) {
    self.changeCount = changeCount
  }

  /// True when the clipboard has changed since the delivery left the words
  /// on it: whatever is there now must not be replaced.
  public func userCopiedSince(currentChangeCount: Int) -> Bool {
    currentChangeCount != changeCount
  }
}
