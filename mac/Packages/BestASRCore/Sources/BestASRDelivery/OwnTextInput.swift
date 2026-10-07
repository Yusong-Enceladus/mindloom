import AppKit
import Foundation

/// A text field of this App that has the keyboard (Mindloom's own search,
/// rename or paste box). A dictation that ends there is written straight
/// into it — no clipboard, no keystrokes (MAC-SPEC §8, ALIGNMENT 收1-11).
@MainActor
public protocol OwnTextInput: AnyObject {
  /// The field's whole text.
  var text: String { get }
  /// The selection in UTF-16 units (a caret is a zero-length selection).
  var selection: NSRange { get }
  /// A one-line field (search, a name): a final 「。」 is not kept.
  var isSingleLine: Bool { get }
  /// Replaces the selection with `text`, as typing would.
  func insert(_ text: String)
}

/// This App's focused text field (ALIGNMENT 收1-11; MAC-SPEC §8 「Mindloom's
/// own search field focused: the words become the query」): the key window's
/// field editor or text view, while this App is the active one. The words
/// are inserted as typing inserts them, so the field's own binding (the
/// search query) follows and ⌘Z undoes them. A password field is never one.
@MainActor
public final class AppKitOwnTextInput: OwnTextInput {
  private let view: NSTextView

  private init(_ view: NSTextView) { self.view = view }

  /// The focused field of this App's key window, while this App is active.
  public static func focused() -> AppKitOwnTextInput? {
    guard NSApp.isActive else { return nil }
    return input(in: NSApp.keyWindow)
  }

  /// The editable text view that is `window`'s first responder (a text
  /// field's field editor, or a text view), if any.
  public static func input(in window: NSWindow?) -> AppKitOwnTextInput? {
    guard let view = window?.firstResponder as? NSTextView, view.isEditable,
      !(view.delegate is NSSecureTextField)
    else { return nil }
    return AppKitOwnTextInput(view)
  }

  public var text: String { view.string }
  public var selection: NSRange { view.selectedRange() }
  public var isSingleLine: Bool { view.isFieldEditor }

  public func insert(_ text: String) {
    view.insertText(text, replacementRange: view.selectedRange())
  }
}
