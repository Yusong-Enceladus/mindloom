import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

/// v11 derivations (MAC-SPEC §13): display guards, status-line steps, step
/// glyphs, due / overdue, risk, 待定, overrides, the same capture's other
/// matters, 按截止's rows, and corrections laid over the projection.
/// Synthetic data only.
final class MemoryDigestTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
  }()

  private func date(_ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  /// 2026-09-20 22:46, a Sunday (the prototype's "now").
  private var now: Date { date(9, 20, 22, 46) }

  private func id(_ n: Int) -> String { String(format: "E0000000-0000-4000-8000-%012d", n) }

  private func record(_ n: Int, at: Date, text: String, app: String = "微信") -> MemoryItemRecord {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: id(n))!), inputMode: .userItem, itemKind: .text,
      title: "", startedAt: at, updatedAt: at, sourceBundleID: nil, sourceDisplayName: app,
      sourceIdentifier: nil, text: text)
  }

  // MARK: - Display guards

  func testDisplayGuards() {
    XCTAssertEqual(MemoryDisplayText.normalizedDates("9/21交回复信，16/20 分"), "9月21日交回复信，16/20 分")
    XCTAssertEqual(MemoryDisplayText.normalizedDates("2026/9/21 不变"), "2026/9/21 不变")
    let owners = ["林知远", "知远"]
    XCTAssertEqual(
      MemoryDisplayText.withoutOwner("林知远答应周五发给王律师", ownerNames: owners), "周五发给王律师")
    XCTAssertEqual(MemoryDisplayText.withoutOwner("用户需要确认报价", ownerNames: owners), "确认报价")
    XCTAssertEqual(MemoryDisplayText.withoutOwner("让林知远一人负责", ownerNames: owners), "让你一人负责")
    XCTAssertEqual(
      MemoryDisplayText.clean(
        "明天9月21日前交回复信的截止日期", date: DateComponents(year: 2026, month: 9, day: 21),
        inferred: false),
      "交回复信")
    XCTAssertEqual(
      MemoryDisplayText.stepLabel(
        "你完成R2理论部分重写", kind: "progress", state: "done", date: nil, inferred: true,
        ownerNames: owners), "完成R2理论部分重写")
    XCTAssertEqual(
      MemoryDisplayText.stepLabel(
        "下周表2数据是否需要重新跑", kind: "question", state: "open", date: nil, inferred: true,
        ownerNames: owners), "表2数据是否需要重新跑？")
    XCTAssertEqual(MemoryDisplayText.status("待你确认报价，9/26签约", ownerNames: []), "确认报价，9月26日签约")
    XCTAssertEqual(MemoryDisplayText.name("实验调参与", ownerNames: []), "实验调参")
  }

  func testRiskDropsClausesWhoseDatesTheStatusHas() {
    XCTAssertEqual(
      MemoryDisplayText.risk(
        reason: "内部目标9/21那周完成回复信，目前仅完成四成，表2数据待核对",
        status: "R2已完成，9月21日交回复信", ownerNames: []),
      "目前仅完成四成，表2数据待核对")
    XCTAssertEqual(
      MemoryDisplayText.risk(reason: "9月21日截止", status: "9月21日截止", ownerNames: []), "9月21日截止")
    XCTAssertNil(MemoryDisplayText.risk(reason: " ", status: "", ownerNames: []))
  }

  func testStatusLineSteps() {
    let today = DateComponents(year: 2026, month: 9, day: 20)
    let steps = MemoryDisplayText.statusSteps(
      "R2已完成，9月21日交回复信，9月15日投稿，8月1日提交", today: today, calendar: calendar)
    // A next-step verb in the past is returned (the digest keeps it only
    // when it is a deadline that passed within the week).
    XCTAssertEqual(steps.map(\.verb), ["交回复信", "提交", "投稿"])
    XCTAssertEqual(steps.first?.date, DateComponents(year: 2026, month: 9, day: 21))
    // A date more than two months back belongs to next year.
    let next = MemoryDisplayText.statusSteps("6月3日答辩", today: today, calendar: calendar)
    XCTAssertEqual(next.first?.date.year, 2027)
    XCTAssertEqual(MemoryDisplayText.statusSteps("9月31日交", today: today, calendar: calendar), [])
    // fix-mac: 「9月18日前确认」 is a limit, overdue once the day has passed
    // although 确认 is no deadline verb.
    let limit = MemoryDisplayText.statusSteps("9月18日前确认入职时间", today: today, calendar: calendar)
    XCTAssertEqual(limit.map(\.byDate), [true])
    XCTAssertEqual(limit.first?.date, DateComponents(year: 2026, month: 9, day: 18))
    XCTAssertEqual(
      MemoryDisplayText.statusSteps("9月18日确认入职时间", today: today, calendar: calendar).map(\.byDate),
      [false])
  }

  func testBigramsLeaveOutDatesAndGenericWords() {
    XCTAssertEqual(MemoryDisplayText.bigrams("9月21日交回复信的截止"), ["交回", "回复", "复信"])
    XCTAssertTrue(MemoryDisplayText.bigrams("截止").isEmpty)
  }

  // MARK: - The digest

  /// E6-like: a map with three parts and five knots, a status-line step due
  /// tomorrow, a risk; another matter holds one of its items.
  private func projection() -> MemoryProjection {
    typealias K = RemoteOrganizerMatterMap.Knot
    let records = [
      record(1, at: date(8, 18), text: "周明澜：先把 R1 的实验补上\n我：好"),
      record(2, at: date(9, 11), text: "我：表2数据是否需要重新跑\n宋雨桐：我看看"),
      record(3, at: date(9, 18, 17, 34), text: "韩策：R2 那个老哥改分了，直接 5 了\n我：太好了", app: "腾讯会议"),
      record(4, at: date(9, 18, 9), text: "[09-18 09:00] Ann Gu：理论部分写好了", app: "企业微信"),
      record(5, at: date(9, 20, 21), text: "我：明天把回复信交了，9月21日交回复信", app: "Fn 口述"),
    ]
    let map = RemoteOrganizerMatterMap(
      strands: [
        .init(id: "s1", name: "R1 补实验与仿真", summary: "仅跑仿真", itemIDs: [id(1)], state: "closed"),
        .init(id: "s2", name: "R2 理论推导", itemIDs: [id(3), id(4)]),
        .init(id: "s3", name: "R3 写作与回复信", itemIDs: [id(5)]),
      ],
      knots: [
        K(
          id: "k5", strand: "s3", kind: "question", text: "下周表2数据是否需要重新跑以验证稳定性",
          state: "open", evidence: [id(2)], quote: "表2数据是否需要重新跑", quoteItemID: id(2)),
        K(
          id: "k6", strand: "s2", kind: "progress", text: "顾安完成R2理论部分重写", date: "2026-09-18",
          state: "done", who: ["Ann Gu"], evidence: [id(4)], quote: "理论部分写好了", quoteItemID: id(4)),
        K(
          id: "k7", strand: "s2", kind: "progress", text: "审稿人R2改分为5", date: "2026-09-18",
          state: "done", who: ["韩策"], evidence: [id(3)], quote: "R2 那个老哥改分了",
          quoteItemID: id(3)),
        K(
          id: "k9", strand: "s1", kind: "deadline", text: "TES期刊正式截止", date: "2026-10-16",
          state: "planned", evidence: [id(1)]),
        K(
          id: "k10", strand: "s1", kind: "commitment", text: "林知远发周明澜数据", date: "2026-09-12",
          state: "planned", who: [], evidence: [id(1)]),
      ],
      health: .init(level: "risk", reason: "内部目标9/21那周完成回复信，目前仅完成四成，表2数据待核对", evidence: []))
    let events = [
      MemoryEventSource(
        eventID: "E6", origin: .spark, title: "TES论文RoboPrior大修返修",
        statusLine: "R2已完成，9月21日交回复信", pinned: false, updatedAt: now,
        itemIDs: (1...5).map(id), personIDs: [], handle: "E6", map: map),
      MemoryEventSource(
        eventID: "E45", origin: .spark, title: "博士中期考核", statusLine: "9月30日交报告",
        pinned: false, updatedAt: now, itemIDs: [id(3)], personIDs: [], handle: "E45"),
    ]
    // swift-format-ignore: NeverUseForceTry
    let persons = try! JSONDecoder().decode(
      [RemoteOrganizerPerson].self,
      from: Data(#"[{"person_id": "p-gu", "display_name": "顾安", "aliases": ["Ann Gu"]}]"#.utf8))
    return MemoryProjection(events: events, records: records, persons: persons, now: now)
  }

  func testTheMatterDigest() throws {
    let digest = MemoryDigest(
      projection: projection(), now: now, calendar: calendar, ownerNames: ["林知远"])
    let e6 = try XCTUnwrap(digest.matter("E6"))
    XCTAssertEqual(e6.title, "TES论文RoboPrior大修返修")
    XCTAssertEqual(e6.risk, "目前仅完成四成，表2数据待核对")
    // Open parts first, each by its first day; the closed part last.
    XCTAssertEqual(e6.parts.map(\.id), ["s2", "s3", "s1"])
    XCTAssertEqual(e6.parts.last?.closed, true)
    // The status line's dated step, due tomorrow, on the part that shares
    // its words.
    let st1 = try XCTUnwrap(e6.step("st1"))
    XCTAssertEqual(st1.text, "交回复信")
    XCTAssertEqual(st1.partID, "s3")
    XCTAssertTrue(st1.due)
    XCTAssertTrue(st1.fromStatus)
    XCTAssertEqual(st1.evidence?.itemID, id(5).uppercased(), "the dictation says that date")
    XCTAssertEqual(e6.due(today: digest.today, calendar: calendar)?.id, "st1")
    // 待定: the open question, its relative word dropped.
    XCTAssertEqual(e6.openQuestions.map(\.text), ["表2数据是否需要重新跑以验证稳定性？"])
    // A done step: who by name (alias → 顾安), evidence with its quote line.
    let k6 = try XCTUnwrap(e6.step("k6"))
    XCTAssertEqual(k6.glyph, .done)
    XCTAssertEqual(k6.who, ["顾安"])
    XCTAssertEqual(k6.evidence?.lines.first?.words, "理论部分写好了")
    XCTAssertEqual(k6.evidence?.lines.first?.speaker, "Ann Gu")
    XCTAssertEqual(k6.evidence?.source.word, "企业微信")
    // The same capture filed into another matter: the moment line.
    let k7 = try XCTUnwrap(e6.step("k7"))
    XCTAssertEqual(k7.evidence?.alsoIn.map(\.eventID), ["E45"])
    XCTAssertEqual(k7.evidence?.source.line, "会议记录 · 腾讯会议")
    XCTAssertEqual(k7.evidence?.source.sameCaptureLead, "同一场会还讲到")
    // A past promise that may not have happened is minor (folded).
    XCTAssertEqual(e6.step("k10")?.glyph, .minor)
    XCTAssertEqual(e6.lastDone(today: digest.today)?.date, date(9, 18).startOfDay(calendar))
    XCTAssertEqual(e6.nextDate(today: digest.today, calendar: calendar), date(9, 21).startOfDay(calendar))
    // 按截止: the status step (tomorrow) and the far deadline; the past
    // promise is not a row.
    XCTAssertEqual(digest.deadlines.filter { $0.eventID == "E6" }.map(\.text), ["交回复信", "TES期刊正式截止"])
  }

  func testTheUsersMarkWins() throws {
    let user = UserOrganizingSnapshot(stepOverrides: [
      UserStepOverride(eventID: "E6", stepID: "st1", state: .done, createdAt: date(9, 20, 23)),
      UserStepOverride(eventID: "E6", stepID: "k5", state: .settled, createdAt: date(9, 20, 23)),
    ])
    let digest = MemoryDigest(projection: projection(), user: user, now: now, calendar: calendar)
    let e6 = try XCTUnwrap(digest.matter("E6"))
    let st1 = try XCTUnwrap(e6.step("st1"))
    XCTAssertTrue(st1.isDone)
    XCTAssertFalse(st1.due)
    XCTAssertEqual(st1.date, date(9, 20).startOfDay(calendar), "a future step done today is dated today")
    XCTAssertEqual(st1.override, .done)
    XCTAssertNil(e6.due(today: digest.today, calendar: calendar))
    XCTAssertEqual(e6.openQuestions, [])
    XCTAssertFalse(digest.deadlines.contains { $0.eventID == "E6" && $0.stepID == "st1" })
  }

  func testAnOverdueStatusDeadline() throws {
    let source = MemoryEventSource(
      eventID: "E61", origin: .spark, title: "Workshop短文", statusLine: "9月15日截稿，还没投",
      pinned: false, updatedAt: now, itemIDs: [], personIDs: [])
    let digest = MemoryDigest(
      projection: MemoryProjection(events: [source], records: [], now: now), now: now,
      calendar: calendar)
    let e61 = try XCTUnwrap(digest.matter("E61"))
    XCTAssertEqual(e61.overdue?.text, "截稿")
    XCTAssertEqual(digest.deadlines.first?.stepID, e61.overdue?.id)
  }

  func testDeadlinesFoldAcrossRelatedMatters() {
    func event(_ id: String, _ title: String, _ status: String) -> MemoryEventSource {
      MemoryEventSource(
        eventID: id, origin: .spark, title: title, statusLine: status, pinned: false,
        updatedAt: now, itemIDs: [], personIDs: [])
    }
    let digest = MemoryDigest(
      projection: MemoryProjection(
        events: [
          event("a", "CoRA 2026 新加坡差旅", "9月25日交报销"),
          event("b", "CoRA 2026 报销", "9月25日交报销单"),
          event("c", "租房续约", "9月25日签合同"),
        ], records: [], now: now), now: now, calendar: calendar)
    let rows = digest.deadlines
    XCTAssertEqual(rows.map(\.eventID), ["a", "c"])
    XCTAssertEqual(rows.first?.alsoEventIDs, ["b"])
  }

  // MARK: - Corrections over the projection

  func testHeldCorrectionsApplyAtOnce() throws {
    let base = projection()
    let moved = base.applying([.moveItem(itemID: id(3), segID: nil, from: "E6", to: "E45")])
    XCTAssertFalse(moved.events.first { $0.eventID == "E6" }!.itemIDs.contains(id(3)))
    XCTAssertTrue(moved.events.first { $0.eventID == "E45" }!.itemIDs.contains(id(3)))
    let out = base.applying([.takeOut(itemID: id(5), segID: nil, from: "E6")])
    XCTAssertTrue(out.unfiled.contains { $0.itemID == id(5) })
    let fresh = base.applying([
      .newMatter(itemID: id(2), segID: nil, from: "E6", title: "表2重跑", provisionalID: "n-1")
    ])
    XCTAssertEqual(fresh.events.first?.eventID, "n-1")
    XCTAssertEqual(fresh.events.first?.statusLine, "从“TES论文RoboPrior大修返修”拆分出来")
    let renamed = base.applying([.rename(eventID: "E6", from: "TES论文RoboPrior大修返修", to: "TES 返修")])
    XCTAssertEqual(renamed.events.first { $0.eventID == "E6" }?.title, "TES 返修")
    XCTAssertNil(base.applying([.delete(eventID: "E45", title: "")]).events.first { $0.eventID == "E45" })
    let user = UserOrganizingSnapshot.empty.applying(
      [.markStep(eventID: "E6", stepID: "st1", state: .done, previous: nil), .pin(eventID: "E6", pinned: true)],
      at: now)
    XCTAssertEqual(user.override(eventID: "E6", stepID: "st1")?.state, .done)
    XCTAssertTrue(user.isPinned("E6"))
  }

  func testEveryCorrectionHasItsWayBack() {
    XCTAssertEqual(
      MemoryCorrection.moveItem(itemID: "i", segID: "s1", from: "a", to: "b").inverse,
      .moveItem(itemID: "i", segID: "s1", from: "b", to: "a"))
    XCTAssertEqual(
      MemoryCorrection.takeOut(itemID: "i", segID: nil, from: "a").inverse,
      .moveItem(itemID: "i", segID: nil, from: "", to: "a"))
    XCTAssertEqual(
      MemoryCorrection.newMatter(itemID: "i", segID: nil, from: "a", title: "t", provisionalID: "n")
        .inverse, .moveItem(itemID: "i", segID: nil, from: "n", to: "a"))
    XCTAssertEqual(
      MemoryCorrection.markStep(eventID: "a", stepID: "k", state: .done, previous: nil).inverse,
      .markStep(eventID: "a", stepID: "k", state: nil, previous: .done))
    XCTAssertEqual(
      MemoryCorrection.group(eventID: "a", from: nil, to: "g").inverse,
      .group(eventID: "a", from: "g", to: nil))
    XCTAssertNil(MemoryCorrection.delete(eventID: "a", title: "t").inverse)
    XCTAssertTrue(MemoryCorrection.rename(eventID: "a", from: "x", to: "y").isHeld)
    XCTAssertFalse(MemoryCorrection.markStep(eventID: "a", stepID: "k", state: .done, previous: nil).isHeld)
    XCTAssertFalse(MemoryCorrection.pin(eventID: "a", pinned: true).isUndoable)
    XCTAssertEqual(MemoryCorrection.markStep(eventID: "a", stepID: "k", state: .done, previous: nil).undoLabel, "标记为完成")
  }

  func testSourceWords() {
    let words = MemoryItemSource.words(record(9, at: now, text: "x", app: "织机键盘"))
    XCTAssertEqual(words.line, "键盘 · iPhone")
    XCTAssertEqual(words.symbol, "keyboard")
    XCTAssertEqual(MemoryItemSource.words(record(9, at: now, text: "x", app: "邮件")).sameCaptureLead, "同一封邮件还讲到")
    XCTAssertEqual(MemoryItemSource.words(record(9, at: now, text: "x", app: "Codex")).word, "Codex")
  }

  func testQuoteLines() {
    let lines = MemoryQuoteLines.around(
      "直接 5 了", in: "[09-18 17:30] 韩策：先说结论\n[09-18 17:34] 韩策：R2 那个老哥改分了，直接 5 了\n林知远：太好了",
      dictation: false, ownerNames: ["林知远"])
    XCTAssertEqual(lines.map(\.speaker), ["韩策", "我"])
    XCTAssertEqual(MemoryQuoteLines.punctuated("明天 交回复信 OK"), "明天，交回复信 OK")
  }
}

extension Date {
  fileprivate func startOfDay(_ calendar: Calendar) -> Date { calendar.startOfDay(for: self) }
}
