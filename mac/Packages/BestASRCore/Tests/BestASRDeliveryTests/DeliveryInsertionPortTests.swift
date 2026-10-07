import AppKit
import BestASRDictation
import BestASRDomain
import XCTest

@testable import BestASRDelivery

/// The state machine sees exactly what the deliverer observed, in its own
/// vocabulary, with nothing added.
final class DeliveryInsertionPortTests: XCTestCase {
  func testEveryKeptReasonHasOneName() {
    XCTAssertEqual(DeliveryInsertionPort.failureReason(for: .nowhere), .nowhere)
    XCTAssertEqual(DeliveryInsertionPort.failureReason(for: .secureInput), .secureInput)
    XCTAssertEqual(DeliveryInsertionPort.failureReason(for: .applicationChanged), .applicationChanged)
    XCTAssertEqual(DeliveryInsertionPort.failureReason(for: .permissionDenied), .permissionDenied)
    XCTAssertEqual(DeliveryInsertionPort.failureReason(for: .unconfirmed), .unconfirmed)
  }

  /// 收1-12: a paste nobody could see land is kept for copying, not
  /// reported as inserted.
  func testAnUnconfirmedPasteIsKeptForCopy() throws {
    let result = DeliveryInsertionPort.result(
      try DictationIdempotencyKey("delivery-unconfirmed"), kept: .unconfirmed)
    XCTAssertEqual(result.method, .retainedForCopy)
    XCTAssertFalse(result.inserted)
    XCTAssertEqual(result.failureReason, .unconfirmed)
    XCTAssertTrue(DictationInsertionFailureReason.unconfirmed.declinedByDesign)
  }

  /// 收1-11: a dictation that ends in Mindloom's own search field is written
  /// into it directly (no clipboard, no ⌘V), without its final 「。」, so the
  /// search runs on the words. It used to be kept as aimed at nowhere.
  @MainActor
  func testOwnSearchFieldIsWrittenDirectly() async throws {
    try XCTSkipIf(TargetReader().secureInputActive(), "a password field has the keyboard")
    let search = FakeOwnField(text: "", singleLine: true)
    let port = DeliveryInsertionPort(
      reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
      targetProvider: { nil }, ownTextInput: { search })
    let clipboard = NSPasteboard.general.changeCount
    let result = try await port.insert(
      DictationInsertionRequest(
        sessionID: SessionID(), target: nil, text: "上周和高原的周报。",
        idempotencyKey: try DictationIdempotencyKey("delivery-own-search")))
    XCTAssertEqual(search.text, "上周和高原的周报")
    XCTAssertTrue(result.inserted)
    XCTAssertEqual(result.method, .directWrite)
    XCTAssertEqual(result.evidence, "own-field")
    XCTAssertNil(result.failureReason)
    XCTAssertEqual(NSPasteboard.general.changeCount, clipboard, "the clipboard is not touched")
  }

  /// A multi-line field keeps the sentence as said, at the caret, with the
  /// space English after English needs.
  @MainActor
  func testOwnTextBoxTakesTheWordsAtTheCaret() throws {
    let box = FakeOwnField(text: "hello", singleLine: false)
    XCTAssertEqual(DeliveryInsertionPort.ownFieldText("world.", into: box), " world.")
    let search = FakeOwnField(text: "", singleLine: true)
    XCTAssertNil(DeliveryInsertionPort.ownFieldText("。", into: search))
    XCTAssertEqual(DeliveryInsertionPort.ownFieldText(" Twin-7 数据. ", into: search), "Twin-7 数据")
  }

  /// No field of this App has the keyboard: the usual delivery decides.
  @MainActor
  func testWithoutAnOwnFieldTheFrontApplicationDecides() async throws {
    let port = DeliveryInsertionPort(
      reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
      targetProvider: { nil }, ownTextInput: { nil })
    let kept = try await port.insert(
      DictationInsertionRequest(
        sessionID: SessionID(), target: nil, text: "x",
        idempotencyKey: try DictationIdempotencyKey("delivery-no-own-field")))
    XCTAssertFalse(kept.inserted)
    XCTAssertEqual(kept.failureReason, .nowhere)
  }

  func testKeptTextIsRetainedForCopyWithItsReason() throws {
    let key = try DictationIdempotencyKey("delivery-kept")
    let result = DeliveryInsertionPort.result(key, kept: .nowhere)
    XCTAssertEqual(result.idempotencyKey, key)
    XCTAssertEqual(result.method, .retainedForCopy)
    XCTAssertFalse(result.inserted)
    XCTAssertEqual(result.failureReason, .nowhere)
  }

  /// Where the words go is where the keyboard is when they are ready. The
  /// request's target is the hint recorded when the key went down; a
  /// dictation begun with nothing in front and finished in a field goes to
  /// that field, and one begun in a field and finished on nothing is kept.
  func testTheApplicationInFrontAtTheEndDecidesNotTheStart() async throws {
    let key = try DictationIdempotencyKey("delivery-end-decides")
    let startedInAField = DictationTargetSnapshot(
      processIdentifier: 7, bundleIdentifier: "com.example.editor", isSecure: false)
    let nothingInFrontNow = await DeliveryInsertionPort(
      reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
      targetProvider: { nil })
    let kept = try await nothingInFrontNow.insert(
      DictationInsertionRequest(
        sessionID: SessionID(), target: startedInAField, text: "x", idempotencyKey: key))
    XCTAssertEqual(kept.failureReason, .nowhere)
    XCTAssertFalse(kept.inserted)
  }

  /// A password field in front when the words are ready is never sent
  /// anything, whatever was in front at the start.
  func testASecureFieldAtTheEndIsKeptWithoutADelivery() async throws {
    let key = try DictationIdempotencyKey("delivery-secure")
    let port = await DeliveryInsertionPort(
      reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
      targetProvider: {
        DictationTargetSnapshot(processIdentifier: 1, bundleIdentifier: "a", isSecure: true)
      })
    let secure = try await port.insert(
      DictationInsertionRequest(sessionID: SessionID(), target: nil, text: "x", idempotencyKey: key))
    XCTAssertEqual(secure.failureReason, .secureInput)
    XCTAssertFalse(secure.inserted)
  }

  /// Regression (review 10-5c S5): after a delivery left its words on the
  /// clipboard, the App copied the dictation again with `clearContents`, so
  /// whatever the user copied in the meantime was lost. The port remembers
  /// the clipboard each delivery left; a newer one belongs to the user.
  @MainActor
  func testACopyMadeAfterTheDeliveryBelongsToTheUser() throws {
    let port = DeliveryInsertionPort(
      reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
      targetProvider: { nil })
    let key = try DictationIdempotencyKey("delivery-lease")
    XCTAssertFalse(
      port.clipboardTakenSinceDelivery(key, currentChangeCount: 10),
      "no clipboard was borrowed: the App copies the words as before")
    port.record(ClipboardLease(changeCount: 10), for: key)
    XCTAssertFalse(port.clipboardTakenSinceDelivery(key, currentChangeCount: 10))
    XCTAssertTrue(port.clipboardTakenSinceDelivery(key, currentChangeCount: 11))
    port.record(nil, for: key)
    XCTAssertFalse(port.clipboardTakenSinceDelivery(key, currentChangeCount: 11))
    XCTAssertTrue(ClipboardLease(changeCount: 3).userCopiedSince(currentChangeCount: 4))
    XCTAssertFalse(ClipboardLease(changeCount: 3).userCopiedSince(currentChangeCount: 3))
  }

  /// The probe pins the application under test: capturing the target names
  /// it, whatever is in front (review 10-5c P1).
  @MainActor
  func testAProvidedTargetIsWhatTheKeyDownCaptures() throws {
    let pinned = DictationTargetSnapshot(
      processIdentifier: 0x7FFF_FF00, bundleIdentifier: "com.example.pinned", isSecure: false)
    let port = DeliveryInsertionPort(
      reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
      targetProvider: { pinned })
    XCTAssertEqual(try port.captureTargetNow(), pinned)
    let none = DeliveryInsertionPort(
      reader: TargetReader(), deliverer: TextDeliverer(), ownApplicationAllowed: { false },
      targetProvider: { nil })
    XCTAssertThrowsError(try none.captureTargetNow())
  }

  /// A result written by an earlier build, with a reason this vocabulary
  /// no longer has, still decodes: the reason is simply absent.
  func testResultsWithHistoricalReasonsStillDecode() throws {
    let json = """
      {"idempotencyKey":"insert:legacy","method":"clipboardPaste","inserted":true,
       "failureReason":"targetApplicationChanged","verified":false}
      """
    let decoded = try JSONDecoder().decode(DictationInsertionResult.self, from: Data(json.utf8))
    XCTAssertTrue(decoded.inserted)
    XCTAssertNil(decoded.failureReason)
    let target = """
      {"processIdentifier":7,"bundleIdentifier":"com.example","isSecure":false,
       "elementFingerprint":"aa","role":"AXTextArea","isEditable":true,
       "selectionLocation":0,"selectionLength":0,"selectionFingerprint":"bb"}
      """
    let snapshot = try JSONDecoder().decode(DictationTargetSnapshot.self, from: Data(target.utf8))
    XCTAssertEqual(snapshot.processIdentifier, 7)
    XCTAssertFalse(snapshot.isSecure)
  }
}

/// One of this App's own text fields, without a window.
@MainActor
private final class FakeOwnField: OwnTextInput {
  var text: String
  var selection: NSRange
  let isSingleLine: Bool

  init(text: String, singleLine: Bool) {
    self.text = text
    selection = NSRange(location: (text as NSString).length, length: 0)
    isSingleLine = singleLine
  }

  func insert(_ words: String) {
    text = (text as NSString).replacingCharacters(in: selection, with: words)
    selection = NSRange(location: selection.location + (words as NSString).length, length: 0)
  }
}
