import BestASRDomain
import BestASREntries
import BestASRIntake
import BestASRMemory
import Foundation
import XCTest

/// V8 contract A5: calendar events of the chosen calendars become items with
/// source 日历 (title, time, attendee names, notes); nothing is ever written
/// to a calendar; Reminders get one reminder only on the owner's click.
final class CalendarEntryTests: XCTestCase {
  private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
  private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 22:13 +08

  /// A reader that only reads; it counts what it was asked.
  private final class FakeCalendar: CalendarReading, @unchecked Sendable {
    var stored: [CalendarEventSnapshot]
    var asked: [[String]] = []
    init(_ events: [CalendarEventSnapshot]) { stored = events }
    func access() -> CalendarAccess { .granted }
    func requestAccess() async -> Bool { true }
    func calendars() -> [CalendarInfo] {
      [
        CalendarInfo(id: "work", title: "工作", source: "iCloud"),
        .init(id: "home", title: "家", source: "iCloud"),
      ]
    }
    func events(from start: Date, to end: Date, calendarIDs: [String]) -> [CalendarEventSnapshot] {
      asked.append(calendarIDs)
      return stored.filter { $0.start < end && $0.end > start }
    }
  }

  /// Counts reminders written.
  private actor CountingReminders: RemindersWriting {
    var written: [ReminderDraft] = []
    func add(_ draft: ReminderDraft) async -> ReminderWriteResult {
      written.append(draft)
      return .added(list: "提醒事项")
    }
  }

  private func event(
    _ key: String, calendar: String = "work", title: String = "组会", start: TimeInterval,
    hours: Double = 1, attendees: [String] = ["张三", "李四"], notes: String? = "带上 Twin-7 的数据"
  ) -> CalendarEventSnapshot {
    CalendarEventSnapshot(
      key: CalendarItemText.key(eventID: key, occurrence: Date(timeIntervalSince1970: start)),
      calendarID: calendar, calendarTitle: calendar == "work" ? "工作" : "家", title: title,
      start: Date(timeIntervalSince1970: start),
      end: Date(timeIntervalSince1970: start + hours * 3_600),
      attendeeNames: attendees, notes: notes)
  }

  func testChosenCalendarsBecomeItemsOnceAndAMovedEventIsANewItem() async throws {
    let past = event("e1", start: 1_789_900_000)  // a day before now
    let future = event("e2", title: "答辩彩排", start: 1_790_300_000, attendees: [], notes: nil)
    let other = event("e3", calendar: "home", title: "家里的事", start: 1_790_100_000)
    var state = CalendarSyncState()
    let items = CalendarSync.plan(
      [past, future, other], chosen: ["work"], state: &state, now: now, timeZone: shanghai)
    XCTAssertEqual(items.count, 2, "only the chosen calendar")
    XCTAssertEqual(items.map(\.source?.name), ["日历", "日历"])
    // A past event keeps its own time; a future one is taken in now.
    XCTAssertEqual(items[0].capturedAt, past.start)
    XCTAssertEqual(items[1].capturedAt, now)
    guard case .text(let text, let extractor) = items[0].candidate else { return XCTFail() }
    XCTAssertEqual(extractor, EntryExtractor.calendarEvent)
    XCTAssertEqual(
      text,
      """
      日程：组会
      时间：2026-09-20 周日 18:26–19:26
      参与人：张三、李四
      日历：工作
      备注：
      带上 Twin-7 的数据
      """)
    // Nothing new: nothing taken.
    XCTAssertEqual(
      CalendarSync.plan(
        [past, future], chosen: ["work"], state: &state, now: now, timeZone: shanghai), [])
    // The rehearsal moves: a new item that says so; the first one stays.
    let moved = event("e2", title: "答辩彩排", start: 1_790_300_000 + 7_200, attendees: [], notes: nil)
    let again = CalendarSync.plan(
      [
        past,
        CalendarEventSnapshot(
          key: future.key, calendarID: "work", calendarTitle: "工作", title: "答辩彩排",
          start: moved.start, end: moved.end),
      ],
      chosen: ["work"], state: &state, now: now, timeZone: shanghai)
    XCTAssertEqual(again.count, 1)
    guard case .text(let movedText, _) = again[0].candidate else { return XCTFail() }
    XCTAssertTrue(movedText.contains("（这条日程有改动，之前收进过一次）"))
    XCTAssertNotEqual(again[0].id, items[1].id)

    // Through intake: idempotent by ID (a crash between commit and saving
    // the state takes nothing twice).
    let root = try makeTemporaryFolder()
    let (committer, store) = makeCommitter(root: root)
    let first = await committer.commit(items)
    let second = await committer.commit(items)
    XCTAssertEqual(first.storedCount, 2)
    XCTAssertEqual(second.storedCount, 0)
    XCTAssertEqual(second.alreadyTaken.count, 2)
    let names = await store.drafts.map(\.source?.name)
    XCTAssertEqual(names, ["日历", "日历"])
  }

  func testAllDayAndMultiDayTimesAndNoEmailAddresses() {
    let day = CalendarEventSnapshot(
      key: "a@1", calendarID: "work", title: "国庆",
      start: Date(timeIntervalSince1970: 1_790_812_800),
      end: Date(timeIntervalSince1970: 1_790_812_800 + 86_400 * 3), isAllDay: true)
    XCTAssertEqual(
      CalendarItemText.text(day, timeZone: TimeZone(identifier: "UTC")!),
      "日程：国庆\n时间：2026-10-01 周四 – 2026-10-03 周六（全天）")
    let untitled = CalendarEventSnapshot(
      key: "b@2", calendarID: "w", title: " \n", start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 3_600), attendeeNames: ["", "王五"])
    let text = CalendarItemText.text(untitled, timeZone: TimeZone(identifier: "UTC")!)
    XCTAssertTrue(text.hasPrefix("日程：（无标题）"))
    XCTAssertTrue(text.contains("参与人：王五"))
    XCTAssertFalse(text.contains("@"))
  }

  /// The calendar entry has no way to write: its reader protocol has only
  /// reads, the EventKit reader never saves or removes, and syncing never
  /// touches Reminders.
  func testTheCalendarIsNeverWritten() async throws {
    let reader = FakeCalendar([event("e1", start: 1_789_900_000)])
    let reminders = CountingReminders()
    var state = CalendarSyncState()
    let (start, end) = CalendarSync.window(now: now)
    _ = CalendarSync.plan(
      reader.events(from: start, to: end, calendarIDs: ["work"]), chosen: ["work"], state: &state,
      now: now)
    let written = await reminders.written
    XCTAssertEqual(written, [])
    XCTAssertEqual(reader.asked, [["work"]])

    // Source check of the EventKit reader: no save, remove or commit call on
    // the event store anywhere in the calendar entry.
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/BestASREntries/CalendarEntry.swift")
        .standardizedFileURL,
      encoding: .utf8)
    for call in [
      "store.save(", "store.remove(", "store.commit(", ".saveCalendar(", "removeCalendar(",
    ] {
      XCTAssertFalse(source.contains(call), "the calendar reader must not call \(call)")
    }
  }

  func testRemindersAreWrittenOnlyOnClickWithTheNextStep() async {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = shanghai
    let draft = ReminderDraft.nextStep(
      text: "把 Twin-7 的数据\n发给王老师", day: Date(timeIntervalSince1970: 1_790_300_000),
      matterTitle: "B203 Twin-7 叠衣真机实验", calendar: calendar)
    XCTAssertEqual(draft.title, "把 Twin-7 的数据 发给王老师")
    XCTAssertEqual(draft.due, DateComponents(year: 2026, month: 9, day: 25))
    XCTAssertEqual(draft.notes, "来自织机：B203 Twin-7 叠衣真机实验")
    XCTAssertEqual(ReminderDraft.nextStep(text: " ", day: nil, matterTitle: "").title, "织机里的下一步")
    let writer = CountingReminders()
    let result = await writer.add(draft)
    XCTAssertEqual(result, .added(list: "提醒事项"))
    let written = await writer.written
    XCTAssertEqual(written, [draft])
  }

  // MARK: 今天到期

  func testDueTodayListsTodaysPlannedStepsAndOverdueOnesReadOnly() {
    func day(_ offset: Int) -> String {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = shanghai
      let date = calendar.date(byAdding: .day, value: offset, to: now)!
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    let event = RemoteOrganizerEvent(
      eventID: "EVT-1", title: "Twin-7 实验", statusLine: "在跑第二轮",
      statusFacts: [
        .init(text: "交初稿", itemIDs: [], state: "planned", date: day(0)),
        .init(text: "补实验", itemIDs: [], state: "planned", date: day(-2)),
        .init(text: "答辩", itemIDs: [], state: "planned", date: day(5)),
        .init(text: "已经做完的", itemIDs: [], state: "done", date: day(0)),
      ])
    let projection = MemoryProjection(
      remote: RemoteOrganizerProjection(cursor: 1, events: [event], questions: [], persons: []),
      records: [], now: now)
    let today = DueList.entries(projection, now: now, days: 0, timeZone: shanghai)
    XCTAssertEqual(today.map(\.text), ["补实验", "交初稿"])
    XCTAssertEqual(today.map(\.overdue), [true, false])
    let week = DueList.entries(projection, now: now, days: 7, timeZone: shanghai)
    XCTAssertEqual(week.map(\.text), ["补实验", "交初稿", "答辩"])
    let rendered = DueList.render(today, days: 0)
    XCTAssertEqual(rendered.heading, "今天到期 1 件，另有 1 件已过期：")
    XCTAssertEqual(rendered.lines.count, 2)
    XCTAssertTrue(rendered.lines[0].contains("（已过期） 补实验 — Twin-7 实验"))
    XCTAssertEqual(DueList.render([], days: 3).heading, "接下来 3 天没有到期的事。")
  }

  /// Review V8R-18: a next step goes to a list kept on this Mac when there is
  /// one; only without one does it go to the (synced) default list, and the
  /// result says so.
  func testRemindersPreferAListOnThisMac() {
    struct List: Equatable {
      let title: String
      let local: Bool
    }
    let icloud = List(title: "提醒事项", local: false)
    let mine = List(title: "本机", local: true)
    let other = List(title: "A 本机", local: true)
    func pick(_ fallback: List?, _ local: [List]) -> List? {
      ReminderListChoice.pick(default: fallback, local: local, isLocal: \.local, title: \.title)
    }
    XCTAssertEqual(pick(icloud, [mine, other]), other)
    XCTAssertEqual(pick(mine, [other]), mine)
    XCTAssertEqual(pick(icloud, []), icloud)
    XCTAssertNil(pick(nil, []))
    XCTAssertNotEqual(
      ReminderWriteResult.addedSynced(list: "提醒事项", account: "iCloud"),
      .added(list: "提醒事项"))
  }
}
