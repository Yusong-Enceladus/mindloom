import ApplicationServices
import XCTest

@testable import BestASRDelivery

/// The reader against a stand-in application (review 10-5c S2, S3): when
/// the tree is asked for, and which element a landing is judged on.
@MainActor
final class TargetReaderTests: XCTestCase {
  /// Elements are opaque tokens here; each fake process number makes a
  /// distinct one, and nothing is ever sent to a real process.
  private func token(_ number: Int32) -> AXUIElement {
    AXUIElementCreateApplication(900_000 + number)
  }

  /// Regression (review 10-5c S3): the fix "the tree is requested on every
  /// miss" was pinned by no test; going back to "wake each process once"
  /// failed nothing. An application that named its field, dropped its tree
  /// (Chromium after input with no assistive use) and is read again is
  /// asked again, each time.
  func testATreeDroppedAfterUseIsRequestedAgainOnEveryRead() async {
    let field = token(1)
    let app = FakeApplication(processID: 42)
    app.buildsTreeOnRequest = field
    app.reads = [
      (field, AccessibilityRead(value: "", selection: .init(location: 0, length: 0), gone: false))
    ]
    let reader = TargetReader(accessibility: app)

    let first = await reader.focusedTextWaitingForTree(in: 42)
    XCTAssertNotNil(first)
    XCTAssertEqual(app.requests, [42])

    app.dropTree()
    let second = await reader.focusedTextWaitingForTree(in: 42)
    XCTAssertNotNil(second, "the dropped tree was asked for again")
    XCTAssertEqual(app.requests, [42, 42])

    app.dropTree()
    XCTAssertNotNil(reader.focusedText(in: 42))
    XCTAssertEqual(app.requests, [42, 42, 42], "the read without a wait asks too")
  }

  /// Two reads in a row of an application that names no element at all:
  /// both ask for the tree (the 2026-09-22 reader asked once per process).
  func testTwoMissesInARowBothRequestTheTree() {
    let app = FakeApplication(processID: 7)
    let reader = TargetReader(accessibility: app)
    XCTAssertNil(reader.focusedText(in: 7))
    XCTAssertNil(reader.focusedText(in: 7))
    XCTAssertEqual(app.requests, [7, 7])
  }

  /// Regression (review 10-5c S2): when the field read before ⌘V is gone,
  /// the reader used to judge the words on whichever element had the
  /// keyboard by then. Words seen in another element are not words seen in
  /// the field they were aimed at: not a landing.
  func testWordsInAnotherElementAfterTheFieldIsGoneAreNotALanding() async {
    let field = token(1)
    let other = token(2)
    let app = FakeApplication(processID: 5)
    app.focused = other
    app.reads = [
      (field, .missing),
      (other, AccessibilityRead(value: "早上好 mlprobe", selection: nil, gone: false)),
    ]
    let reader = TargetReader(accessibility: app)
    let before = FocusedText(
      value: "", selectionLocation: 0, selectionLength: 0,
      element: FocusedElementHandle(element: field))
    let landed = await reader.wordsLanded("早上好 mlprobe", since: before, in: 5, within: 0.05)
    XCTAssertFalse(landed)
  }

  /// The same field showing the words is a landing; a field the reader
  /// never named (no element) cannot show anything.
  func testTheSameFieldShowingTheWordsIsALanding() async {
    let field = token(1)
    let app = FakeApplication(processID: 5)
    app.reads = [(field, AccessibilityRead(value: "早上好 mlprobe", selection: nil, gone: false))]
    let reader = TargetReader(accessibility: app)
    let before = FocusedText(
      value: "", selectionLocation: 0, selectionLength: 0,
      element: FocusedElementHandle(element: field))
    let landed = await reader.wordsLanded("早上好 mlprobe", since: before, in: 5, within: 0.05)
    XCTAssertTrue(landed)
    let unnamed = FocusedText(value: "", selectionLocation: 0, selectionLength: 0)
    let unseen = await reader.wordsLanded("早上好 mlprobe", since: unnamed, in: 5, within: 0.05)
    XCTAssertFalse(unseen)
  }
}

/// A stand-in application: the element it names as focused, what each
/// element reads as, and the tree requests it received.
final class FakeApplication: TargetAccessibility, @unchecked Sendable {
  let processID: Int32
  private let lock = NSLock()
  private var _focused: AXUIElement?
  private var _requests: [Int32] = []
  /// When set, a tree request makes the application name this element.
  var buildsTreeOnRequest: AXUIElement?
  var reads: [(AXUIElement, AccessibilityRead)] = []

  init(processID: Int32) {
    self.processID = processID
  }

  var focused: AXUIElement? {
    get { lock.withLock { _focused } }
    set { lock.withLock { _focused = newValue } }
  }

  var requests: [Int32] { lock.withLock { _requests } }

  func dropTree() { focused = nil }

  func focusedElement(ofProcess processID: Int32) -> AXUIElement? {
    processID == self.processID ? focused : nil
  }

  func requestTree(ofProcess processID: Int32) {
    lock.withLock {
      _requests.append(processID)
      if processID == self.processID, let built = buildsTreeOnRequest { _focused = built }
    }
  }

  func read(_ element: AXUIElement) -> AccessibilityRead {
    reads.first { CFEqual($0.0, element) }?.1 ?? .missing
  }
}
