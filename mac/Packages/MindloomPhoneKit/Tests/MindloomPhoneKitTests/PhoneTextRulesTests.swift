import XCTest

@testable import MindloomPhoneKit

/// The recognizer's segments read as written Chinese (device bench, iOS 27 SpeechTranscriber:
/// 「三件事 ，第一」 and 「告诉我。。」).
final class PhoneTextRulesTests: XCTestCase {
  func testNoSpaceBeforeFullWidthPunctuation() {
    XCTAssertEqual(
      PhoneTextRules.tidy("今天的组会主要讨论了三件事 ，第一数据清洗的脚本已经写完 ，下周一开始"),
      "今天的组会主要讨论了三件事，第一数据清洗的脚本已经写完，下周一开始")
  }

  func testDoubledFullStopCollapses() {
    XCTAssertEqual(PhoneTextRules.finalized("有问题请随时告诉我。。"), "有问题请随时告诉我。")
  }

  func testLatinAndNumberSpacingStays() {
    XCTAssertEqual(PhoneTextRules.tidy("下午 4:00要去 MacBook Pro 那边"), "下午 4:00要去 MacBook Pro 那边")
    XCTAssertEqual(PhoneTextRules.tidy("（ 草稿 ）"), "（草稿）")
  }

  func testFinalizedAppendsFullStop() {
    XCTAssertEqual(PhoneTextRules.finalized(" 快递放在楼下 "), "快递放在楼下。")
    XCTAssertEqual(PhoneTextRules.finalized(""), "")
  }
}
