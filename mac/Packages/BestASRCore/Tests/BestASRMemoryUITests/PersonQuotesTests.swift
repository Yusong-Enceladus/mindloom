import BestASRDomain
import BestASRMemory
import XCTest

@testable import BestASRMemoryUI

/// The Person page's 说过的话: only the person's own turns, one line from
/// each of their most important matters, a spoken, substantive line that
/// names its matter before a chat's, a short one or small talk, and no
/// section for someone who said nothing.
@MainActor
final class PersonQuotesTests: XCTestCase {
  private typealias F = MemorySnapshotFixture

  private func person(_ id: String, in projection: MemoryProjection) throws -> MemoryPersonEntry {
    let state = MemoryScreenState(
      mode: .spark, projection: projection, now: F.now, calendar: F.calendar)
    return try XCTUnwrap(state.person(id))
  }

  func testOneLinePerMatterSaidAloudBeforeANewerChatLine() throws {
    let projection = F.sparkProjection(questions: false)
    let quotes = PersonQuotes.quotes(of: try person(F.wang, in: projection), in: projection)
    // 租房续约 is her only matter with her words: the recording's longer
    // turn, not its later "行，周五你过来签。" (seven characters) nor the
    // pasted chat's lines.
    XCTAssertEqual(quotes.map(\.text), ["热水器周六让师傅来看。"])
    XCTAssertEqual(quotes.first?.source, "当面")
    XCTAssertEqual(quotes.first?.spoken, true)
    // A recording's turn is dated at its start in the recording.
    XCTAssertEqual(quotes.first?.date, F.date(9, 24, 19, 40))
    XCTAssertEqual(quotes.first?.rowID, F.item(4))
  }

  func testMeetingSpeakerAndOneKnownChatLineAreAttributed() throws {
    let projection = F.sparkProjection(questions: false)
    let zhou = PersonQuotes.quotes(of: try person(F.zhou, in: projection), in: projection)
    XCTAssertEqual(zhou.map(\.text), ["第三页数据还缺，周二前给我。"])
    XCTAssertEqual(zhou.first?.source, "腾讯会议")
    let mom = PersonQuotes.quotes(of: try person(F.mom, in: projection), in: projection)
    XCTAssertEqual(mom.map(\.text), ["周四的号挂上了，上午十点。"])
    XCTAssertEqual(mom.first?.eventID, "ev-mom")
    XCTAssertEqual(mom.first?.spoken, false)
    // The row it opens is the item's row on that event page.
    XCTAssertEqual(mom.first?.rowID, F.item(6))
  }

  func testNoAttributedLinesMeansNoSection() throws {
    let projection = F.sparkProjection(questions: false)
    // 阿杰 is in 周末露营, whose only item is a plain message.
    XCTAssertEqual(PersonQuotes.quotes(of: try person(F.jie, in: projection), in: projection), [])
  }

  private static let wangP = MemoryItemRecord.Person(id: F.pid(F.wang), name: "王姐")
  private static let meP = MemoryItemRecord.Person(id: F.pid(F.me), name: "我")

  private static func chat(_ n: Int, _ date: Date, _ lines: [String]) -> MemoryItemRecord {
    F.record(
      n, .userItem, kind: .text, at: date, app: "微信", bundle: "com.tencent.xinWeChat",
      text: lines.joined(separator: "\n"))
  }

  private static func projection(
    _ events: [RemoteOrganizerEvent], _ records: [MemoryItemRecord]
  ) -> MemoryProjection {
    // Listed in Home order, as the Spark's projection is.
    MemoryProjection(
      remote: RemoteOrganizerProjection(cursor: 1, events: events, questions: [], persons: F.persons),
      records: records, now: F.now, ownerPersonIDs: [F.me])
  }

  func testTheMattersSheCarriesComeFirstOneLineEach() throws {
    func seg(_ who: String, _ text: String, _ start: Int64) -> MemoryItemRecord.Segment {
      .init(
        startMilliseconds: start, endMilliseconds: start + 1_000, personID: F.pid(who),
        personName: who == F.wang ? "王姐" : "我", text: text)
    }
    let records = [
      Self.chat(41, F.date(9, 20, 9, 0), ["王姐：宽带下个月到期记得续费", "我：好"]),
      // 物业: first after the pin in Home, but only a short line and thanks.
      Self.chat(42, F.date(9, 25, 9, 0), ["王姐：周五再说吧", "我：好", "王姐：好的，谢谢"]),
      // 租房续约: a newer chat line, and an older recording where she speaks.
      Self.chat(43, F.date(9, 20, 20, 0), ["王姐：房租下个月起要涨三百块", "我：最多两百"]),
      F.record(
        44, .roomMicrophone, at: F.date(9, 18, 19, 0), text: "",
        segments: [
          seg(F.wang, "押金的事等签合同再说", 0), seg(F.me, "行", 1_000), seg(F.wang, "好的。", 2_000),
        ],
        people: [Self.wangP, Self.meP], duration: 10),
      // 差旅报销: the newest lines of all, from one chat.
      Self.chat(45, F.date(9, 26, 18, 0), ["王姐：发票记得贴在背面", "我：好", "王姐：行程单也要打印出来附上"]),
      // 搬家: low in Home, but four of its items hold her words.
      Self.chat(46, F.date(9, 10, 9, 0), ["王姐：搬家公司约在周六上午"]),
      Self.chat(47, F.date(9, 11, 9, 0), ["王姐：大件家具先拍照留底"]),
      Self.chat(48, F.date(9, 12, 9, 0), ["王姐：钥匙交接那天我也在场"]),
      Self.chat(49, F.date(9, 13, 9, 0), ["王姐：旧房的水电表记得拍照"]),
    ]
    let projection = Self.projection(
      [
        F.event(
          "ev-pin", "宽带续费", status: "", items: [41], people: [F.wang], importance: 0.3,
          pinned: true),
        F.event("ev-top", "物业", status: "", items: [42], people: [F.wang], importance: 0.95),
        F.event("ev-rent", "租房续约", status: "", items: [43, 44], people: [F.wang], importance: 0.9),
        F.event("ev-trip", "差旅报销", status: "", items: [45], people: [F.wang], importance: 0.6),
        F.event(
          "ev-move", "搬家", status: "", items: [46, 47, 48, 49], people: [F.wang], importance: 0.2),
      ], records)
    let wang = try person(F.wang, in: projection)

    let all = PersonQuotes.quotes(of: wang, in: projection)
    // The pin first; 租房续约 (second in Home, two items) and 搬家 (last in
    // Home, most items) before 差旅报销 (fourth, one item), whose lines are
    // the newest; 物业's short line after every substantive one. 搬家 gives
    // the line that names it, not its newest.
    XCTAssertEqual(all.map(\.eventID), ["ev-pin", "ev-rent", "ev-move", "ev-trip", "ev-top"])
    XCTAssertEqual(
      all.map(\.text),
      ["宽带下个月到期记得续费", "押金的事等签合同再说", "搬家公司约在周六上午", "行程单也要打印出来附上", "周五再说吧"])
    XCTAssertEqual(all.map(\.source), ["微信", "当面", "微信", "微信", "微信"])
    XCTAssertEqual(Set(all.map(\.id)).count, all.count)

    let three = PersonQuotes.quotes(of: wang, in: projection, limit: 3)
    XCTAssertEqual(three.map(\.eventID), ["ev-pin", "ev-rent", "ev-move"])
  }

  func testALineTwoMattersHoldIsShownOnce() throws {
    let records = [Self.chat(51, F.date(9, 22, 20, 0), ["王姐：押金一个月月底前转", "王姐：维修费用按合同第七条算"])]
    let projection = Self.projection(
      [
        F.event("ev-a", "租房续约", status: "", items: [51], people: [F.wang], importance: 0.9),
        F.event("ev-b", "维修", status: "", items: [51], people: [F.wang], importance: 0.5),
      ], records)
    let quotes = PersonQuotes.quotes(of: try person(F.wang, in: projection), in: projection)
    XCTAssertEqual(quotes.map(\.eventID), ["ev-a", "ev-b"])
    XCTAssertEqual(quotes.map(\.text), ["维修费用按合同第七条算", "押金一个月月底前转"])
  }

  func testALineThatNamesItsMatterBeforeSmallTalk() throws {
    func seg(_ who: String, _ text: String, _ start: Int64) -> MemoryItemRecord.Segment {
      .init(
        startMilliseconds: start, endMilliseconds: start + 1_000, personID: F.pid(who),
        personName: who == F.wang ? "王姐" : "我", text: text)
    }
    let records = [
      F.record(
        61, .roomMicrophone, at: F.date(9, 20, 10, 0), text: "",
        segments: [
          seg(F.wang, "宽带师傅明天上午来装", 0), seg(F.me, "好", 1_000),
          seg(F.wang, "今天天气真不错，出去走走吧", 2_000),
        ],
        people: [Self.wangP, Self.meP], duration: 10),
      // Newer and naming it too, but written.
      Self.chat(62, F.date(9, 21, 9, 0), ["王姐：宽带账号密码贴在路由器背面"]),
    ]
    let projection = Self.projection(
      [F.event("ev-net", "新家宽带", status: "", items: [61, 62], people: [F.wang], importance: 0.5)],
      records)
    let quotes = PersonQuotes.quotes(of: try person(F.wang, in: projection), in: projection)
    XCTAssertEqual(quotes.map(\.text), ["宽带师傅明天上午来装"])
  }

  func testTitleTermsAreItsWordsLessNames() {
    XCTAssertEqual(PersonQuotes.titleTerms("TG-2换PG-80夹爪", leaving: []), ["tg", "pg", "80", "夹爪"])
    let midterm = PersonQuotes.titleTerms("林知远博士中期考核", leaving: ["林知远", "周明澜"])
    XCTAssertTrue(midterm.contains("中期"))
    XCTAssertFalse(midterm.contains("知远"))
    XCTAssertTrue(
      PersonQuotes.names("先把精力放在 RoboPrior 上", terms: ["roboprior"], factQuotes: []))
    XCTAssertTrue(PersonQuotes.names("那涨 200 我这边没问题。", terms: [], factQuotes: ["那涨 200 我这边没问题"]))
    XCTAssertFalse(PersonQuotes.names("别老熬夜", terms: ["roboprior", "返修"], factQuotes: []))
  }

  func testGreetingsAndThanksAreNotLines() {
    XCTAssertTrue(PersonQuotes.isFiller("收到，谢谢老师"))
    XCTAssertTrue(PersonQuotes.isFiller("好的好的！"))
    XCTAssertTrue(PersonQuotes.isFiller("OK thanks"))
    XCTAssertTrue(PersonQuotes.isFiller("好了好了，散会散会。"))
    XCTAssertFalse(PersonQuotes.isFiller("好好准备答辩"))
    XCTAssertFalse(PersonQuotes.isFiller("嗯 你负责汇报就行 别掉链子"))
    // Letters and digits count; spaces and punctuation do not.
    XCTAssertEqual(PersonQuotes.words("嗯 你负责汇报就行 别掉链子").count, 12)
    XCTAssertEqual(PersonQuotes.words("早鸟10/10 不急").count, 8)
  }
}
