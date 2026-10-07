import XCTest

@testable import BestASRProcessing

/// Regression (review 10-6 S10): in a chat App the user fixes the word and
/// presses Return within seconds, which empties the field. The fix is seen
/// by a reading taken before that, and kept.
final class FieldCorrectionTrackerTests: XCTestCase {
  let dictation = "明天上午十点在三楼会议室开评审会"
  let fixed = [LearnedCorrectionCandidate(heard: "议室", written: "议事")]

  func testAFixSeenBeforeTheMessageIsSentIsKept() {
    var tracker = FieldCorrectionTracker(key: "k", inserted: dictation)
    tracker.observe(dictation)
    XCTAssertEqual(tracker.corrections, [])
    tracker.observe("明天上午十点在三楼会议事开评审会")
    tracker.observe(nil)  // Sent: the field is empty.
    XCTAssertEqual(tracker.corrections, fixed)
    tracker.observe("好的，收到")  // The next message.
    XCTAssertEqual(tracker.corrections, fixed)
  }

  func testAFixUndoneIsForgotten() {
    var tracker = FieldCorrectionTracker(key: "k", inserted: dictation)
    tracker.observe("明天上午十点在三楼会议事开评审会")
    tracker.observe(dictation)
    XCTAssertEqual(tracker.corrections, [])
  }
}
