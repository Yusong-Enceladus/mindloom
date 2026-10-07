import BestASRDomain
import BestASRMemory
import CoreGraphics
import Foundation
import XCTest

/// v7 (MAP-CONTRACT §3): the 线索 model from a matter's map (strands, main
/// thread, knots, evidence), the facts on one thread before a map exists,
/// the status bar, the layout (deterministic, strands on their slots, labels
/// that never touch), the 网 lens graph, ropes as shown, and Home's lenses.
/// Synthetic data only.
final class MemoryMatterMapTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, _ hour: Int = 10) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private func id(_ n: Int) -> String { String(format: "D0000000-0000-4000-8000-%012d", n) }

  private func record(_ n: Int, at: Date, text: String, mode: SessionInputMode = .userItem)
    -> MemoryItemRecord
  {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: id(n))!), inputMode: mode,
      itemKind: mode == .userItem ? .text : nil, title: "记录", startedAt: at, updatedAt: at,
      sourceBundleID: "com.tencent.xinWeChat", sourceDisplayName: "微信", sourceIdentifier: nil,
      text: text)
  }

  /// Twelve items over 9/1–9/12; items 1–4 on strand s1 (open), 5–6 on s2
  /// (closed), the rest on the main thread. Item 9 is held as a part.
  private var records: [MemoryItemRecord] {
    (1...12).map { n in
      record(
        n, at: date(9, n),
        text: n == 3 ? "周明：电机修好了，明天恢复实验\n我：好" : "赵晴：第\(n)天的记录\n我：收到",
        mode: n == 7 ? .dictation : .userItem)
    }
  }

  private var map: RemoteOrganizerMatterMap {
    typealias K = RemoteOrganizerMatterMap.Knot
    return RemoteOrganizerMatterMap(
      strands: [
        .init(id: "s1", name: "实验调试", summary: "电机修好", itemIDs: (1...4).map(id)),
        .init(id: "s2", name: "开放日", itemIDs: [id(5), id(6)], state: "closed"),
      ],
      knots: [
        K(
          id: "k1", strand: "s1", kind: "progress", text: "电机修好", date: "2026-09-03",
          state: "done", who: ["周明", "我"], evidence: [id(2), id(3)],
          quote: "电机修好了", quoteItemID: id(3)),
        K(
          id: "k2", strand: "s2", kind: "decision", text: "只演示叠衣服", date: "2026-09-05",
          state: "done", evidence: [id(5)]),
        K(
          id: "k3", strand: nil, kind: "question", text: "为什么掉线", state: "open",
          evidence: [id(9)], segmentRefs: [.init(itemID: id(9), segID: "p2")]),
        K(
          id: "k4", strand: "s1", kind: "commitment", text: "跑 baseline", date: "2026-09-14",
          state: "planned", who: ["林知远"], evidence: [id(12)]),
        K(
          id: "k5", strand: "s1", kind: "progress", text: "同一天的第二个结", date: "2026-09-03",
          state: "doing", evidence: [id(4)]),
      ],
      health: .init(level: "risk", reason: "集群还没修好", evidence: [id(11)]))
  }

  private func projection(
    map: RemoteOrganizerMatterMap?, facts: [MemoryStatusFact] = [],
    ropes: [RemoteOrganizerRope] = [], relations: [RemoteOrganizerRelation] = []
  ) -> MemoryProjection {
    let events = [
      MemoryEventSource(
        eventID: "ev-a", origin: .spark, title: "真机实验", statusLine: "数据已定", pinned: false,
        updatedAt: nil, itemIDs: (1...12).map(id), personIDs: [], statusFacts: facts,
        segments: [
          MemoryItemSegment(itemID: id(9), segID: "p1", start: 0, end: 4, gist: "前半"),
          MemoryItemSegment(itemID: id(9), segID: "p2", start: 4, end: 9, gist: "后半"),
        ],
        map: map, facets: nil, listedFacts: facts),
      MemoryEventSource(
        eventID: "ev-b", origin: .spark, title: "集群维护", statusLine: "", pinned: false,
        updatedAt: nil, itemIDs: [id(11)], personIDs: []),
      MemoryEventSource(
        eventID: "ev-c", origin: .spark, title: "开放日", statusLine: "", pinned: false,
        updatedAt: nil, itemIDs: [id(6)], personIDs: []),
    ]
    return MemoryProjection(
      events: events, records: records, now: date(9, 12, 20), ropes: ropes, relations: relations)
  }

  private var now: Date { date(9, 12, 20) }

  // MARK: - The model

  func testTheModelFollowsTheMap() throws {
    let model = try XCTUnwrap(
      MemoryStrandModel(
        projection: projection(map: map), eventID: "ev-a", now: now, calendar: calendar))
    XCTAssertTrue(model.hasMap)
    XCTAssertEqual(model.itemCount, 12)
    XCTAssertEqual(model.strands.map(\.itemCount), [4, 2])
    XCTAssertEqual(model.mainItemCount, 6)
    XCTAssertEqual(model.strands.map(\.closed), [false, true])
    // The axis starts three days before the first item and ends four days
    // after the last planned knot.
    XCTAssertEqual(model.day(of: date(9, 1), calendar: calendar), 3)
    XCTAssertEqual(model.today, 3 + 11)
    XCTAssertEqual(model.totalDays, 3 + 13 + 4 + 1)
    XCTAssertEqual(model.strands[0].firstDay, 3)
    XCTAssertEqual(model.strands[0].lastDay, 3 + 3)
    XCTAssertEqual(model.strands[1].firstDay, 3 + 4)
    XCTAssertEqual(model.strands[1].lastDay, 3 + 5)
    // Knots: glyphs, days, who (the Mac's user left out), strands.
    let k1 = try XCTUnwrap(model.knot("k1"))
    XCTAssertEqual(k1.glyph, .done)
    XCTAssertEqual(k1.day, 3 + 2)
    XCTAssertEqual(k1.who.map(\.name), ["周明"])
    XCTAssertEqual(k1.strand, 0)
    XCTAssertEqual(model.knot("k2")?.glyph, .decision)
    XCTAssertEqual(model.knot("k4")?.glyph, .planned)
    XCTAssertEqual(model.knot("k5")?.glyph, .doing)
    // The quote's item comes first and shows the quote; the other its words.
    XCTAssertEqual(k1.evidence.map(\.holdsQuote), [true, false])
    XCTAssertEqual(k1.evidence.first?.snippet, "电机修好了")
    XCTAssertEqual(k1.evidence.first?.rowID, id(3))
    // A question with no date sits on its evidence's day, on the main
    // thread, and opens the part it cites.
    let question = try XCTUnwrap(model.knot("k3"))
    XCTAssertEqual(question.glyph, .question)
    XCTAssertNil(question.strand)
    XCTAssertTrue(question.dateIsInferred)
    XCTAssertEqual(question.day, 3 + 8)
    XCTAssertEqual(question.evidence.first?.rowID, "\(id(9))#p2")
    XCTAssertEqual(model.mainKnots.map(\.id), ["k3"])
    XCTAssertEqual(model.health?.level, .risk)
    XCTAssertEqual(model.health?.evidence.map(\.itemID), [id(11)])
    // The same inputs give the same model.
    XCTAssertEqual(
      model,
      MemoryStrandModel(
        projection: projection(map: map), eventID: "ev-a", now: now, calendar: calendar))
  }

  func testWithoutAMapTheFactsAreOnOneThread() throws {
    let facts = [
      MemoryStatusFact(
        text: "周五交报告", state: .planned, day: DateComponents(year: 2026, month: 9, day: 18)),
      MemoryStatusFact(text: "电机修好", state: .done, itemIDs: [id(3)]),
      MemoryStatusFact(text: "预算不够", state: .info),
    ]
    let model = try XCTUnwrap(
      MemoryStrandModel(
        projection: projection(map: nil, facts: facts), eventID: "ev-a", now: now,
        calendar: calendar))
    XCTAssertFalse(model.hasMap)
    XCTAssertTrue(model.strands.isEmpty)
    XCTAssertEqual(model.mainItemCount, 12)
    XCTAssertEqual(model.mainKnots.map(\.glyph), [.done, .planned])
    XCTAssertEqual(model.mainKnots.first?.day, model.day(of: date(9, 3), calendar: calendar))
    XCTAssertEqual(model.mainKnots.last?.day, model.today + 6)
    XCTAssertTrue(model.totalDays > model.today + 6)
  }

  func testTheStatusBar() throws {
    let relations = [
      RemoteOrganizerRelation(kind: "blocks", a: "ev-b", b: "ev-a", quote: "等集群修好"),
      RemoteOrganizerRelation(kind: "blocks", a: "ev-a", b: "ev-c", quote: "等实验做完"),
      RemoteOrganizerRelation(kind: "cross", a: "ev-a", b: "ev-c", count: 3),
    ]
    let projection = projection(map: map, relations: relations)
    let model = try XCTUnwrap(
      MemoryStrandModel(projection: projection, eventID: "ev-a", now: now, calendar: calendar))
    let status = MemoryMatterStatus(
      model: model, statusLine: "数据已定", facts: [], projection: projection, calendar: calendar)
    XCTAssertEqual(status.flag?.text, "跑 baseline")
    XCTAssertEqual(status.flag?.daysAway, 2)
    XCTAssertEqual(status.commitments.map(\.knotID), ["k4"])
    XCTAssertEqual(status.questions.map(\.id), ["k3"])
    // A passed step is the flag only when nothing is ahead.
    let passed = MemoryMatterStatus(
      model: model, statusLine: "",
      facts: [
        MemoryStatusFact(
          text: "交初稿", state: .planned, day: DateComponents(year: 2026, month: 9, day: 10))
      ], projection: projection, calendar: calendar)
    XCTAssertEqual(passed.flag?.daysAway, 2)
    let onlyPassed = try XCTUnwrap(
      MemoryStrandModel(
        projection: self.projection(map: nil, facts: []), eventID: "ev-a", now: now,
        calendar: calendar))
    let late = MemoryMatterStatus(
      model: onlyPassed, statusLine: "",
      facts: [
        MemoryStatusFact(
          text: "交初稿", state: .planned, day: DateComponents(year: 2026, month: 9, day: 10))
      ], projection: projection, calendar: calendar)
    XCTAssertEqual(late.flag?.daysAway, -2)
  }

  func testRopesAsShown() {
    let ropes = [
      RemoteOrganizerRope(id: "top", title: "科研", children: ["ev-a", "gone"]),
      RemoteOrganizerRope(id: "inner", title: "论文", parent: "top", children: ["ev-b"]),
      RemoteOrganizerRope(id: "empty", title: "空绳", children: ["gone"]),
      RemoteOrganizerRope(id: "loop1", title: "一", parent: "loop2", children: ["ev-c"]),
      RemoteOrganizerRope(id: "loop2", title: "二", parent: "loop1", children: ["ev-a"]),
      RemoteOrganizerRope(id: "orphan", title: "孤", parent: "missing", children: []),
    ]
    let shown = projection(map: nil, ropes: ropes).ropes
    XCTAssertEqual(shown.map(\.id), ["top", "inner", "loop1"])
    XCTAssertEqual(shown[0].children, ["ev-a"], "unknown matters are left out")
    XCTAssertEqual(shown[1].parent, "top")
    XCTAssertNil(shown[2].parent, "a loop is broken at the top")
    // A matter is on one rope: ev-a stays on the first that lists it.
    XCTAssertFalse(shown.contains { $0.id == "loop2" })
  }

  func testAQuoteInsideItsText() {
    let excerpt = MemoryQuoteExcerpt.excerpt(
      of: "电机修好了", in: "周明：电机修好了，明天恢复实验\n我：好", context: 4)
    XCTAssertEqual(excerpt?.quote, "电机修好了")
    XCTAssertEqual(excerpt?.before, "周明：")
    XCTAssertEqual(excerpt?.after, "，明天恢…")
    XCTAssertNil(MemoryQuoteExcerpt.excerpt(of: "不在里面", in: "周明：电机修好了"))
  }
}
