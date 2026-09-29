import Foundation

/// The application a dictation is aimed at: whichever one was in front when
/// the dictation key went down.
///
/// Nothing finer is recorded because nothing finer is needed to deliver. ⌘V
/// goes to the process, and the process puts the text where its own keyboard
/// focus is — which is the one thing an outside observer can never know
/// better than the application itself. Thirty days of this user's history
/// showed 603 pastes and 2 accessibility writes; the element-level model that
/// served those 2 cost four decision tables and the bug this module replaces.
public struct DeliveryTarget: Codable, Equatable, Sendable {
  public let processIdentifier: Int32
  public let bundleIdentifier: String?

  public init(processIdentifier: Int32, bundleIdentifier: String?) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
  }
}

/// What became of a delivery. There are two answers, and both are observed
/// rather than inferred: the application asked the pasteboard for the text,
/// or it did not.
public enum DeliveryOutcome: Equatable, Sendable {
  /// The application took the text. `evidence` says what showed it, and the
  /// wait is how long that took.
  case delivered(evidence: DeliveryEvidence, waitMilliseconds: Int)
  /// The text was not taken. It is on the clipboard as plain text, so a
  /// late paste still lands the right words, and the capsule says 已复制.
  case kept(DeliveryKeptReason)
}

/// The text an application shows at its keyboard focus, read before a
/// delivery and compared after it.
///
/// Chromium reads the pasteboard on ⌘V whether or not anything editable has
/// the keyboard — the page's paste event takes the data before anyone
/// decides what to do with it (measured 2026-09-22: a page whose focus was
/// on a button asked for the text in 13 ms and put it nowhere). So where an
/// application names a focused element, the pasteboard request alone is
/// not enough: the text that element shows has to change.
public struct FocusedText: Equatable, Sendable {
  public let value: String?
  public let selectionLocation: Int?
  public let selectionLength: Int?

  public init(value: String?, selectionLocation: Int?, selectionLength: Int?) {
    self.value = value
    self.selectionLocation = selectionLocation
    self.selectionLength = selectionLength
  }

  /// Whether there is anything here that a paste could be seen to change.
  public var exposesText: Bool {
    value != nil || selectionLocation != nil
  }

  public var caret: CaretContext? {
    guard let value, let selectionLocation, let selectionLength else { return nil }
    return CaretContext(
      value: value, selectionLocation: selectionLocation, selectionLength: selectionLength)
  }
}

/// What proved a delivery landed.
public enum DeliveryEvidence: String, Equatable, Sendable {
  /// The application asked the pasteboard for the text, and named no
  /// focused element that could be watched.
  case pasteboard
  /// The application asked for the text and the focused field then showed
  /// different text.
  case field
}

public enum DeliveryKeptReason: String, Equatable, Sendable {
  /// ⌘V was sent and nothing asked for the text: no field had the keyboard.
  case nowhere
  /// A password field has the keyboard. Nothing is sent.
  case secureInput
  /// A different application is in front now. Nothing is sent.
  case applicationChanged
  /// The system does not let this app post keystrokes.
  case permissionDenied
}
