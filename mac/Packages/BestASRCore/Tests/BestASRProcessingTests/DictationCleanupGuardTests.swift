import BestASRProcessing
import XCTest

final class DictationCleanupGuardTests: XCTestCase {
  func testDeletingFillersAndStuttersIsAccepted() {
    let raw = "嗯，这个这个方案我觉得呃可以先跑一遍，然后然后再看结果"
    let candidate = "这个方案我觉得可以先跑一遍，然后再看结果。"
    XCTAssertEqual(DictationCleanupGuard.accepted(candidate, raw: raw), candidate)
  }

  func testRewritingWordsTheUserSaidIsRejected() {
    let raw = "我们先把虚构样机的效果测一下，再决定要不要改配色"
    let rewrite = "我们先把虚构问题的整体效果测一下，再决定要不要改设计"
    XCTAssertNil(DictationCleanupGuard.accepted(rewrite, raw: raw))
  }

  func testNumberFormattingIsNotCountedAsIntroducedText() {
    let raw = "这个模型的准确率提升了百分之五左右"
    let candidate = "这个模型的准确率提升了 5% 左右。"
    XCTAssertEqual(DictationCleanupGuard.accepted(candidate, raw: raw), candidate)
  }

  func testSummarisingInsteadOfCleaningIsRejected() {
    let raw = "我今天想说的是我们这个项目的三个重点，第一个是速度，第二个是准确率，第三个是内存"
    XCTAssertNil(DictationCleanupGuard.accepted("项目有三个重点。", raw: raw))
  }

  func testEmptyControlOrOversizedOutputIsRejected() {
    let raw = "随便说两句"
    XCTAssertNil(DictationCleanupGuard.accepted("   ", raw: raw))
    XCTAssertNil(DictationCleanupGuard.accepted("随便说两句<|im_end|>", raw: raw))
    XCTAssertNil(DictationCleanupGuard.accepted(String(repeating: "随", count: 9_000), raw: raw))
  }

  func testASingleCorrectedCharacterInALongDictationStaysWithinTheLimit() {
    let raw = String(repeating: "今天我们讨论了模型的准确率和速度，", count: 12) + "他说的是在座的各位"
    let candidate = raw.replacingOccurrences(of: "在座", with: "在坐")
    XCTAssertEqual(DictationCleanupGuard.accepted(candidate, raw: raw), candidate)
  }
}
