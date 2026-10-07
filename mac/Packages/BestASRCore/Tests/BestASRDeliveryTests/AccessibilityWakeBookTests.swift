import XCTest

@testable import BestASRDelivery

/// How long a read waits for an application to name its focused element
/// (DELIVERY.md 原因 2).
final class AccessibilityWakeBookTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testAnApplicationNeverSeenGetsAFullWait() {
    let book = AccessibilityWakeBook()
    XCTAssertEqual(book.waitSeconds(for: 42, now: now), AccessibilityWakeBook.wakeWindowSeconds)
    XCTAssertGreaterThanOrEqual(AccessibilityWakeBook.wakeWindowSeconds, 0.5)
  }

  /// Regression (2026-10-05): the daily build woke each process once and
  /// never again. In its delivery records an Electron application that
  /// named its focused element on one day named none for every later
  /// dictation, so each paste into it was judged on the pasteboard read
  /// alone: a Chromium tree dropped after input with no assistive use stayed
  /// dropped. A process that named its element before and is found without
  /// one now is asked and waited for again.
  func testAnApplicationThatDroppedItsTreeIsWaitedForAgain() {
    var book = AccessibilityWakeBook()
    book.noteExposed(42)
    XCTAssertEqual(book.waitSeconds(for: 42, now: now), AccessibilityWakeBook.wakeWindowSeconds)
  }

  /// An application that showed nothing after a full wait (WeChat) is not
  /// made to cost that wait on every dictation; after ten minutes it gets
  /// a full wait again (it may build its tree later; the process number may
  /// be reused).
  func testAnApplicationThatShowsNothingIsNotWaitedForEveryTime() {
    var book = AccessibilityWakeBook()
    book.noteMissingAfterWait(7, now: now)
    XCTAssertEqual(book.waitSeconds(for: 7, now: now.addingTimeInterval(5)), 0)
    XCTAssertEqual(
      book.waitSeconds(
        for: 7, now: now.addingTimeInterval(AccessibilityWakeBook.missingMemorySeconds)),
      AccessibilityWakeBook.wakeWindowSeconds)
    book.noteExposed(7)
    XCTAssertEqual(
      book.waitSeconds(for: 7, now: now.addingTimeInterval(6)),
      AccessibilityWakeBook.wakeWindowSeconds)
    XCTAssertEqual(book.waitSeconds(for: 8, now: now), AccessibilityWakeBook.wakeWindowSeconds)
  }

  /// The tree is requested when the dictation key goes down (off the main
  /// thread). By the time the words are ready the application has had its
  /// chance, so the read then waits only for what is left of the window: a
  /// WeChat dictation costs no wait, an application switched to while
  /// talking (not asked at key-down) still gets the whole window.
  func testARequestAtKeyDownIsNotWaitedForTwice() {
    var book = AccessibilityWakeBook()
    book.noteRequested(42, now: now)
    XCTAssertEqual(book.waitSeconds(for: 42, now: now.addingTimeInterval(0.2)), 0.3, accuracy: 1e-3)
    XCTAssertEqual(book.waitSeconds(for: 42, now: now.addingTimeInterval(3)), 0)
    XCTAssertEqual(
      book.waitSeconds(for: 43, now: now.addingTimeInterval(3)),
      AccessibilityWakeBook.wakeWindowSeconds)
    // A request older than any dictation no longer counts.
    XCTAssertEqual(
      book.waitSeconds(
        for: 42, now: now.addingTimeInterval(AccessibilityWakeBook.requestMemorySeconds)),
      AccessibilityWakeBook.wakeWindowSeconds)
  }

  func testTheLogNamesWhatTheFocusShowed() {
    XCTAssertEqual(TextDeliverer.focusName(nil), "none")
    XCTAssertEqual(
      TextDeliverer.focusName(
        FocusedText(value: nil, selectionLocation: nil, selectionLength: nil)),
      "no-text")
    XCTAssertEqual(
      TextDeliverer.focusName(FocusedText(value: "", selectionLocation: 0, selectionLength: 0)),
      "text")
  }
}
