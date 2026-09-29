import BestASRDictation
import XCTest

/// Keeping text for copying is the designed answer when there was nowhere
/// to write; it is a failure when an engine that should have produced text
/// did not. A delivery rate that mixes the two measures nothing.
final class InsertionOutcomeClassificationTests: XCTestCase {
  func testReasonsThatAreTheSystemDoingItsJob() {
    for reason in [
      DictationInsertionFailureReason.nowhere, .secureInput, .applicationChanged,
      .permissionDenied, .nothingToInsert,
    ] {
      XCTAssertTrue(reason.declinedByDesign, "\(reason)")
    }
  }

  func testReasonsThatAreDefects() {
    for reason in [DictationInsertionFailureReason.unavailable, .ambiguousReservation] {
      XCTAssertFalse(reason.declinedByDesign, "\(reason)")
    }
  }

  func testTheVocabularyIsSmallAndComplete() {
    let all: [DictationInsertionFailureReason] = [
      .nowhere, .secureInput, .applicationChanged, .permissionDenied, .nothingToInsert,
      .unavailable, .ambiguousReservation,
    ]
    XCTAssertEqual(Set(all.map(\.rawValue)).count, 7)
    for reason in all {
      XCTAssertEqual(DictationInsertionFailureReason(rawValue: reason.rawValue), reason)
    }
  }
}
