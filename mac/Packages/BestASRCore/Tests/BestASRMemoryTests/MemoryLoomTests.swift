import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

/// Home's 「最近在动的事」: which matters get a lane, how a busy day becomes
/// one knot and the ribbon's thickness, how one meeting filed into several
/// matters becomes a weft, milestones, flags in the 「接下来」 zone, and the
/// header's counts. Synthetic data only.
final class MemoryLoomTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  private func id(_ n: Int) -> String {
    String(format: "D0000000-0000-4000-8000-%012d", n)
  }

  private func record(
    _ n: Int, at: Date, mode: SessionInputMode = .userItem, kind: UserItemKind? = .text,
    app: String? = "微信", bundle: String? = "com.tencent.xinWeChat", text: String = "周经理：好的"
  ) -> MemoryItemRecord {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: id(n))!), inputMode: mode,
      itemKind: mode == .userItem ? kind : nil, title: "记录", startedAt: at, updatedAt: at,
      sourceBundleID: bundle, sourceDisplayName: app, sourceIdentifier: nil, text: text)
  }

  private func event(
    _ name: String, _ items: [Int], facts: [MemoryStatusFact] = [],
    segments: [MemoryItemSegment] = []
  ) -> MemoryEventSource {
    MemoryEventSource(
      eventID: name, origin: .spark, title: "事 \(name)", statusLine: "\(name) 进行中",
      pinned: false, updatedAt: nil, itemIDs: items.map(id), personIDs: [],
      statusFacts: facts, segments: segments)
  }

  private func loom(
    _ events: [MemoryEventSource], _ records: [MemoryItemRecord],
    span: MemoryLoom.Span = .twoWeeks
  ) -> MemoryLoom {
    let projection = MemoryProjection(events: events, records: records, now: date(9, 30))
    return MemoryReadModel(projection, calendar: calendar).looms[span]!
  }

  // MARK: - Lanes

  func testLanesFollowHomeOrderSkipQuietMattersAndStopAtFive() {
    var records: [MemoryItemRecord] = []
    var events: [MemoryEventSource] = []
    // ev-0 … ev-7 in Home order; ev-2 last moved 20 days before the newest item.
    for e in 0..<8 {
      let day = e == 2 ? date(9, 8) : date(9, 20 + e % 8)
      records.append(record(e, at: day))
      events.append(event("ev-\(e)", [e]))
    }
    let two = loom(events, records)
    XCTAssertEqual(two.lanes.map(\.eventID), ["ev-0", "ev-1", "ev-3", "ev-4", "ev-5"])
    XCTAssertTrue(two.isShown)
    // Every matter that moved counts, on the axis or not.
    XCTAssertEqual(two.movedCount, 7)
    // Five weeks reach back to ev-2.
    let five = loom(events, records, span: .fiveWeeks)
    XCTAssertEqual(five.lanes.map(\.eventID), ["ev-0", "ev-1", "ev-2", "ev-3", "ev-4"])
    XCTAssertEqual(five.movedCount, 8)
  }

  /// "Now" is the newest item, so a replayed library draws as it did then.
  func testNowIsTheNewestItemAndTodayIsTheLastPastDay() {
    let records = [record(1, at: date(9, 20)), record(2, at: date(9, 27, 18))]
    let result = loom([event("a", [1]), event("b", [2])], records)
    XCTAssertEqual(result.now, date(9, 27, 18))
    XCTAssertEqual(result.start, date(9, 14, 0))
    XCTAssertEqual(result.todayIndex, 13)
    XCTAssertEqual(result.totalDays, 21)
    XCTAssertEqual(result.lanes[1].knots.map(\.day), [13])
    XCTAssertEqual(result.lanes[0].knots.map(\.day), [6])
  }

  /// A record no event or Unfiled holds (a Home cut off at an earlier day
  /// is given every record) does not move "now".
  func testARecordThePagesDoNotShowDoesNotMoveNow() {
    let records = [
      record(1, at: date(9, 20)), record(2, at: date(9, 22)), record(3, at: date(9, 29)),
    ]
    let result = loom([event("a", [1]), event("b", [2])], records)
    XCTAssertEqual(result.now, date(9, 22))
  }

  // MARK: - Knots

  func testABusyDayIsOneKnotWithItsCountAndItsMostFrequentShape() {
    let records = [
      record(1, at: date(9, 25, 9)),
      record(2, at: date(9, 25, 11), mode: .dictation, app: nil, bundle: nil),
      record(3, at: date(9, 25, 15)),
      record(4, at: date(9, 27, 9), kind: .image, text: ""),
      record(9, at: date(9, 27, 10)),
    ]
    let result = loom([event("a", [1, 2, 3, 4]), event("b", [9])], records)
    let knots = result.lanes[0].knots
    XCTAssertEqual(knots.count, 2)
    XCTAssertEqual(knots[0].count, 3)
    XCTAssertEqual(knots[0].kind, .chat)
    XCTAssertEqual(knots[0].itemIDs, [id(1), id(2), id(3)])
    XCTAssertEqual(knots[0].time, date(9, 25, 9))
    XCTAssertEqual(knots[1].kind, .image)
    XCTAssertEqual(result.lanes[0].itemCount, 4)
    XCTAssertEqual(result.lanes[0].firstDay, knots[0].day)
    XCTAssertEqual(result.lanes[0].lastDay, knots[1].day)
  }

  func testEachSourceHasItsOwnShape() {
    let transcript = "周会\n\n苗青禾(00:00:03):\n先说展会。\n\n欧阳帆(00:00:40):\n好的。"
    let cases: [(MemoryItemRecord, MemoryLoom.KnotKind)] = [
      (record(1, at: date(9, 20), mode: .roomMicrophone, app: nil, bundle: nil), .meeting),
      (record(2, at: date(9, 20), mode: .dictation, app: nil, bundle: nil), .dictation),
      (record(3, at: date(9, 20), kind: .image, app: "iPhone", bundle: nil, text: ""), .phone),
      (record(4, at: date(9, 20), kind: .image, text: ""), .image),
      (record(5, at: date(9, 20), kind: .file, text: ""), .file),
      (record(6, at: date(9, 20), kind: .document, text: "合同正文"), .file),
      (record(7, at: date(9, 20), kind: .document, text: transcript), .meeting),
      (record(8, at: date(9, 20)), .chat),
    ]
    for (index, (item, kind)) in cases.enumerated() {
      let other = record(100, at: date(9, 21))
      let result = loom([event("x", [index + 1]), event("y", [100])], [item, other])
      XCTAssertEqual(result.lanes.first?.knots.first?.kind, kind, "case \(index)")
    }
  }

  // MARK: - Wefts

  func testAMeetingFiledInPartsIsAWeftAcrossItsLanes() {
    let meeting = 50
    let parts = ["a", "c"].enumerated().map { index, name in
      MemoryItemSegment(
        itemID: id(meeting), segID: "s\(index)", start: index * 10, end: index * 10 + 10,
        gist: "\(name) 的部分")
    }
    let records = [
      record(meeting, at: date(9, 24, 14), mode: .systemAudio, app: "腾讯会议", bundle: nil),
      record(1, at: date(9, 24, 18)), record(2, at: date(9, 24, 19)),
      record(3, at: date(9, 22)), record(4, at: date(9, 23)),
    ]
    let events = [
      event("a", [1, 2, meeting], segments: [parts[0]]),
      event("b", [3]),
      event("c", [meeting, 4], segments: [parts[1]]),
    ]
    let result = loom(events, records)
    XCTAssertEqual(result.wefts.count, 1)
    let weft = result.wefts[0]
    XCTAssertEqual(weft.itemID, id(meeting))
    XCTAssertEqual(weft.lanes, [0, 2])
    XCTAssertEqual(weft.kind, .meeting)
    XCTAssertEqual(weft.time, date(9, 24, 14))
    // The day it happened takes the meeting's shape though chats outnumber it,
    // and the knot tells the part this matter holds.
    let knot = result.lanes[0].knots.first { $0.day == weft.day }!
    XCTAssertEqual(knot.kind, .meeting)
    XCTAssertEqual(knot.count, 3)
    XCTAssertEqual(knot.snippet, "a 的部分")
    XCTAssertEqual(result.lanes[2].knots.first { $0.day == weft.day }?.kind, .meeting)
    // The hover card lists the day's items; a click opens their rows on the
    // event page (the part this matter holds, for the meeting).
    XCTAssertEqual(knot.items.map(\.rowID), [id(meeting) + "#s0", id(1), id(2)])
    XCTAssertEqual(knot.items.map(\.snippet).first, "a 的部分")
    XCTAssertTrue(result.lanes[1].knots.allSatisfy { $0.day != weft.day })
  }

  func testAnItemInOneShownMatterIsNoWeft() {
    let records = [record(1, at: date(9, 24)), record(2, at: date(9, 25))]
    let result = loom([event("a", [1]), event("b", [2])], records)
    XCTAssertTrue(result.wefts.isEmpty)
  }

  // MARK: - 接下来

  func testTheNextDatedStepIsAHollowKnotInTheFutureZone() {
    let records = [record(1, at: date(9, 27, 9)), record(2, at: date(9, 26))]
    let soon = MemoryStatusFact(
      text: "交初稿", state: .planned, day: DateComponents(year: 2026, month: 9, day: 29))
    let later = MemoryStatusFact(
      text: "发布会", state: .planned, day: DateComponents(year: 2026, month: 10, day: 20))
    let past = MemoryStatusFact(
      text: "开会", state: .planned, day: DateComponents(year: 2026, month: 9, day: 20))
    let done = MemoryStatusFact(
      text: "已交", state: .done, day: DateComponents(year: 2026, month: 9, day: 28))
    let result = loom(
      [event("a", [1], facts: [past, done, later, soon]), event("b", [2], facts: [later])],
      records)
    let next = result.lanes[0].next!
    XCTAssertEqual(next.text, "交初稿")
    XCTAssertEqual(next.daysAway, 2)
    XCTAssertEqual(next.day, result.todayIndex + 2)
    XCTAssertGreaterThanOrEqual(next.day!, result.days)
    XCTAssertLessThan(next.day!, result.totalDays)
    // Beyond the zone: a chip, no knot.
    let far = result.lanes[1].next!
    XCTAssertEqual(far.daysAway, 23)
    XCTAssertNil(far.day)
  }

  // MARK: - Ribbon, milestones, flags

  private func fact(
    _ text: String, _ state: MemoryStatusFact.State, _ month: Int, _ day: Int,
    items: [Int] = []
  ) -> MemoryStatusFact {
    MemoryStatusFact(
      text: text, state: state, day: DateComponents(year: 2026, month: month, day: day),
      itemIDs: items.map(id))
  }

  /// The ribbon is √items per day, smoothed over neighbours, and only
  /// between the lane's first and last day.
  func testTheRibbonIsTheSmoothedSquareRootOfEachDay() {
    let records =
      (1...4).map { record($0, at: date(9, 16, 8 + $0)) }
      + [record(5, at: date(9, 17)), record(6, at: date(9, 19)), record(9, at: date(9, 27))]
    let result = loom([event("a", [1, 2, 3, 4, 5, 6]), event("b", [9])], records)
    let band = result.lanes[0].band
    XCTAssertEqual(band.count, result.totalDays)
    XCTAssertEqual(band[1], 0)
    XCTAssertEqual(band[2], 2.5 / 1.5, accuracy: 1e-9)
    XCTAssertEqual(band[3], 1.0, accuracy: 1e-9)
    XCTAssertEqual(band[4], 0.5, accuracy: 1e-9)
    XCTAssertEqual(band[5], 1 / 1.5, accuracy: 1e-9)
    XCTAssertEqual(band[6], 0)
    XCTAssertTrue(band[result.todayIndex...].allSatisfy { $0 == 0 })
  }

  /// Milestones: dated done / cancelled facts up to today and under-way ones
  /// before it, the latest three, each a few words without its date.
  func testMilestonesAreTheLatestThreeDatedFactsInFewWords() {
    let records = [
      record(1, at: date(9, 16)), record(2, at: date(9, 20)), record(3, at: date(9, 27, 9)),
      record(9, at: date(9, 26)),
    ]
    let facts = [
      fact("二面反馈已收到，等结果", .done, 9, 16, items: [1]),
      fact("审稿意见到", .done, 9, 15),
      fact("9月18日 Offer已发，4月6日入职", .done, 9, 18),
      fact("材料定稿", .inProgress, 9, 25),
      // Under way today: a flag, not a milestone.
      fact("正在改条款", .inProgress, 9, 27),
      fact("太早的事", .done, 9, 1),
      fact("交初稿", .planned, 9, 20),
      MemoryStatusFact(text: "没有日期", state: .done),
      fact("取消了面谈", .cancelled, 9, 20),
    ]
    let result = loom([event("a", [1, 2, 3], facts: facts), event("b", [9])], records)
    let milestones = result.lanes[0].milestones
    XCTAssertEqual(milestones.map(\.label), ["Offer已发", "取消了面谈", "材料定稿"])
    XCTAssertEqual(milestones.map(\.day), [4, 6, 11])
    XCTAssertEqual(milestones.map(\.state), [.done, .cancelled, .inProgress])
    // A milestone opens its own items, else that day's.
    XCTAssertEqual(milestones[1].rowIDs, [id(2)])
    XCTAssertEqual(milestones[0].rowIDs, [])
    let earlier = loom(
      [event("a", [1, 2, 3], facts: Array(facts.prefix(2))), event("b", [9])], records)
    XCTAssertEqual(earlier.lanes[0].milestones.map(\.label), ["审稿意见到", "二面反馈已收到"])
    XCTAssertEqual(earlier.lanes[0].milestones.last?.rowIDs, [id(1)])
    // No dated facts: no milestones.
    XCTAssertTrue(result.lanes[1].milestones.isEmpty)
  }

  /// Flags: planned or under-way facts dated today to a week ahead, the
  /// soonest three, with how urgent each is.
  func testFlagsAreDatedStepsInTheNextWeekWithTheirUrgency() {
    let records = [record(1, at: date(9, 27, 9)), record(2, at: date(9, 26))]
    let a = [
      fact("中期汇报", .inProgress, 9, 30),
      fact("9月28日前需回复确认接受Offer", .planned, 9, 28),
      fact("改完条款再签", .planned, 9, 27),
      fact("签约", .planned, 10, 3),
      fact("太远", .planned, 10, 5),
      fact("过去的", .planned, 9, 20),
      fact("已交", .done, 9, 29),
    ]
    let b = [fact("10月3日签约", .planned, 10, 3), fact("签约", .planned, 10, 3)]
    let result = loom([event("a", [1], facts: a), event("b", [2], facts: b)], records)
    let flags = result.lanes[0].flags
    XCTAssertEqual(flags.map(\.text), ["改完条款再签", "需回复确认接受Offer", "中期汇报"])
    XCTAssertEqual(flags.map(\.daysAway), [0, 1, 3])
    XCTAssertEqual(flags.map(\.day), [13, 14, 16])
    XCTAssertEqual(flags.map(\.urgency), [.urgent, .urgent, .soon])
    // One flag per day and text.
    XCTAssertEqual(result.lanes[1].flags.map(\.text), ["签约"])
    XCTAssertEqual(result.lanes[1].flags.first?.urgency, .later)
    XCTAssertEqual(result.lanes[1].flags.first?.day, result.totalDays - 2)
    XCTAssertEqual(
      [0, 1, 2, 4, 5, 7].map { MemoryLoom.Urgency(daysAway: $0) },
      [.urgent, .urgent, .soon, .soon, .later, .later])
  }

  /// The header's counts cover every Home matter, not only the lanes.
  func testDueCountsAndLastActivityCoverEveryHomeMatter() {
    let records = [
      record(1, at: date(9, 27, 9)), record(2, at: date(9, 26)), record(3, at: date(9, 25)),
      record(4, at: date(9, 1)),
    ]
    let events = [
      event("a", [1], facts: [fact("交材料", .planned, 9, 27)]),
      event("b", [2], facts: [fact("交回复信", .planned, 9, 28)]),
      event("c", [3]),
      event("d", [4], facts: [fact("续签", .inProgress, 9, 28), fact("旧的", .planned, 9, 2)]),
    ]
    let result = loom(events, records)
    XCTAssertEqual(result.dueToday, 1)
    XCTAssertEqual(result.dueTomorrow, 2)
    XCTAssertEqual(result.movedCount, 3)
    XCTAssertEqual(result.dues["d"]?.daysAway, 1)
    XCTAssertNil(result.dues["c"])
    XCTAssertEqual(result.lastActivity["d"], date(9, 1))
    XCTAssertEqual(result.lastActivity["a"], date(9, 27, 9))
    XCTAssertEqual(result.lanes.map(\.eventID), ["a", "b", "c"])
  }

  func testALabelIsTheFirstClauseWithoutDatesCutToItsWidth() {
    XCTAssertEqual(MemoryLoom.label("9月21日前需回复确认接受Offer", width: 10), "需回复确认接受Offer")
    XCTAssertEqual(MemoryLoom.label("4600元成交，9月26日签约", width: 8), "4600元成交")
    XCTAssertEqual(MemoryLoom.label("材料今天交，22日汇报", width: 8), "材料交")
    XCTAssertEqual(MemoryLoom.label("周三前交材料", width: 8), "交材料")
    XCTAssertEqual(MemoryLoom.label("2026-09-26 签约", width: 8), "签约")
    XCTAssertEqual(MemoryLoom.label("26日签约", width: 8), "签约")
    XCTAssertEqual(MemoryLoom.label("R2 已完成，还差回复信", width: 8), "R2 已完成")
    XCTAssertEqual(MemoryLoom.label("一二三四五六七八九十", width: 8), "一二三四五六七…")
    XCTAssertEqual(MemoryLoom.label("9月20日，材料交了", width: 8), "材料交了")
    XCTAssertEqual(MemoryLoom.label("", width: 8), "")
    XCTAssertEqual(MemoryLoom.label("9月20日", width: 8), "")
    XCTAssertEqual(MemoryLoom.label("周二 9:30 B超，姐姐陪", width: 10), "9:30 B超")
  }

  // MARK: - Empty

  func testFewerThanTwoMovingMattersHideThePanel() {
    XCTAssertFalse(loom([], []).isShown)
    XCTAssertTrue(loom([], []).lanes.isEmpty)
    let one = loom([event("a", [1])], [record(1, at: date(9, 25))])
    XCTAssertEqual(one.lanes.count, 1)
    XCTAssertFalse(one.isShown)
    // A matter whose items are all older than the window is no lane.
    let old = loom(
      [event("a", [1]), event("b", [2])], [record(1, at: date(9, 25)), record(2, at: date(8, 1))])
    XCTAssertFalse(old.isShown)
  }

  func testTheStatusIsCutToOneShortLine() {
    let long = MemoryEventSource(
      eventID: "a", origin: .spark, title: "长", statusLine: "一二三四五六七八九十一二三四五六七八九十\n第二行",
      pinned: false, updatedAt: nil, itemIDs: [id(1)], personIDs: [])
    let result = loom(
      [long, event("b", [2])], [record(1, at: date(9, 25)), record(2, at: date(9, 26))])
    XCTAssertEqual(result.lanes[0].status.count, MemoryLoom.statusLength)
    XCTAssertTrue(result.lanes[0].status.hasSuffix("…"))
  }

  // MARK: - Scale

  /// 200 matters and 2,000 items: derived quickly, off the main thread in
  /// the App.
  func testTwoHundredMattersAndTwoThousandItemsStayFast() {
    var records: [MemoryItemRecord] = []
    var events: [MemoryEventSource] = []
    for e in 0..<200 {
      var items: [Int] = []
      for k in 0..<10 {
        let n = e * 10 + k
        records.append(record(n, at: date(9, 1).addingTimeInterval(Double(n) * 1_300)))
        items.append(n)
      }
      events.append(event("ev-\(e)", items))
    }
    let projection = MemoryProjection(events: events, records: records, now: date(9, 30))
    let started = Date()
    let spans = MemoryLoom.Span.allCases.map {
      MemoryLoom(projection: projection, home: projection.home(), span: $0, calendar: calendar)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    XCTAssertEqual(spans.map(\.lanes.count), [5, 5])
  }
}
