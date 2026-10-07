import BestASRAgentAccess
import BestASRMemory
import Foundation
import MindloomAgentProtocol
import XCTest

/// v12 integration (ALIGNMENT 用-8): the agents' `search` runs 历史's engine
/// (`SearchQueryParser` + the record index's `SearchTokens` rules) over the
/// matters in reach, not a literal or word-by-word match of its own.
final class AgentRecordSearchTests: XCTestCase {
  private let zone = TimeZone(identifier: "Asia/Singapore")!

  /// 2026-09-30 (a Wednesday) 10:00 in the product zone; 上周 is 9/21–9/27.
  private var now: Date { date(9, 30, 10) }

  private func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private var clock: SearchClock { SearchClock(now: now, timeZone: zone) }

  private func item(
    _ id: String, _ text: String, _ month: Int, _ day: Int, from source: String,
    speakers: [String] = []
  ) -> AgentSearchDocument.Item {
    .init(
      itemID: id, text: text, at: date(month, day, 15),
      source: AgentSearchSource(name: source, inputMode: "userItem", itemKind: "text"),
      speakers: speakers)
  }

  /// Three matters, synthetic.
  private var documents: [AgentSearchDocument] {
    [
      AgentSearchDocument(
        matterID: "E-DOME", title: "穹顶研究院实习", status: "等对方回复", people: [], steps: [],
        items: [item("I1", "穹顶那边下周开始实习，先办门禁卡", 9, 25, from: "微信")],
        updatedAt: date(9, 25, 15)),
      AgentSearchDocument(
        matterID: "E-ROBO", title: "RoboPrior 大修返修", status: "回复信写到第三条", people: ["许嘉禾"],
        steps: ["10月7日前交回复信"],
        items: [
          item("I2", "审稿意见的回复信初稿发过来了", 9, 29, from: "邮件", speakers: ["许嘉禾"])
        ],
        updatedAt: date(9, 29, 15)),
      AgentSearchDocument(
        matterID: "E-POSTER", title: "开放日海报", status: "", people: ["小林"], steps: [],
        items: [
          item("I3", "周五前把海报初稿发给虚构甲", 9, 23, from: "微信"),
          item("I4", "海报印刷的报价单", 9, 29, from: "邮件"),
        ],
        updatedAt: date(9, 29, 16)),
    ]
  }

  private func search(
    _ query: String, vocabulary: AgentRecordSearch.Vocabulary = .init()
  ) async -> AgentSearchResult {
    await AgentRecordSearch(vocabulary: { vocabulary }).search(
      query, in: documents, limit: 20, clock: clock)
  }

  /// A sound-alike typo and other spacing and casing find the same matter
  /// (the record index's rules: pinyin grams, camel-case parts, joined words).
  func testSoundAlikesSpacingAndCasing() async {
    let dome = await search("穹鼎 实习")
    XCTAssertEqual(dome.hits.map(\.matterID), ["E-DOME"])
    XCTAssertEqual(dome.hits.first?.field, "标题")
    let robo = await search("robo prior 回复信")
    XCTAssertEqual(robo.hits.first?.matterID, "E-ROBO")
    XCTAssertFalse(robo.hits.first?.partial ?? true)
    let nothing = await search("火星基地")
    XCTAssertEqual(nothing.hits, [])
  }

  /// A word held as typed ranks above one held only by its sound (found in
  /// the live walk: 「论文 火星基地」 came back as full matches through
  /// sound-alikes alone).
  func testWordsAsTypedRankAboveSoundAlikes() async {
    let documents = [
      AgentSearchDocument(
        matterID: "E-SOUND", title: "琼鼎实习安排", status: "", people: [], steps: [], items: [],
        updatedAt: date(9, 29, 15)),
      AgentSearchDocument(
        matterID: "E-TYPED", title: "穹顶实习安排", status: "", people: [], steps: [], items: [],
        updatedAt: date(9, 20, 15)),
    ]
    let result = await AgentRecordSearch().search(
      "穹顶 实习", in: documents, limit: 5, clock: clock)
    XCTAssertEqual(result.hits.map(\.matterID), ["E-TYPED", "E-SOUND"])
    XCTAssertGreaterThan(result.hits[0].score, result.hits[1].score)
  }

  /// Time and source words are conditions on the items (product zone, weeks
  /// from Monday), named back as conditions; the reason is the item that fits.
  func testTimeAndSourceWordsAreConditions() async {
    let result = await search("上周 微信 海报")
    XCTAssertEqual(result.hits.map(\.matterID), ["E-POSTER"])
    XCTAssertEqual(result.hits.first?.itemID, "I3")
    XCTAssertEqual(result.conditions.count, 2)
    XCTAssertTrue(result.conditions.contains("微信"), "\(result.conditions)")
    XCTAssertTrue(result.conditions.contains { $0.hasPrefix("上周") }, "\(result.conditions)")
    XCTAssertEqual(result.dropped, [])
    // The e-mail about the poster came this week, not last.
    let email = await search("邮件 海报")
    XCTAssertEqual(email.hits.first?.itemID, "I4")
  }

  /// When the conditions leave nothing, one is left out and said so (the
  /// App's 「不限「…」」), instead of an empty answer.
  func testAConditionNothingMeetsIsDroppedAndSaid() async throws {
    let result = await search("上周 邮件 海报")
    XCTAssertEqual(result.hits.map(\.matterID), ["E-POSTER"])
    XCTAssertEqual(result.hits.first?.itemID, "I4")
    let dropped = try XCTUnwrap(result.dropped.first)
    XCTAssertTrue(dropped.hasPrefix("上周"), dropped)
    XCTAssertEqual(result.conditions, ["邮件"])
  }

  /// People's names are read from the matters in reach only: a name there is
  /// a condition; any other name is just words, so nothing outside the grant
  /// shapes the answer.
  func testPeopleComeFromTheMattersInReach() async {
    let context = AgentRecordSearch.context(for: documents, clock: clock)
    XCTAssertEqual(Set(context.people.map(\.name)), ["许嘉禾", "小林"])
    XCTAssertEqual(Set(context.sourceNames), ["微信", "邮件"])
    let named = await search("许嘉禾 回复信")
    XCTAssertEqual(named.hits.map(\.matterID), ["E-ROBO"])
    XCTAssertEqual(named.conditions, ["许嘉禾"])
    let unknown = await search("韩梅梅 海报")
    XCTAssertEqual(unknown.conditions, [])
    XCTAssertEqual(unknown.hits.map(\.matterID), ["E-POSTER"])
    XCTAssertEqual(unknown.hits.first?.partial, true)
  }

  /// The dictionary's spoken forms find the written word; the owner's own
  /// name is never a condition.
  func testDictionaryAndOwner() async {
    let words = AgentRecordSearch.Vocabulary(
      lexicon: [SearchLexiconEntry(canonical: "RoboPrior", spoken: ["肉包"])],
      ownerNames: ["小林"])
    let spoken = await search("肉包 回复信", vocabulary: words)
    XCTAssertEqual(spoken.hits.first?.matterID, "E-ROBO")
    let owner = await search("小林 海报", vocabulary: words)
    XCTAssertEqual(owner.conditions, [])
    XCTAssertEqual(owner.hits.map(\.matterID), ["E-POSTER"])
    XCTAssertEqual(owner.hits.first?.partial, false)
  }

  /// Only conditions: the matters that fit, the most recent first.
  func testOnlyATimeListsTheMattersOfThatTime() async {
    let result = await search("上周")
    XCTAssertEqual(result.hits.map(\.matterID), ["E-DOME", "E-POSTER"])
    XCTAssertEqual(result.hits.map(\.itemID), ["I1", "I3"])
  }

  // MARK: Through the service

  /// The tool answers with the conditions it read and the one it left out,
  /// inside the fence (a person's name is the library's word), and marks a
  /// matter holding only some of the words.
  func testTheToolSaysConditionsAndPartialMatches() async throws {
    let owner = ScriptedOwner()
    let service = AgentAccessService(
      memory: FixedMemory(snapshot: try AgentFixture.snapshot()), records: MemoryAgentRecords(),
      secrets: MemoryAgentGrantSecretStore(), consent: owner,
      timeZone: AgentFixture.timeZone, clock: { AgentFixture.now })
    await owner.queue(allowAll(spaces: ["personal", "lab"]))
    let client = await AgentTestClient(service: service)
    // 第三组 came in this week from 微信 (fixture: 2026-09-30, 5 hours ago).
    let wechat = await client.call("search", ["query": "微信 第三组"])
    XCTAssertEqual(wechat.matterIDs.first, AgentFixture.twin)
    XCTAssertEqual(wechat.structured?["conditions"], ["微信"])
    XCTAssertTrue(wechat.text.fenced.contains("按条件：微信"), wechat.text)
    let lastWeek = await client.call("search", ["query": "上周 第三组"])
    XCTAssertEqual(lastWeek.matterIDs.first, AgentFixture.twin)
    let dropped = lastWeek.structured?["dropped_conditions"]?.arrayValue ?? []
    XCTAssertEqual(dropped.count, 1)
    XCTAssertTrue(lastWeek.text.fenced.contains("下面不限“上周"), lastWeek.text)
    let some = await client.call("search", ["query": "第三组 火星基地"])
    XCTAssertEqual(some.matterIDs.first, AgentFixture.twin)
    XCTAssertEqual(some.structured?["matters"]?.arrayValue?.first?["partial"], true)
    XCTAssertTrue(some.text.fenced.contains("（只包含其中一部分词）"), some.text)
  }
}
