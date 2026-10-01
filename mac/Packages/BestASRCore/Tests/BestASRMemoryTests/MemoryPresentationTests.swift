import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

/// Questions, Unfiled, related events, days and people as the memory pages
/// show them. Synthetic events and records only; time is injected.
final class MemoryPresentationTests: XCTestCase {
  private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
  // 2026-09-27 09:00:00 +08:00
  private let base = Date(timeIntervalSince1970: 1_790_470_800)

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = shanghai
    return calendar
  }

  private func id(_ n: Int) -> String {
    String(format: "00000000-0000-0000-0000-%012d", n)
  }

  private func record(_ n: Int, at offset: TimeInterval, text: String, people: [(Int, String)] = [])
    -> MemoryItemRecord
  {
    MemoryItemRecord(
      sessionID: SessionID(UUID(uuidString: id(n))!), inputMode: .userItem, itemKind: .text,
      title: "条目", startedAt: base.addingTimeInterval(offset),
      updatedAt: base.addingTimeInterval(offset), sourceBundleID: nil,
      sourceDisplayName: "微信", sourceIdentifier: nil, text: text,
      people: people.map {
        .init(id: PersonID(UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", $0.0))!), name: $0.1)
      })
  }

  private func question(_ id: String, a: String, b: String, kind: String = "same_event", hoursAgo: Double)
    -> RemoteOrganizerQuestion
  {
    let formatter = ISO8601DateFormatter()
    let created = formatter.string(from: base.addingTimeInterval(-hoursAgo * 3_600))
    return try! JSONDecoder().decode(
      RemoteOrganizerQuestion.self,
      from: Data(
        """
        {"question_id":"\(id)","kind":"\(kind)","a":"\(a)","b":"\(b)",
         "prompt_zh":"问题\(id)","created_at":"\(created)"}
        """.utf8))
  }

  private func projection(questions: [RemoteOrganizerQuestion] = []) -> MemoryProjection {
    let events = [
      MemoryEventSource(
        eventID: "ev-rent", origin: .spark, title: "租房续约", statusLine: "", pinned: false,
        updatedAt: base, itemIDs: [id(1), id(2)], personIDs: ["p-wang"],
        statusFacts: [
          MemoryStatusFact(
            remote: .init(
              text: "周五去签字", itemIDs: [id(2)], state: "planned", date: "2026-09-26")),
          MemoryStatusFact(remote: .init(text: "老说法", itemIDs: [])),
        ]),
      MemoryEventSource(
        eventID: "ev-net", origin: .spark, title: "新家宽带", statusLine: "师傅周日来装",
        pinned: false, updatedAt: base, itemIDs: [id(3)], personIDs: ["p-wang", "p-x"]),
      MemoryEventSource(
        eventID: "ev-camp", origin: .spark, title: "露营", statusLine: "差一顶帐篷",
        pinned: false, updatedAt: base, itemIDs: [], personIDs: ["p-jie"]),
    ]
    let persons = try! JSONDecoder().decode(
      [RemoteOrganizerPerson].self,
      from: Data(
        """
        [{"person_id":"p-wang","display_name":"王姐","aliases":[],"origin":"chat","merged_into":null},
         {"person_id":"p-x","display_name":null,"aliases":[],"origin":"voice","merged_into":null},
         {"person_id":"p-jie","display_name":"阿杰","aliases":[],"origin":"chat","merged_into":null}]
        """.utf8))
    return MemoryProjection(
      events: events,
      records: [
        record(1, at: 0, text: "王姐：下个月起房租想涨 300"),
        record(2, at: 86_400, text: "合同第 3 页\n押金一个月"),
        record(3, at: 3_600, text: "[10:02] 王姐：师傅那段"),
        record(4, at: 7_200, text: "只是随手一记"),
        record(5, at: 60, text: "被移出的"),
      ],
      persons: persons, questions: questions,
      unfiled: [
        .init(itemID: id(4), reason: "none"), .init(itemID: id(5), reason: "removed_by_user"),
        .init(itemID: id(99), reason: "none"),
      ],
      now: base)
  }

  func testQuestionsAreClassifiedByShapeAndExpireAfter72Hours() {
    let projection = projection(questions: [
      question("q-into", a: id(3), b: "ev-rent", hoursAgo: 1),
      question("q-stay", a: id(2), b: "ev-rent", hoursAgo: 2),
      question("q-merge", a: "ev-rent", b: "ev-net", hoursAgo: 71.9),
      question("q-person", a: "p-x", b: "p-wang", kind: "same_person", hoursAgo: 3),
      question("q-old", a: id(3), b: "ev-rent", hoursAgo: 72),
    ])
    let open = projection.memoryQuestions()
    XCTAssertEqual(open.map(\.questionID), ["q-into", "q-stay", "q-merge", "q-person"])
    XCTAssertEqual(
      open.map(\.kind), [.itemIntoEvent, .itemStaysInEvent, .mergeEvents, .samePerson])
    XCTAssertEqual(open[0].prompt, "问题q-into", "shown as written")
    XCTAssertEqual(open[0].itemID, id(3))
    XCTAssertEqual(open[3].personIDs, ["p-x", "p-wang"])
    XCTAssertEqual(projection.bannerQuestion()?.questionID, "q-into")
    // The event page gets the questions about it, not the people ones.
    let detail = projection.event(id: "ev-rent")
    XCTAssertEqual(detail?.questions.map(\.questionID), ["q-into", "q-stay", "q-merge"])
  }

  func testStatusFactsKeepTheirStateAndDay() throws {
    let detail = try XCTUnwrap(projection().event(id: "ev-rent"))
    XCTAssertEqual(detail.statusFacts.map(\.state), [.planned, .info])
    XCTAssertEqual(detail.statusFacts[0].day, DateComponents(year: 2026, month: 9, day: 26))
    XCTAssertEqual(
      MemoryDateText.factDay(detail.statusFacts[0].day!, calendar: calendar, now: base), "9月26日")
    // No written status line: the newest item's first line, marked as such.
    XCTAssertEqual(detail.statusLine, "合同第 3 页")
    XCTAssertTrue(detail.statusIsFallback)
    let home = projection().home()
    XCTAssertEqual(home[0].statusLine, "合同第 3 页")
    XCTAssertTrue(home[0].statusIsFallback)
    XCTAssertFalse(home[1].statusIsFallback)
  }

  func testFactsHaveAFixedOrderWhateverTheOrganizerSent() {
    func fact(_ text: String, _ state: String, _ date: String? = nil) -> MemoryStatusFact {
      MemoryStatusFact(remote: .init(text: text, itemIDs: [], state: state, date: date))
    }
    let sent = [
      fact("已签", "done"), fact("押金一个月", "info"), fact("周一汇报", "planned", "2026-09-28"),
      fact("不去了", "cancelled"), fact("在修", "in_progress"), fact("没日子", "planned"),
      fact("周日交", "planned", "2026-09-27"),
    ]
    let expected = ["周日交", "周一汇报", "没日子", "在修", "已签", "不去了", "押金一个月"]
    XCTAssertEqual(MemoryStatusFact.ordered(sent).map(\.text), expected)
    XCTAssertEqual(MemoryStatusFact.ordered(sent.reversed()).map(\.text), expected)
  }

  func testDateChipIsHiddenWhenTheTextSaysTheDay() {
    func chip(_ text: String, _ date: String = "2026-09-28") -> Int? {
      MemoryStatusFact(remote: .init(text: text, itemIDs: [], state: "planned", date: date))
        .chipDay?.day
    }
    XCTAssertNil(chip("定于9月28日（周一）上午10点汇报"))
    XCTAssertNil(chip("9月28号前交"))
    XCTAssertNil(chip("9/28 交 PPT"))
    XCTAssertNil(chip("2026-09-28 汇报"))
    XCTAssertNil(chip("28日上午汇报"))
    XCTAssertEqual(chip("周一上午汇报"), 28)
    XCTAssertEqual(chip("9月2日汇报", "2026-09-28"), 28)
    XCTAssertEqual(chip("9月28日交，10月2日聚餐", "2026-10-02"), nil)
    XCTAssertEqual(chip("10月28日交", "2026-09-28"), 28)
  }

  func testChatTextReadsAsTurnsOnlyWhenItIsAConversation() {
    let chat = MemoryChatText.turns(
      in: "周经理：林晓，PPT周日晚上前发我。\n我：好的周经理\n今天先拉数据。")
    XCTAssertEqual(chat?.map(\.name), ["周经理", "我"])
    XCTAssertEqual(chat?.last?.text, "好的周经理 今天先拉数据。")
    XCTAssertEqual(
      MemoryChatText.turns(in: "姐姐：周二 B 超\n陈阿姨：好\n姐姐：带医保卡")?.count, 3)
    // A list of fields, an outline, a URL, times and one line are not chats.
    XCTAssertNil(MemoryChatText.turns(in: "时间：周二 9:30\n地点：市一医院\n带：医保卡"))
    XCTAssertNil(MemoryChatText.turns(in: "Q3运营汇报提纲：\n一、核心指标：留存率 41%"))
    XCTAssertNil(MemoryChatText.turns(in: "https://example.com\n我：看这个"))
    XCTAssertNil(MemoryChatText.turns(in: "10:30 开会\n我：好"))
    XCTAssertNil(MemoryChatText.turns(in: "我：好"))
  }

  /// One named line reads as a turn only when the name is a person of the
  /// event (and not the Mac's user).
  func testOneNamedLineOfAKnownPersonIsATurn() {
    let line = "小刘：林晓，渠道转化率的表我更新好了"
    XCTAssertNil(MemoryChatText.turns(in: line))
    XCTAssertNil(MemoryChatText.turns(in: line, knownNames: ["周经理"]))
    let turns = MemoryChatText.turns(in: line, knownNames: ["小刘", "周经理"])
    XCTAssertEqual(turns?.map(\.name), ["小刘"])
    XCTAssertEqual(turns?.first?.text, "林晓，渠道转化率的表我更新好了")
    XCTAssertNil(MemoryChatText.turns(in: "我：好", knownNames: ["我"]))
    XCTAssertNil(MemoryChatText.turns(in: "时间：周二 9:30", knownNames: ["小刘"]))
  }

  /// The organizing device's reading: its summary line apart, and a time
  /// stamp every message repeats left out; the raw text is kept.
  func testScreenshotReadingSplitsTheSummaryAndDropsARepeatedStamp() {
    let raw = """
      我告知姐姐约好了B超
      [9月24日 19:28] 我：妈妈的B超约好了
      [9月24日 19:28] 姐姐：好，我请假陪妈去
      """
    let reading = MemoryScreenshotReading(organizer: raw)
    XCTAssertEqual(reading.raw, raw)
    XCTAssertEqual(reading.summary, "我告知姐姐约好了B超")
    XCTAssertEqual(reading.body, "我：妈妈的B超约好了\n姐姐：好，我请假陪妈去")
    // Different times stay.
    let timed = MemoryScreenshotReading(organizer: "概要\n[10:02] 甲：好\n[10:05] 乙：行")
    XCTAssertEqual(timed.body, "[10:02] 甲：好\n[10:05] 乙：行")
    // One line has no summary; a stamped first line is a message.
    XCTAssertNil(MemoryScreenshotReading(organizer: "聊天截图：甲说周五见").summary)
    XCTAssertNil(MemoryScreenshotReading(organizer: "[10:02] 甲：好\n[10:05] 乙：行").summary)
    // A summary sent apart: the text is all message, whatever its first line.
    let apart = MemoryScreenshotReading(
      organizer: "陈阿姨：热水器下周修\n我：好的", summary: "房东说热水器\n下周修")
    XCTAssertEqual(apart.summary, "房东说热水器 下周修")
    XCTAssertEqual(apart.body, "陈阿姨：热水器下周修\n我：好的")
    let none = MemoryScreenshotReading(organizer: "陈阿姨：热水器下周修\n我：好的", summary: "")
    XCTAssertNil(none.summary)
    XCTAssertEqual(none.body, "陈阿姨：热水器下周修\n我：好的")
    // A reading made on this Mac has none either.
    let local = MemoryScreenshotReading(local: "会议纪要\n甲：周五交稿")
    XCTAssertNil(local.summary)
    XCTAssertEqual(local.body, "会议纪要\n甲：周五交稿")
  }

  /// Up to six named people on Home never share a colour, however their IDs
  /// hash; the first to appear keeps the colour of their ID, and events and
  /// the people list agree.
  func testVisiblePeopleNeverShareAColour() throws {
    let target = MemoryPersonColor.index(for: "person-0")
    let ids = Array(
      (0..<400).map { "person-\($0)" }.filter { MemoryPersonColor.index(for: $0) == target }
        .prefix(7))
    XCTAssertEqual(ids.count, 7)
    // Each in two matters, so each is one of the people Home shows.
    let events = ids.enumerated().flatMap { index, person in
      ["", "-b"].map { suffix in
        MemoryEventSource(
          eventID: "ev-\(index)\(suffix)", origin: .spark, title: "事\(index)\(suffix)",
          statusLine: "", pinned: false, updatedAt: base, itemIDs: [id(index + 1)],
          personIDs: [person])
      }
    }
    let personsJSON = ids.enumerated().map { index, person in
      #"{"person_id":"\#(person)","display_name":"人\#(Array("甲乙丙丁戊己庚")[index])","aliases":[],"origin":"chat","merged_into":null}"#
    }.joined(separator: ",")
    let persons = try JSONDecoder().decode(
      [RemoteOrganizerPerson].self, from: Data("[\(personsJSON)]".utf8))
    // Person 0 appeared first; person 6 appeared longest ago of all but is
    // the least recent, so it falls outside the six on Home.
    let offsets: [TimeInterval] = [-6_000, 600, 500, 400, 300, 200, -7_000]
    let records = offsets.enumerated().map { index, offset in
      record(index + 1, at: offset, text: "第\(index)条")
    }
    let make = {
      MemoryProjection(events: events, records: records, persons: persons, now: self.base)
    }
    let projection = make()
    let row = projection.featuredPeople()
    let visible = Array(row.prefix(MemoryPersonColor.count))
    XCTAssertEqual(Set(visible.map(\.colorIndex)).count, visible.count)
    XCTAssertFalse(visible.contains { $0.personID == ids[6] })
    // The earliest of the visible people keeps the colour of their ID.
    XCTAssertEqual(visible.first { $0.personID == ids[0] }?.colorIndex, target)
    // Outside the six: the colour of their ID.
    XCTAssertEqual(row.first { $0.personID == ids[6] }?.colorIndex, target)
    // Cards and the people list agree; the same inputs give the same colours.
    for entry in projection.home() {
      for person in entry.people {
        XCTAssertEqual(person.colorIndex, row.first { $0.personID == person.personID }?.colorIndex)
      }
    }
    XCTAssertEqual(make().featuredPeople().map(\.colorIndex), row.map(\.colorIndex))
  }

  /// The Spark flattens a screenshot's reading as a summary line, then
  /// "[time] sender：text" per message (screenshot-read compose_text).
  func testSparkScreenshotReadingReadsAsTurnsAfterItsSummary() {
    let reading = "姐姐和我约妈妈周二复查\n[10:02] 姐姐：号约好了，周二上午 B 超\n[10:05] 我：好，我请半天假"
    let turns = MemoryChatText.turns(in: reading, leadingSummary: true)
    XCTAssertEqual(turns?.map(\.name), ["姐姐", "我"])
    XCTAssertEqual(turns?.first?.text, "号约好了，周二上午 B 超")
    // The stamp may carry a day, as read off the screenshot.
    let dated = "我告知姐姐约好了\n[9月24日 19:28] 我：约好了，周二上午\n[9月24日 19:28] 姐姐：好，我请假陪妈去"
    XCTAssertEqual(
      MemoryChatText.turns(in: dated, leadingSummary: true)?.map(\.text),
      ["约好了，周二上午", "好，我请假陪妈去"])
    // Without the summary allowance the first line is not a turn.
    XCTAssertNil(MemoryChatText.turns(in: reading))
    // A summary alone before notes is still not a chat.
    XCTAssertNil(
      MemoryChatText.turns(in: "复查安排\n时间：周二 9:30\n地点：市一医院", leadingSummary: true))
  }

  func testUnfiledItemsAreNewestFirstAndSkipItemsNotOnThisMac() {
    let unfiled = projection().unfiledItems()
    XCTAssertEqual(unfiled.map(\.item.itemID), [id(4), id(5)])
    XCTAssertEqual(unfiled.map(\.reason), ["none", "removed_by_user"])
  }

  /// 王姐 writes in both matters (a speaker line in each), so they relate.
  func testRelatedEventsSharePeople() {
    let related = projection().related(to: "ev-rent")
    XCTAssertEqual(related.map(\.eventID), ["ev-net"])
  }

  func testDayGroupsFollowTheInjectedCalendar() throws {
    let detail = try XCTUnwrap(projection().event(id: "ev-rent"))
    let groups = detail.dayGroups(calendar: calendar)
    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(
      groups.map { MemoryDateText.dayHeader($0.day!, calendar: calendar, now: base) },
      ["9月27日 周日", "9月28日 周一"])
    XCTAssertEqual(MemoryDateText.time(base, calendar: calendar), "09:00")
    XCTAssertEqual(
      MemoryDateText.span(
        MemoryEventSpan(start: base, end: base.addingTimeInterval(3 * 86_400)),
        calendar: calendar, now: base),
      "9月27日 – 9月30日")
    XCTAssertEqual(MemoryDateText.duration(nanoseconds: 192_000_000_000), "3 分 12 秒")
  }

  func testPeopleAreNamesOrAQuestionMarkWithStableColours() {
    let projection = projection()
    let people = projection.people()
    let unnamed = try! XCTUnwrap(people.first { $0.personID == "p-x" })
    XCTAssertEqual(unnamed.name, "?")
    XCTAssertFalse(unnamed.isNamed)
    XCTAssertTrue(people.first { $0.personID == "p-wang" }!.isNamed)
    XCTAssertEqual(projection.home()[1].people.map(\.name), ["王姐", "?"])
    // Stable across processes: a fixed FNV-1a value, not Swift's seeded hash.
    XCTAssertEqual(MemoryPersonColor.index(for: "p-wang"), MemoryPersonColor.index(for: "P-WANG"))
    XCTAssertTrue((0..<6).contains(MemoryPersonColor.index(for: "p-wang")))
    let spread = Set((0..<60).map { MemoryPersonColor.index(for: "person-\($0)") })
    XCTAssertEqual(spread.count, 6)
    // The Home row: people seen in events, most recent first.
    XCTAssertEqual(projection.recentPeople().first?.personID, "p-wang")
    XCTAssertNotNil(projection.recentPeople().first?.lastSeen)
  }

  func testSearchMatchesTitleStatusAndPeople() {
    let home = projection().home()
    XCTAssertEqual(home.filter { $0.matches("王姐") }.map(\.eventID), ["ev-rent", "ev-net"])
    XCTAssertEqual(home.filter { $0.matches("帐篷") }.map(\.eventID), ["ev-camp"])
    XCTAssertEqual(home.filter { $0.matches("  ") }.count, 3)
  }
}

/// Each correction on the pages records the decision the organizer expects.
final class MemoryDecisionTests: XCTestCase {
  func testCorrectionsAreWellFormedDecisionsOfTheRightKind() throws {
    let newID = UUID(uuidString: "0C7D8E0A-1111-4222-8333-444455556666")!
    let decisions = [
      MemoryDecisions.rename(eventID: "ev", title: "我的标题"),
      MemoryDecisions.pin(eventID: "ev", pinned: true),
      MemoryDecisions.featureLess(eventID: "ev"),
      MemoryDecisions.remove(itemID: "it", from: "ev"),
      MemoryDecisions.move(itemID: "it", to: "ev-2"),
      MemoryDecisions.fileAsNewEvent(itemID: "it", newEventID: newID),
      MemoryDecisions.name(personID: "p", name: "王姐"),
    ]
    XCTAssertEqual(
      decisions.map(\.kind),
      [
        "rename_event", "pin_event", "feature_less", "remove_item", "move_item",
        "file_item_new_event", "name_person",
      ])
    XCTAssertTrue(decisions.allSatisfy(\.isWellFormed))
    XCTAssertEqual(decisions[5].newEventID, "0c7d8e0a-1111-4222-8333-444455556666")
    XCTAssertEqual(decisions[4].toEventID, "ev-2")
    XCTAssertEqual(decisions[3].eventID, "ev")
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(decisions[5])) as? [String: Any])
    XCTAssertEqual(json["new_event_id"] as? String, "0c7d8e0a-1111-4222-8333-444455556666")
    XCTAssertEqual(json["item_id"] as? String, "it")
  }
}
