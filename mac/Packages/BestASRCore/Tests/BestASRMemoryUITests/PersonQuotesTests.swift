import BestASRDomain
import BestASRMemory
import XCTest

@testable import BestASRMemoryUI

/// The Person page's 说过的话: only the person's own turns, newest first, a
/// few per matter, and no section for someone who said nothing.
@MainActor
final class PersonQuotesTests: XCTestCase {
  private typealias F = MemorySnapshotFixture

  private func person(_ id: String, in projection: MemoryProjection) throws -> MemoryPersonEntry {
    let state = MemoryScreenState(
      mode: .spark, projection: projection, now: F.now, calendar: F.calendar)
    return try XCTUnwrap(state.person(id))
  }

  func testOnlyTheirOwnTurnsFromRecordingsAndChatsNewestFirst() throws {
    let projection = F.sparkProjection(questions: false)
    let quotes = PersonQuotes.quotes(of: try person(F.wang, in: projection), in: projection)
    // The recording's two turns of hers (the later one first), then the
    // pasted chat's two; "我" in between is not hers.
    XCTAssertEqual(
      quotes.map(\.text),
      ["行，周五你过来签。", "热水器周六让师傅来看。", "那我跟家里商量一下， 明天回你。", "下个月起房租想涨 300，你看行不？"])
    XCTAssertEqual(Set(quotes.map(\.eventTitle)), ["租房续约"])
    XCTAssertEqual(quotes.map(\.source), ["当面", "当面", "微信", "微信"])
    // A recording's turn is dated at its start in the recording.
    XCTAssertEqual(quotes[0].date, F.date(9, 24, 19, 40).addingTimeInterval(6))
    XCTAssertEqual(quotes[2].date, F.date(9, 22, 20, 14))
  }

  func testMeetingSpeakerAndOneKnownChatLineAreAttributed() throws {
    let projection = F.sparkProjection(questions: false)
    let zhou = PersonQuotes.quotes(of: try person(F.zhou, in: projection), in: projection)
    XCTAssertEqual(zhou.map(\.text), ["第三页数据还缺，周二前给我。"])
    XCTAssertEqual(zhou.first?.source, "腾讯会议")
    let mom = PersonQuotes.quotes(of: try person(F.mom, in: projection), in: projection)
    XCTAssertEqual(mom.map(\.text), ["周四的号挂上了，上午十点。"])
    XCTAssertEqual(mom.first?.eventID, "ev-mom")
    // The row it opens is the item's row on that event page.
    XCTAssertEqual(mom.first?.rowID, F.item(6))
  }

  func testNoAttributedLinesMeansNoSection() throws {
    let projection = F.sparkProjection(questions: false)
    // 阿杰 is in 周末露营, whose only item is a plain message.
    XCTAssertEqual(PersonQuotes.quotes(of: try person(F.jie, in: projection), in: projection), [])
  }

  func testLimitTwoPerMatterWhileOthersHaveLinesAndShortLinesLeftOut() throws {
    func seg(_ who: String, _ text: String, _ start: Int64) -> MemoryItemRecord.Segment {
      .init(
        startMilliseconds: start, endMilliseconds: start + 1_000, personID: F.pid(who),
        personName: who == F.wang ? "王姐" : "我", text: text)
    }
    let wangP = MemoryItemRecord.Person(id: F.pid(F.wang), name: "王姐")
    let meP = MemoryItemRecord.Person(id: F.pid(F.me), name: "我")
    let records = [
      F.record(
        31, .roomMicrophone, at: F.date(9, 25, 10, 0), text: "",
        segments: [
          seg(F.wang, "第一句先说押金的事", 0), seg(F.me, "嗯你说", 1_000),
          seg(F.wang, "第二句说维修的钱", 2_000), seg(F.me, "然后呢", 3_000),
          seg(F.wang, "好的。", 4_000), seg(F.me, "还有吗", 5_000),
          seg(F.wang, "第三句说退租怎么算", 6_000),
        ],
        people: [wangP, meP], duration: 10),
      F.record(
        32, .roomMicrophone, at: F.date(9, 24, 10, 0), text: "",
        segments: [seg(F.wang, "另一件事里的一句话", 0)], people: [wangP], duration: 5),
    ]
    let remote = RemoteOrganizerProjection(
      cursor: 1,
      events: [
        F.event("ev-a", "租房续约", status: "", items: [31], people: [F.wang], importance: 0.9),
        F.event("ev-b", "新家宽带", status: "", items: [32], people: [F.wang], importance: 0.5),
      ],
      questions: [], persons: F.persons)
    let projection = MemoryProjection(
      remote: remote, records: records, now: F.now, ownerPersonIDs: [F.me])
    let wang = try person(F.wang, in: projection)

    let three = PersonQuotes.quotes(of: wang, in: projection, limit: 3)
    // Two from 租房续约, then 新家宽带's line before a third from 租房续约.
    XCTAssertEqual(three.map(\.text), ["第三句说退租怎么算", "第二句说维修的钱", "另一件事里的一句话"])

    let all = PersonQuotes.quotes(of: wang, in: projection)
    // Room left: the matter's third line fills it; "好的。" is too short.
    XCTAssertEqual(
      all.map(\.text), ["第三句说退租怎么算", "第二句说维修的钱", "第一句先说押金的事", "另一件事里的一句话"])
    XCTAssertEqual(Set(all.map(\.id)).count, all.count)
  }
}
