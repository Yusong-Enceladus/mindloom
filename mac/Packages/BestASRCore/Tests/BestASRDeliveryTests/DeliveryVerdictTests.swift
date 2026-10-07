import AppKit
import XCTest

@testable import BestASRDelivery

/// The whole decision, in one function with no pasteboard behind it.
final class DeliveryVerdictTests: XCTestCase {
  /// Nothing asked for the text: a miss, whatever the field did.
  func testAnUnreadPasteIsAMiss() {
    XCTAssertEqual(TextDeliverer.verdict(taken: false, fieldChanged: nil), .notTaken)
    XCTAssertEqual(TextDeliverer.verdict(taken: false, fieldChanged: true), .notTaken)
    XCTAssertEqual(TextDeliverer.verdict(taken: false, fieldChanged: nil).keptReason, .nowhere)
  }

  /// 收1-12 (regression, 2026-10-05): the application read the pasteboard
  /// and named no focused element (WeChat; Claude with no caret). That read
  /// alone is not proof the words were typed in: the paste is unconfirmed,
  /// the words stay on the clipboard and the HUD says 「已复制」. It used to
  /// count as delivered with evidence `pasteboard`.
  func testAPasteboardReadAloneIsNotProof() {
    let verdict = TextDeliverer.verdict(taken: true, fieldChanged: nil)
    XCTAssertEqual(verdict, .takenUnwatched)
    XCTAssertEqual(verdict.keptReason, .unconfirmed)
    XCTAssertFalse(verdict.restoresPriorClipboard)
    XCTAssertEqual(verdict.logEvidence, "read-unwatched")
  }

  /// The text was taken and the watched field shows the words (Claude with
  /// a caret): landed. Taken and the words not seen: not typed in, however
  /// fast the pasteboard was read.
  func testAWatchedFieldDecidesATakenPaste() {
    XCTAssertEqual(TextDeliverer.verdict(taken: true, fieldChanged: true), .landed)
    XCTAssertNil(TextDeliverer.verdict(taken: true, fieldChanged: true).keptReason)
    XCTAssertEqual(TextDeliverer.verdict(taken: true, fieldChanged: false), .takenUnseen)
  }

  /// Regression (review 10-5c S1): a paste that was taken and not seen to
  /// land was reported as 「没有找到输入位置」 (`nowhere`), although the words
  /// may have gone in: a field whose tree had not caught up, a rebuilt or
  /// rewritten field, a field that shows no text. The user then pasted a
  /// second time. It is `unconfirmed` (「无法确认文字是否已输入」); only a paste
  /// nothing asked for is `nowhere`.
  func testATakenPasteThatWasNotSeenIsUnconfirmedNeverNowhere() {
    for watched in [false, nil] as [Bool?] {
      let verdict = TextDeliverer.verdict(taken: true, fieldChanged: watched)
      XCTAssertEqual(verdict.keptReason, .unconfirmed, "\(String(describing: watched))")
      XCTAssertFalse(verdict.restoresPriorClipboard)
    }
    XCTAssertEqual(
      TextDeliverer.verdict(taken: true, fieldChanged: false).logEvidence, "read-not-seen")
    XCTAssertEqual(TextDeliverer.verdict(taken: false, fieldChanged: false).keptReason, .nowhere)
    XCTAssertEqual(
      DeliveryInsertionPort.failureReason(for: .unconfirmed), .unconfirmed)
  }

  /// Regression (review 10-5d R4): nothing read within the 0.4 s paste
  /// window was 「没有找到输入位置」 with 「按 ⌘V 粘贴」, although ⌘V had gone
  /// to the target: an application busy at that moment read the words later
  /// and typed them in, and the user pasted them a second time. A read in
  /// the late-read window after it is 「无法确认文字是否已输入」; only no read
  /// in either window is `nowhere`.
  func testALateReadIsUnconfirmedNotNowhere() async {
    let late = TextDeliverer.verdict(taken: false, takenLate: true, fieldChanged: nil)
    XCTAssertEqual(late, .takenLate)
    XCTAssertEqual(late.keptReason, .unconfirmed)
    XCTAssertFalse(late.restoresPriorClipboard)
    XCTAssertEqual(late.logEvidence, "read-late")
    XCTAssertEqual(
      TextDeliverer.verdict(taken: false, takenLate: true, fieldChanged: false).keptReason,
      .unconfirmed)
    XCTAssertEqual(
      TextDeliverer.verdict(taken: false, takenLate: true, fieldChanged: true), .landed,
      "the words seen in the field after a late read landed")
    XCTAssertEqual(
      TextDeliverer.verdict(taken: false, takenLate: false, fieldChanged: nil).keptReason,
      .nowhere)
    XCTAssertGreaterThanOrEqual(TextDeliverer.lateReadWindowSeconds, 1)
    XCTAssertLessThanOrEqual(TextDeliverer.lateReadWindowSeconds, 2)

    // The promise sees a read that comes after the paste window: the wait
    // for it is what turns a miss into 「无法确认」.
    let promise = PromisedPasteboardText("dictated")
    let name = NSPasteboard.Name("bestASR.tests.\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(promise.write(to: pasteboard))
    let posted = Date()
    let busyTarget = Task.detached {
      try? await Task.sleep(for: .milliseconds(250))
      return NSPasteboard(name: name).string(forType: .string)
    }
    let inWindow = await promise.awaitRequest(after: posted, timeout: 0.1)
    XCTAssertFalse(inWindow, "nothing read within the paste window")
    let afterwards = await promise.awaitRequest(
      after: posted, timeout: TextDeliverer.lateReadWindowSeconds)
    XCTAssertTrue(afterwards, "the late read is seen")
    let read = await busyTarget.value
    XCTAssertEqual(read, "dictated", "and it got the words")
    XCTAssertEqual(
      TextDeliverer.verdict(taken: inWindow, takenLate: afterwards, fieldChanged: nil)
        .keptReason, .unconfirmed)
  }

  /// 收1-14 / 收1-15: the user's clipboard is borrowed only for the 0.4 s
  /// paste window and given back only when the words were seen to land;
  /// every other outcome leaves the words on the clipboard for ⌘V.
  @MainActor
  func testTheClipboardIsBorrowedBrieflyAndGivenBackOnlyOnALanding() {
    let window = TextDeliverer.pasteWindowSeconds
    XCTAssertEqual(window, 0.4)
    let all: [TextDeliverer.PasteVerdict] = [
      .landed, .notTaken, .takenUnseen, .takenUnwatched, .takenLate,
    ]
    XCTAssertEqual(all.filter(\.restoresPriorClipboard), [.landed])
  }

  /// Only something seen in a field proves a delivery; there is no
  /// pasteboard-only evidence any more.
  func testEvidenceIsAlwaysSomethingSeenInAField() {
    XCTAssertNil(DeliveryEvidence(rawValue: "pasteboard"))
    XCTAssertEqual(DeliveryEvidence.field.rawValue, "field")
    XCTAssertEqual(DeliveryEvidence.ownField.rawValue, "own-field")
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
