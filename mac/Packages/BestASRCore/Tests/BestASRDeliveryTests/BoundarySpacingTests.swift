import XCTest

@testable import BestASRDelivery

final class BoundarySpacingTests: XCTestCase {
  func testEnglishAfterEnglishGetsOneSpace() {
    XCTAssertEqual(
      BoundarySpacing.apply(
        "Second sentence.",
        before: CaretContext(value: "First sentence.", selectionLocation: 15, selectionLength: 0)),
      " Second sentence.")
    XCTAssertEqual(
      BoundarySpacing.apply(
        "world", before: CaretContext(value: "hello", selectionLocation: 5, selectionLength: 0)),
      " world")
  }

  func testNothingIsAddedAfterASpaceAfterChineseOverASelectionOrBeforePunctuation() {
    XCTAssertEqual(
      BoundarySpacing.apply(
        "world", before: CaretContext(value: "hello ", selectionLocation: 6, selectionLength: 0)),
      "world")
    XCTAssertEqual(
      BoundarySpacing.apply(
        "世界", before: CaretContext(value: "你好", selectionLocation: 2, selectionLength: 0)),
      "世界")
    XCTAssertEqual(
      BoundarySpacing.apply(
        "world", before: CaretContext(value: "hello", selectionLocation: 0, selectionLength: 5)),
      "world")
    XCTAssertEqual(
      BoundarySpacing.apply(
        ", world", before: CaretContext(value: "hello", selectionLocation: 5, selectionLength: 0)),
      ", world")
    XCTAssertEqual(BoundarySpacing.apply("world", before: nil), "world")
  }
}
