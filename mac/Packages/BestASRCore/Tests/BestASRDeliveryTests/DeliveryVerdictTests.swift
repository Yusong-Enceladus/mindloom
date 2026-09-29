import XCTest

@testable import BestASRDelivery

/// The whole decision, in one function with no pasteboard behind it.
final class DeliveryVerdictTests: XCTestCase {
  /// Nothing asked for the text: a miss, whatever the field did.
  func testAnUnreadPasteIsAMiss() {
    XCTAssertFalse(TextDeliverer.verdict(taken: false, fieldChanged: nil))
    XCTAssertFalse(TextDeliverer.verdict(taken: false, fieldChanged: true))
  }

  /// The text was taken and no element could be watched (WeChat): landed.
  func testATakenPasteWithNoFieldToWatchLanded() {
    XCTAssertTrue(TextDeliverer.verdict(taken: true, fieldChanged: nil))
  }

  /// The text was taken and the watched field changed (Claude with a
  /// caret): landed. Taken and unchanged (Chromium with the keyboard on a
  /// button): a miss, however fast the pasteboard was read.
  func testAWatchedFieldDecidesATakenPaste() {
    XCTAssertTrue(TextDeliverer.verdict(taken: true, fieldChanged: true))
    XCTAssertFalse(TextDeliverer.verdict(taken: true, fieldChanged: false))
  }

  func testTextThatWasNeverExposedCannotBeSeenToChange() {
    let body = FocusedText(value: nil, selectionLocation: nil, selectionLength: nil)
    XCTAssertFalse(body.exposesText)
    XCTAssertNil(body.caret)
    let field = FocusedText(value: "hello", selectionLocation: 5, selectionLength: 0)
    XCTAssertTrue(field.exposesText)
    XCTAssertEqual(field.caret?.selectionLocation, 5)
  }
}
