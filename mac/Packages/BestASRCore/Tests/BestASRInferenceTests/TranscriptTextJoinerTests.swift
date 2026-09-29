import BestASRInference
import XCTest

final class TranscriptTextJoinerTests: XCTestCase {
  func testEnglishSentenceBoundariesAndClosingQuotesRemainReadable() {
    XCTAssertEqual(
      TranscriptTextJoiner.join(["First sentence.", "Second sentence!", "Why?", "Next."]),
      "First sentence. Second sentence! Why? Next.")
    XCTAssertEqual(
      TranscriptTextJoiner.join(["He said “yes.”", "Then left."]),
      "He said “yes.” Then left.")
    XCTAssertEqual(TranscriptTextJoiner.join(["hello", "world"]), "hello world")
  }

  func testChineseAndPunctuationOnlyFragmentsDoNotAcquireInventedSpaces() {
    XCTAssertEqual(TranscriptTextJoiner.join(["第一句。", "第二句。"]), "第一句。第二句。")
    XCTAssertEqual(TranscriptTextJoiner.join(["Hello", ",", "world", "."]), "Hello, world.")
    XCTAssertEqual(TranscriptTextJoiner.join(["中文 use Codex.", "Next."]), "中文 use Codex. Next.")
    XCTAssertEqual(TranscriptTextJoiner.join([" \n", " hello ", "", " world\n"]), "hello world")
  }
}
