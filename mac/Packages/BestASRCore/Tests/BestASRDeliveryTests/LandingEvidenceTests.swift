import XCTest

@testable import BestASRDelivery

/// What proves pasted words arrived: the words seen in the same field, not
/// merely a change (DELIVERY.md 原因 3).
final class LandingEvidenceTests: XCTestCase {
  private func field(_ value: String?, _ location: Int? = nil, _ length: Int? = 0) -> FocusedText {
    FocusedText(
      value: value, selectionLocation: location, selectionLength: location == nil ? nil : length)
  }

  func testTheWordsSeenInTheFieldAreALanding() {
    XCTAssertTrue(
      LandingEvidence.landed(
        "明天下午三点开会", before: field("会议记录："), after: field("会议记录：明天下午三点开会")))
  }

  /// Regression (2026-10-05): a field whose text changed without the words
  /// in it — focus moved to another element, or the application changed
  /// the field for its own reasons — used to count as the words landing,
  /// and the HUD said 写进去了 while nothing had arrived.
  func testAChangeWithoutTheWordsIsNotALanding() {
    XCTAssertFalse(
      LandingEvidence.landed("明天下午三点开会", before: field(""), after: field("Search chats")))
    XCTAssertFalse(
      LandingEvidence.landed("hello world", before: field("draft"), after: field("draft ")))
    XCTAssertFalse(
      LandingEvidence.landed("hello world", before: field("a", 1), after: field("ab", 2)))
  }

  /// Dictating the same sentence twice: the second time it must appear one
  /// more time than it did, not merely be there.
  func testWordsAlreadyThereMustAppearOnceMore() {
    let once = "好的，收到。"
    XCTAssertFalse(LandingEvidence.landed("好的，收到。", before: field(once), after: field(once)))
    XCTAssertTrue(
      LandingEvidence.landed("好的，收到。", before: field(once), after: field(once + "好的，收到。")))
  }

  /// A field may re-space, wrap or join what was pasted: a rich editor
  /// turns line breaks into paragraphs, a single-line field drops them,
  /// an editor puts a no-break or zero-width space where a space was, and
  /// full-width letters and digits are the same words.
  func testFieldsThatReshapeTheWordsStillShowThem() {
    XCTAssertTrue(
      LandingEvidence.landed(
        " first line\nsecond line", before: field(""), after: field("first line\n\nsecond line")))
    XCTAssertTrue(
      LandingEvidence.landed("one\ntwo", before: field(""), after: field("onetwo")))
    XCTAssertTrue(
      LandingEvidence.landed(
        "Twin 7 数据", before: field(""), after: field("Twin\u{00A0}7\u{200B} 数据")))
    XCTAssertTrue(LandingEvidence.landed("ＡＢＣ１２３", before: field(""), after: field("ABC123")))
  }

  /// Where a field shows no text but reports its caret, the caret moving on
  /// by exactly the words' length (UTF-16) is a landing; any other move is
  /// not.
  func testACaretThatMovesByTheWordsIsALandingOnlyWithoutText() {
    let words = "送达 ok"
    let length = (words as NSString).length
    XCTAssertTrue(
      LandingEvidence.landed(words, before: field(nil, 10), after: field(nil, 10 + length)))
    XCTAssertFalse(
      LandingEvidence.landed(words, before: field(nil, 10), after: field(nil, 11 + length)))
    XCTAssertFalse(LandingEvidence.landed(words, before: field(nil, 10), after: field(nil, 10)))
    // Replacing a selection: the words start where the selection did.
    XCTAssertTrue(
      LandingEvidence.landed(words, before: field(nil, 4, 6), after: field(nil, 4 + length)))
    // A field that shows text is judged by its text, never by its caret.
    XCTAssertFalse(
      LandingEvidence.landed(words, before: field("x", 1), after: field("y", 1 + length)))
  }

  func testNothingToSeeIsNeverALanding() {
    XCTAssertFalse(LandingEvidence.landed("  \n", before: field(""), after: field("  \n")))
    XCTAssertFalse(LandingEvidence.landed("words", before: field(nil), after: field(nil)))
  }

  func testOccurrencesDoNotOverlap() {
    XCTAssertEqual(LandingEvidence.occurrences(of: "aa", in: "aaaa"), 2)
    XCTAssertEqual(LandingEvidence.occurrences(of: "aa", in: "aaa"), 1)
    XCTAssertEqual(LandingEvidence.occurrences(of: "", in: "aaa"), 0)
  }

  /// The reader's element is carried for the read after ⌘V but never
  /// compared: two reads of the same text are equal.
  func testTheElementIsNotPartOfEquality() {
    XCTAssertEqual(field("a", 1), field("a", 1))
    XCTAssertNotEqual(field("a", 1), field("a", 0))
  }
}
