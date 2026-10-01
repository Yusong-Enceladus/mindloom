import Foundation
import XCTest

@testable import MindloomPhone

/// Regression (phone E2E, 2026-09-30): the 送往 Mac rows kept saying "刚刚"
/// minutes after an entry was sent, next to a newer row that already said
/// "5 分钟前", because a row is only redrawn when its entry changes. The rows
/// now redraw from a minute timeline, which only helps if the label is
/// computed from the timeline's date, not from the wall clock at draw time.
@MainActor
final class OutboxTimeLabelTests: XCTestCase {
  func testTheLabelIsCountedFromTheGivenNow() {
    let sent = Date(timeIntervalSince1970: 1_790_756_000)
    XCTAssertEqual(OutboxCard.relative(sent, now: sent.addingTimeInterval(20)), "刚刚")
    let later = OutboxCard.relative(sent, now: sent.addingTimeInterval(9 * 60))
    XCTAssertNotEqual(later, "刚刚")
    XCTAssertTrue(later.contains("9"), later)
    // Far from the wall clock: the label still follows `now`.
    let old = Date(timeIntervalSince1970: 1_000_000_000)
    let label = OutboxCard.relative(old, now: old.addingTimeInterval(3 * 60))
    XCTAssertTrue(label.contains("3"), label)
  }
}
