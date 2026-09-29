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
