import BestASRProcessing
import XCTest

final class DictationEditExtractorTests: XCTestCase {
  func testAFixedWordIsRecovered() {
    let inserted = "他说的是在座的各位同事，明天上午十点开会"
    let edited = "他说的是在坐的各位同事，明天上午十点开会"
    XCTAssertEqual(
      DictationEditExtractor.pairs(inserted: inserted, fieldContents: edited),
      [DictationEditPair(recognized: "座", corrected: "坐")])
  }

  func testAnEnglishTermTheUserRecapitalisedIsRecovered() {
    let inserted = "我们用 fable 这个模型跑一下这个 benchmark，看看速度"
    let edited = "我们用 Fable 这个模型跑一下这个 benchmark，看看速度"
    XCTAssertEqual(
      DictationEditExtractor.pairs(inserted: inserted, fieldContents: edited),
      [DictationEditPair(recognized: "f", corrected: "F")])
  }

  func testTextTypedAroundTheDictationIsNotTreatedAsACorrection() {
    let inserted = "明天上午十点在三楼会议室开评审会"
    let edited = "@老王 明天上午十点在三楼会议室开评审会，麻烦你提前到一下"
    XCTAssertEqual(DictationEditExtractor.pairs(inserted: inserted, fieldContents: edited), [])
  }

  func testAClearedFieldTeachesNothing() {
    let inserted = "明天上午十点在三楼会议室开评审会"
    XCTAssertEqual(DictationEditExtractor.pairs(inserted: inserted, fieldContents: ""), [])
    XCTAssertEqual(DictationEditExtractor.pairs(inserted: inserted, fieldContents: "好的"), [])
  }

  func testARewrittenSentenceTeachesNothing() {
    let inserted = "我觉得这个方案可以先跑一遍看看结果"
    let edited = "这个我再想想，晚点给你答复"
    XCTAssertEqual(DictationEditExtractor.pairs(inserted: inserted, fieldContents: edited), [])
  }

  func testAWholeClauseReplacedIsTooLongToCountAsAMisheardWord() {
    let inserted = "这个模型的准确率比上一版高了不少，延迟也没有变差"
    let edited = "这个模型的准确率比上一版高了不少，内存占用和启动时间也都还行"
    XCTAssertEqual(DictationEditExtractor.pairs(inserted: inserted, fieldContents: edited), [])
  }

  func testTheDictationFoundLaterInALongerFieldIsStillMatched() {
    let inserted = "麻烦把这个接口的超时时间调成三十秒"
    let edited = "刚才讨论的两件事：一是发布节奏，二是稳定性。麻烦把这个接口的超时时间调成三十妙，另外记得同步给测试"
    XCTAssertEqual(
      DictationEditExtractor.pairs(inserted: inserted, fieldContents: edited),
      [DictationEditPair(recognized: "秒", corrected: "妙")])
  }

  func testAnUnchangedDictationProducesNothing() {
    let inserted = "这段话我一个字都没改"
    XCTAssertEqual(
      DictationEditExtractor.pairs(inserted: inserted, fieldContents: inserted), [])
    XCTAssertEqual(
      DictationEditExtractor.pairs(inserted: inserted, fieldContents: "前面有别的话。" + inserted),
      [])
  }

  func testALongDictationIsExtractedQuickly() {
    let inserted = String(repeating: "今天我们讨论了模型的准确率和速度，", count: 20) + "结论是先上线"
    let edited = inserted.replacingOccurrences(of: "结论是先上线", with: "结论是先上限")
    let started = ContinuousClock.now
    let pairs = DictationEditExtractor.pairs(inserted: inserted, fieldContents: edited)
    XCTAssertEqual(pairs, [DictationEditPair(recognized: "线", corrected: "限")])
    XCTAssertLessThan(started.duration(to: .now), .milliseconds(400))
  }
}
