import BestASRProcessing
import XCTest

final class ProtectedFactValidatorTests: XCTestCase {
  func testPunctuationAndFormattingPassWhenProtectedFactsStayExact() {
    let result = DictationProtectedFactValidator.validate(
      source: "do not send 25% to Alice at 10:30 email a@example.com",
      candidate: "Do not send 25% to Alice at 10:30. Email a@example.com.",
      dictionaryTerms: ["Alice"]
    )
    XCTAssertTrue(result.passed)
    XCTAssertEqual(result.violatedCategories, [])
  }

  func testChangedProtectedCategoriesFailAtZeroTolerance() {
    let source = "Do not pay Alice $25 on 2026-08-01. See https://example.com/a"
    let cases: [(String, DictationProtectedFactCategory)] = [
      (
        "Do not pay Alice $35 on 2026-08-01. See https://example.com/a",
        .money
      ),
      (
        "Do pay Alice $25 on 2026-08-01. See https://example.com/a",
        .negation
      ),
      (
        "Do not pay Bob $25 on 2026-08-01. See https://example.com/a",
        .dictionaryTerm
      ),
      (
        "Do not pay Alice $25 on 2026-08-01. See https://example.com/b",
        .url
      ),
    ]
    for (candidate, category) in cases {
      let result = DictationProtectedFactValidator.validate(
        source: source,
        candidate: candidate,
        dictionaryTerms: ["Alice"]
      )
      XCTAssertFalse(result.passed, candidate)
      XCTAssertTrue(result.violatedCategories.contains(category), candidate)
    }
  }

  func testBilingualNumbersMoneyPercentDatesAndTimesAreIndependent() {
    let source = "张明将在2026年8月1日10:30支付人民币1,250.50元，占25%。"
    let cases: [(String, DictationProtectedFactCategory)] = [
      ("张明将在2026年8月2日10:30支付人民币1,250.50元，占25%。", .dateTime),
      ("张明将在2026年8月1日11:30支付人民币1,250.50元，占25%。", .dateTime),
      ("张明将在2026年8月1日10:30支付人民币1,350.50元，占25%。", .money),
      ("张明将在2026年8月1日10:30支付人民币1,250.50元，占35%。", .percentage),
    ]

    for (candidate, category) in cases {
      let result = DictationProtectedFactValidator.validate(
        source: source,
        candidate: candidate,
        dictionaryTerms: ["张明"]
      )
      XCTAssertFalse(result.passed, candidate)
      XCTAssertTrue(result.violatedCategories.contains(category), candidate)
      XCTAssertTrue(
        result.violatedCategories.contains(.numberDateTimeAmount),
        candidate
      )
    }
  }

  func testBilingualNegationCommitmentAndActionOwnerChangesAreRejected() {
    let source = "Alice will send the report. 张明负责审核，李雷不会付款。"
    let cases: [(String, DictationProtectedFactCategory)] = [
      ("Alice may send the report. 张明负责审核，李雷不会付款。", .commitment),
      ("Alice will send the report. 张明负责审核，李雷会付款。", .negation),
      ("Alice will send the report. 李雷负责审核，张明不会付款。", .actionOwner),
    ]

    for (candidate, category) in cases {
      let result = DictationProtectedFactValidator.validate(
        source: source,
        candidate: candidate,
        dictionaryTerms: ["Alice", "张明", "李雷"]
      )
      XCTAssertFalse(result.passed, candidate)
      XCTAssertTrue(result.violatedCategories.contains(category), candidate)
    }
  }

  func testAddedUnsupportedFactIsRejectedButContentRemovalIsAllowed() {
    let added = DictationProtectedFactValidator.validate(
      source: "We will ship the build",
      candidate: "We will ship the build tomorrow.",
      dictionaryTerms: []
    )
    XCTAssertFalse(added.passed)
    XCTAssertTrue(added.violatedCategories.contains(.unsupportedFact))

    let removedFiller = DictationProtectedFactValidator.validate(
      source: "We will um ship the build",
      candidate: "We will ship the build.",
      dictionaryTerms: []
    )
    XCTAssertTrue(removedFiller.passed)
  }

  func testChineseOwnerRelationAllowsLaterRepetitionCleanup() {
    let repeated = DictationProtectedFactValidator.validate(
      source: "张明负责审核审核预算预算是42万元",
      candidate: "张明负责审核预算是42万元。",
      dictionaryTerms: ["张明"]
    )
    XCTAssertTrue(repeated.passed)

    let changedAction = DictationProtectedFactValidator.validate(
      source: "张明负责审核预算",
      candidate: "张明负责预算",
      dictionaryTerms: ["张明"]
    )
    XCTAssertFalse(changedAction.passed)
    XCTAssertTrue(changedAction.violatedCategories.contains(.actionOwner))
  }

  func testDictionaryTermsUseWordBoundariesForLatinTerms() {
    let result = DictationProtectedFactValidator.validate(
      source: "Malice is not Alice",
      candidate: "Malice is not Bob",
      dictionaryTerms: ["Alice"]
    )
    XCTAssertFalse(result.passed)
    XCTAssertTrue(result.violatedCategories.contains(.dictionaryTerm))
  }
}
