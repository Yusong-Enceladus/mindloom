import XCTest

@testable import BestASRProcessing

/// The questions a language model answers confidently and wrongly, and which
/// have exactly one right answer. Measured on the installed 1.7B: 十七乘以
/// 二十三 came back as 四百五十五, and 一英里等于多少公里 as 0.62137 — the
/// conversion inverted.
final class SpokenCalculationTests: XCTestCase {
  func testTheArithmeticTheModelGotWrong() {
    XCTAssertEqual(SpokenCalculation.answer(to: "十七乘以二十三等于多少"), "391")
    XCTAssertEqual(SpokenCalculation.answer(to: "17 乘以 23"), "391")
    XCTAssertEqual(SpokenCalculation.answer(to: "十七乘二十三是多少"), "391")
  }

  func testTheFourOperations() {
    XCTAssertEqual(SpokenCalculation.answer(to: "一百二十八加七十二等于多少"), "200")
    XCTAssertEqual(SpokenCalculation.answer(to: "一千减去三百五"), "650")
    XCTAssertEqual(SpokenCalculation.answer(to: "九十六除以八等于多少"), "12")
    XCTAssertEqual(SpokenCalculation.answer(to: "3.5 + 1.25"), "4.75")
  }

  func testChineseNumeralsUpToHundredMillion() {
    XCTAssertEqual(SpokenCalculation.chineseNumber("十五"), 15)
    XCTAssertEqual(SpokenCalculation.chineseNumber("两百三十"), 230)
    XCTAssertEqual(SpokenCalculation.chineseNumber("一千零八"), 1008)
    XCTAssertEqual(SpokenCalculation.chineseNumber("三万五千"), 35000)
    XCTAssertEqual(SpokenCalculation.chineseNumber("两亿"), 200_000_000)
  }

  /// The direction is the part the model inverted: one mile is 1.609 km, not
  /// 0.62137.
  func testTheUnitConversionTheModelInverted() {
    XCTAssertEqual(
      SpokenCalculation.answer(to: "一英里等于多少公里"), "1英里 = 1.6093公里")
    XCTAssertEqual(
      SpokenCalculation.answer(to: "一公里等于多少英里"), "1公里 = 0.6214英里")
  }

  func testTheUnitsPeopleDictate() {
    XCTAssertEqual(
      SpokenCalculation.answer(to: "一百八十磅是多少公斤"), "180磅 = 81.6466公斤")
    XCTAssertEqual(
      SpokenCalculation.answer(to: "两斤等于多少克"), "2斤 = 1000克")
    XCTAssertEqual(
      SpokenCalculation.answer(to: "六英尺是多少厘米"), "6英尺 = 182.88厘米")
    XCTAssertEqual(
      SpokenCalculation.answer(to: "100 miles in km"), "100miles = 160.9344km")
  }

  /// Narrowness is the point: anything this does not recognise goes to the
  /// model untouched rather than being answered with a guess.
  func testEverythingElseFallsThrough() {
    for question in [
      "澳大利亚的首都是哪里",
      "写一句话回复说我明天没空",
      "把这段改短一点",
      "今天天气怎么样",
      "这个方案我们下周一起过一遍",
      "翻译成英文",
    ] {
      XCTAssertNil(SpokenCalculation.answer(to: question), question)
    }
  }

  /// Mismatched dimensions have no answer, and an answer that is not a number
  /// must never be shown as one.
  func testImpossibleConversionsAndBrokenExpressionsAreRefused() {
    XCTAssertNil(SpokenCalculation.answer(to: "一公斤等于多少公里"))
    XCTAssertNil(SpokenCalculation.answer(to: "五除以零等于多少"))
    XCTAssertNil(SpokenCalculation.answer(to: "三加"))
  }
}
