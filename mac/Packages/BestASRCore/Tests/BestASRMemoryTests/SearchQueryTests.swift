import BestASRMemory
import XCTest

/// v12 find: the lexical rules (B4 §3.2a) and the query reading (§3.2c).
/// Synthetic words only.
final class SearchQueryTests: XCTestCase {
  /// A Friday, 2026-10-02 12:00 in Singapore.
  private func fixedClock() -> SearchClock {
    var parts = DateComponents()
    parts.year = 2026
    parts.month = 10
    parts.day = 2
    parts.hour = 12
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = SearchClock.productTimeZone
    return SearchClock(now: cal.date(from: parts)!)
  }

  private func day(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.timeZone = SearchClock.productTimeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text)!
  }

  // MARK: - Normalization

  func testWidthCaseAndTraditionalFold() {
    XCTAssertEqual(SearchText.normalize("ＧｒｉｐＤｉｆｆ"), "gripdiff")
    XCTAssertEqual(SearchText.normalize("們的會議"), "们的会议")
    XCTAssertEqual(SearchText.normalize("Café"), "cafe")
  }

  func testCamelCaseAndDigitsSplit() {
    XCTAssertEqual(SearchText.wordParts("GripDiff"), ["grip", "diff"])
    XCTAssertEqual(SearchText.wordParts("HTTPServer"), ["http", "server"])
    XCTAssertEqual(SearchText.wordParts("Twin7"), ["twin", "7"])
    XCTAssertEqual(SearchText.wordParts("plain"), ["plain"])
  }

  func testIndexTokensHaveGramsCharactersPinyinAndJoinedWords() {
    let indexed = SearchText.indexTokens("穹顶具身组用 Grip Diff 和 TouchFold")
    let body = Set(indexed.body.split(separator: " ").map(String.init))
    XCTAssertTrue(body.isSuperset(of: ["穹顶", "顶具", "具身", "身组", "组用"]))
    XCTAssertTrue(body.isSuperset(of: ["grip", "diff", "gripdiff", "touchfold", "touch", "fold"]))
    XCTAssertTrue(indexed.uni.split(separator: " ").contains("穹"))
    XCTAssertTrue(indexed.pin.split(separator: " ").contains("qiongding"))
  }

  // MARK: - Matching rules in memory (the same rules the index applies)

  private func parse(_ text: String, context: SearchContext? = nil) -> SearchQuery {
    SearchQueryParser.parse(text, context: context ?? SearchContext(clock: fixedClock()))
  }

  func testSpacesInsideWordsAndCaseStillMatch() {
    let tokens = SearchTokens("这周 GripDiff 的消融实验跑完了")
    XCTAssertTrue(parse("grip diff").matches(tokens))
    XCTAssertTrue(parse("gripdiff").matches(tokens))
    XCTAssertTrue(parse("GRIPDIFF ").matches(tokens))
    XCTAssertFalse(parse("grip fold").matches(tokens))
  }

  func testTwoWordsNeedNotTouch() {
    let tokens = SearchTokens("杭州那边的协议，下周谈合作细节")
    XCTAssertTrue(parse("杭州 合作").matches(tokens))
    XCTAssertTrue(parse("杭州合作").matches(tokens))
  }

  func testHomophoneTypoMeetsByPinyin() {
    let tokens = SearchTokens("穹顶具身组的实习面试")
    XCTAssertTrue(parse("穹鼎").matches(tokens))
  }

  func testTraditionalQueryFindsSimplifiedText() {
    XCTAssertTrue(parse("會議紀要").matches(SearchTokens("把会议纪要发给大家")))
  }

  func testDictionarySpokenFormFindsTheWrittenWord() {
    let lexicon = [SearchLexiconEntry(canonical: "RoboPrior", spoken: ["肉包普瑞尔"])]
    let context = SearchContext(lexicon: lexicon, clock: fixedClock())
    let query = parse("肉包普瑞尔 返修", context: context)
    XCTAssertTrue(query.matches(SearchTokens("RoboPrior 大修返修意见到了")))
    XCTAssertTrue(query.highlights.contains("RoboPrior"))
  }

  func testQuestionWordsAreDropped() {
    let query = parse("实习什么时候入职")
    XCTAssertEqual(query.units.map(\.text), ["实习", "入职"])
    XCTAssertTrue(query.matches(SearchTokens("研究实习 offer 已发，4月13日入职")))
  }

  // MARK: - Conditions

  func testPersonSourceAndTimeBecomeChips() {
    let people = [SearchPerson(id: "p1", name: "陆思成", aliases: ["陆老师"])]
    let context = SearchContext(people: people, clock: fixedClock())
    let query = parse("上周 微信里陆老师说的报价", context: context)
    XCTAssertEqual(query.people.map(\.id), ["p1"])
    XCTAssertEqual(query.sources.map(\.label), ["微信"])
    XCTAssertEqual(query.interval?.start, day("2026-09-21"))
    XCTAssertEqual(query.interval?.end, day("2026-09-28"))
    XCTAssertEqual(query.units.map(\.text), ["报价"])
    XCTAssertEqual(Set(query.chips.map(\.label)).count, 3)
    XCTAssertFalse(query.ordersByTime)
  }

  func testOnlyConditionsOrderByTime() {
    let query = parse("昨天 口述")
    XCTAssertTrue(query.ordersByTime)
    XCTAssertEqual(query.sources.first?.inputModes, ["dictation"])
    XCTAssertEqual(query.interval?.start, day("2026-10-01"))
  }

  func testGenericSourceWordInsideAWordStaysContent() {
    let query = parse("会议纪要")
    XCTAssertTrue(query.sources.isEmpty)
    XCTAssertFalse(query.units.isEmpty)
  }

  func testOwnerIsNeverACondition() {
    let people = [SearchPerson(id: "me", name: "林知远", aliases: ["知远"])]
    let context = SearchContext(people: people, ownerNames: ["林知远", "知远"], clock: fixedClock())
    XCTAssertTrue(parse("知远 报价", context: context).people.isEmpty)
  }

  func testTimeWords() {
    let c = fixedClock()
    func interval(_ text: String) -> DateInterval? {
      SearchQueryParser.parse(text, context: SearchContext(clock: c)).interval
    }
    XCTAssertEqual(interval("今天")?.start, day("2026-10-02"))
    XCTAssertEqual(interval("前天")?.start, day("2026-09-30"))
    XCTAssertEqual(interval("这周")?.start, day("2026-09-28"))
    XCTAssertEqual(interval("9月25日")?.start, day("2026-09-25"))
    XCTAssertEqual(interval("9月25号")?.end, day("2026-09-26"))
    XCTAssertEqual(interval("九月")?.start, day("2026-09-01"))
    XCTAssertEqual(interval("9月")?.end, day("2026-10-01"))
    XCTAssertEqual(interval("12月")?.start, day("2025-12-01"))
    XCTAssertEqual(interval("周三")?.start, day("2026-09-30"))
    XCTAssertEqual(interval("周六")?.start, day("2026-09-26"))
    XCTAssertEqual(interval("上周三")?.start, day("2026-09-23"))
    XCTAssertEqual(interval("最近三天")?.start, day("2026-09-30"))
    XCTAssertEqual(interval("上个月")?.start, day("2026-09-01"))
    XCTAssertNil(interval("NC27-4471"))
  }

  func testRemovingAChipTakesItsWordsOut() {
    let query = parse("上周 微信里的报价")
    let source = query.chips.first { $0.kind == .source }!
    XCTAssertEqual(SearchQueryParser.removing(source, from: "上周 微信里的报价"), "上周 报价")
    let time = query.chips.first { $0.kind == .time }!
    XCTAssertEqual(SearchQueryParser.removing(time, from: "上周 微信里的报价"), "微信里的报价")
  }

  func testMatchExpressionIsOneFTSQuery() {
    let match = parse("GripDiff 穹顶").match()!
    XCTAssertTrue(match.contains("{body meta people}"))
    XCTAssertTrue(match.contains("{pin}"))
    XCTAssertTrue(match.contains(" AND "))
  }

  // MARK: - Words typed together, lone characters

  func testWordsTypedTogetherAreAlsoAPhrase() {
    let spaced = parse("叠 衣服")
    XCTAssertEqual(spaced.phraseTexts, ["叠衣服"])
    XCTAssertNotNil(spaced.phraseMatch)
    XCTAssertTrue(spaced.highlights.contains("叠衣服"))
    let latin = parse("Robo Prior")
    XCTAssertTrue(latin.phraseTexts.contains("roboprior"))
    // A stopword between two words keeps them apart.
    XCTAssertTrue(parse("报价的合同").phrases.isEmpty)
  }

  func testATwoCharacterTypoWithAStopwordIsOneWord() {
    XCTAssertEqual(parse("理聊").units.map(\.text), ["理聊"])
    XCTAssertTrue(parse("理聊").matches(SearchTokens("下午去理疗")))
  }

  func testALoneCharacterNextToWordsIsNotRequired() {
    let query = parse("匿名代码传了吗")
    XCTAssertFalse(query.units.contains { $0.text == "传" || $0.text == "传了" })
    XCTAssertTrue(query.matches(SearchTokens("匿名代码我晚上整理好")))
    // Alone it still counts.
    XCTAssertEqual(parse("租").units.map(\.text), ["租"])
  }

  func testAllButOneWordStepNeedsThreeWords() {
    XCTAssertNil(parse("报价 合同").mostMatch)
    XCTAssertNotNil(parse("报价 合同 发票").mostMatch)
  }
}
