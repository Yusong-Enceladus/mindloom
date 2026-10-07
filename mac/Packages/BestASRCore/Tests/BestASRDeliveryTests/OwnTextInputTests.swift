import AppKit
import XCTest

@testable import BestASRDelivery

/// 收1-11: Mindloom's own focused field takes a dictation directly. Real
/// AppKit views in a window that is never shown.
@MainActor
final class OwnTextInputTests: XCTestCase {
  private var window: NSWindow!

  override func setUp() async throws {
    _ = NSApplication.shared
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 160), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
  }

  override func tearDown() async throws {
    window.close()
    window = nil
  }

  /// A one-line field (the search field): the words go in at the caret as
  /// typing puts them, and the field tells its delegate (what a SwiftUI
  /// binding listens to).
  func testAFocusedTextFieldTakesTheWordsAsTyped() throws {
    let field = NSTextField(string: "周报")
    field.frame = NSRect(x: 10, y: 10, width: 240, height: 24)
    let listener = ChangeListener()
    field.delegate = listener
    window.contentView?.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field))
    (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 0))
    let input = try XCTUnwrap(AppKitOwnTextInput.input(in: window))
    XCTAssertTrue(input.isSingleLine)
    XCTAssertEqual(input.selection, NSRange(location: 2, length: 0))
    let words = try XCTUnwrap(DeliveryInsertionPort.ownFieldText("和高原。", into: input))
    input.insert(words)
    XCTAssertEqual(input.text, "周报和高原")
    XCTAssertEqual(field.stringValue, "周报和高原")
    XCTAssertEqual(listener.changes, 1)
  }

  /// A text view (a paste box) is multi-line: the sentence stays as said.
  func testATextViewKeepsTheSentence() throws {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
    view.string = "hello"
    window.contentView?.addSubview(view)
    XCTAssertTrue(window.makeFirstResponder(view))
    view.setSelectedRange(NSRange(location: 5, length: 0))
    let input = try XCTUnwrap(AppKitOwnTextInput.input(in: window))
    XCTAssertFalse(input.isSingleLine)
    input.insert(try XCTUnwrap(DeliveryInsertionPort.ownFieldText("world.", into: input)))
    XCTAssertEqual(view.string, "hello world.")
  }

  /// A password field, read-only text or nothing focused is never one.
  func testOnlyAnEditableNonSecureFieldIsOne() throws {
    let secure = NSSecureTextField(string: "")
    secure.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
    window.contentView?.addSubview(secure)
    XCTAssertTrue(window.makeFirstResponder(secure))
    XCTAssertNil(AppKitOwnTextInput.input(in: window))

    let readOnly = NSTextView(frame: NSRect(x: 0, y: 40, width: 300, height: 80))
    readOnly.string = "原文"
    readOnly.isEditable = false
    window.contentView?.addSubview(readOnly)
    XCTAssertTrue(window.makeFirstResponder(readOnly))
    XCTAssertNil(AppKitOwnTextInput.input(in: window))

    XCTAssertTrue(window.makeFirstResponder(nil))
    XCTAssertNil(AppKitOwnTextInput.input(in: window))
    XCTAssertNil(AppKitOwnTextInput.input(in: nil))
  }
}

@MainActor
private final class ChangeListener: NSObject, NSTextFieldDelegate {
  var changes = 0
  func controlTextDidChange(_ notification: Notification) { changes += 1 }
}
