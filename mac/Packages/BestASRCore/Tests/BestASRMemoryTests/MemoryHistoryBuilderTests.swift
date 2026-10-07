import BestASRDomain
import BestASRMemory
import XCTest

/// v12 find: the 历史 page's rows (ALIGNMENT 查-1, 查-7). Synthetic records.
final class MemoryHistoryBuilderTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  private func dictation(
    _ text: String, delivered: String? = nil, segments: [MemoryItemRecord.Segment] = [],
    playable: Bool = true
  ) -> MemoryItemRecord {
    var record = MemoryItemRecord(
      sessionID: SessionID(), inputMode: .dictation, itemKind: nil, title: "本地记录",
      startedAt: start, updatedAt: start, sourceBundleID: nil, sourceDisplayName: "Typeless",
      sourceIdentifier: nil, text: text, segments: segments, durationNanoseconds: 72_000_000_000,
      playbackAvailable: playable)
    record.deliveredText = delivered
    return record
  }

  private func parse(_ text: String) -> SearchQuery {
    SearchQueryParser.parse(text, context: SearchContext(clock: SearchClock(now: start)))
  }

  func testRowPlaysFromTheSentenceThatMatched() {
    let segments = [
      MemoryItemRecord.Segment(
        startMilliseconds: 0, endMilliseconds: 4_000, personID: nil, personName: nil,
        text: "先说一下周末安排", monotonicStartNanoseconds: 10, monotonicEndNanoseconds: 20),
      MemoryItemRecord.Segment(
        startMilliseconds: 4_000, endMilliseconds: 9_000, personID: nil, personName: nil,
        text: "然后是 GripDiff 的消融实验", monotonicStartNanoseconds: 30, monotonicEndNanoseconds: 40),
    ]
    let record = dictation("先说一下周末安排 然后是 GripDiff 的消融实验", segments: segments)
    let row = MemoryHistoryBuilder.row(record, query: parse("grip diff"), matter: nil)
    XCTAssertEqual(row.playFrom, 30)
    XCTAssertTrue(row.playable)
    XCTAssertEqual(row.source, "口述")
    XCTAssertEqual(row.duration, "1 分 12 秒")
    // Nothing typed: from the start.
    XCTAssertNil(MemoryHistoryBuilder.row(record, query: parse(""), matter: nil).playFrom)
  }

  /// v12 search: a record found only by meaning shows (and plays from) the
  /// piece that was closest, not its first line.
  func testRowFoundByMeaningShowsTheClosestPiece() {
    let segments = [
      MemoryItemRecord.Segment(
        startMilliseconds: 0, endMilliseconds: 4_000, personID: nil, personName: nil,
        text: "先说一下周末安排", monotonicStartNanoseconds: 10, monotonicEndNanoseconds: 20),
      MemoryItemRecord.Segment(
        startMilliseconds: 4_000, endMilliseconds: 9_000, personID: nil, personName: nil,
        text: "续租的合同下周签，房租涨两百", monotonicStartNanoseconds: 30, monotonicEndNanoseconds: 40),
    ]
    let record = dictation("先说一下周末安排\n续租的合同下周签，房租涨两百", segments: segments)
    let row = MemoryHistoryBuilder.row(
      record, query: parse("房东"), matter: nil, near: "续租的合同下周签，房租涨两百")
    XCTAssertEqual(row.line, "续租的合同下周签，房租涨两百")
    XCTAssertEqual(row.playFrom, 30)
    // Without the piece: the first line, from the start.
    let plain = MemoryHistoryBuilder.row(record, query: parse("房东"), matter: nil)
    XCTAssertEqual(plain.line, "先说一下周末安排")
    XCTAssertNil(plain.playFrom)
    XCTAssertEqual(MemoryHistoryBuilder.nearKeys("续租的合同下周签。还有别的"), ["续租的合同下周签"])
    XCTAssertEqual(MemoryHistoryBuilder.nearKeys("嗯"), [])
  }

  func testRowShowsTheDeliveredWordsAndTheMatter() {
    let record = dictation("嗯 那个 报价单 明天发", delivered: "报价单明天发。")
    let row = MemoryHistoryBuilder.row(record, query: nil, matter: ("E1", "采购夹爪"))
    XCTAssertEqual(row.fullText, "报价单明天发。")
    XCTAssertEqual(row.matterTitle, "采购夹爪")
    XCTAssertEqual(row.itemID, record.sessionID.rawValue.uuidString.uppercased())
  }

  func testSnippetStartsNearTheHitInALongLine() {
    let long =
      String(repeating: "很长的开头", count: 20) + "这里提到穹顶研究院" + String(repeating: "结尾", count: 10)
    let (line, cut) = MemoryHistoryBuilder.snippet(long, highlights: ["穹顶"])
    XCTAssertTrue(cut)
    XCTAssertTrue(line.contains("穹顶研究院"))
    XCTAssertLessThan(line.count, long.count)
    let (first, notCut) = MemoryHistoryBuilder.snippet("第一行\n第二行\n第三行", highlights: [])
    XCTAssertEqual(first, "第一行 第二行")
    XCTAssertFalse(notCut)
  }

  func testDaysGroupNewestFirstInTheProductCalendar() {
    let calendar = SearchClock.productCalendar
    let rows = [0.0, -3_600, -90_000, -90_100].map { offset in
      MemoryHistoryRow(
        itemID: UUID().uuidString, time: start.addingTimeInterval(offset), source: "微信",
        symbol: "bubble.left", eventID: nil, matterTitle: nil, line: "x", fullText: "x")
    }
    let days = MemoryHistoryBuilder.days(rows, calendar: calendar)
    XCTAssertEqual(days.map(\.rows.count), [2, 2])
    XCTAssertGreaterThan(days[0].day, days[1].day)
  }
}
