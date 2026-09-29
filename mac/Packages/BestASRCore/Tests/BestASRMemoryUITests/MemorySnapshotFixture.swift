import AppKit
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import Foundation

/// A synthetic library for snapshots: invented people, events, and items.
/// Nothing here is read from a real library or the network.
enum MemorySnapshotFixture {
  static let zone = TimeZone(identifier: "Asia/Shanghai")!
  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }

  /// 2026-09-26 20:00 +08:00.
  static let now = date(9, 26, 20, 0)

  static func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
  }

  // People, with IDs whose stable colours match the design mockup.
  static let wang = "A0000000-0000-4000-8000-000000000013"
  static let mom = "A0000000-0000-4000-8000-000000000001"
  static let zhou = "A0000000-0000-4000-8000-000000000002"
  static let jie = "A0000000-0000-4000-8000-000000000003"
  static let chen = "A0000000-0000-4000-8000-000000000007"
  static let me = "A0000000-0000-4000-8000-000000000006"
  static let unnamed = "A0000000-0000-4000-8000-000000000022"
  static let jieGe = "A0000000-0000-4000-8000-000000000015"

  static func item(_ n: Int) -> String { String(format: "B0000000-0000-4000-8000-%012d", n) }
  static func sid(_ n: Int) -> SessionID { SessionID(UUID(uuidString: item(n))!) }
  static func pid(_ id: String) -> PersonID { PersonID(UUID(uuidString: id)!) }

  static func record(
    _ n: Int, _ mode: SessionInputMode, kind: UserItemKind? = nil, at date: Date,
    app: String? = nil, bundle: String? = nil, text: String, title: String = "记录",
    segments: [MemoryItemRecord.Segment] = [], people: [MemoryItemRecord.Person] = [],
    duration: TimeInterval? = nil, thumbnail: String? = nil
  ) -> MemoryItemRecord {
    MemoryItemRecord(
      sessionID: sid(n), inputMode: mode, itemKind: kind, title: title, startedAt: date,
      updatedAt: date, sourceBundleID: bundle, sourceDisplayName: app, sourceIdentifier: nil,
      text: text, segments: segments, people: people,
      durationNanoseconds: duration.map { UInt64($0 * 1_000_000_000) },
      playbackAvailable: duration != nil, thumbnailAssetPath: thumbnail)
  }

  static var records: [MemoryItemRecord] {
    let wangP = MemoryItemRecord.Person(id: pid(wang), name: "王姐")
    let meP = MemoryItemRecord.Person(id: pid(me), name: "我")
    func seg(_ person: String?, _ name: String?, _ text: String, _ start: Int64)
      -> MemoryItemRecord.Segment
    {
      .init(
        startMilliseconds: start, endMilliseconds: start + 3_000,
        personID: person.map(pid), personName: name, text: text,
        monotonicStartNanoseconds: UInt64(start) * 1_000_000,
        monotonicEndNanoseconds: UInt64(start + 3_000) * 1_000_000)
    }
    return [
      // 租房续约
      // A pasted chat: its "名：" lines read as turns.
      record(
        1, .userItem, kind: .text, at: date(9, 22, 20, 14), app: "微信",
        bundle: "com.tencent.xinWeChat",
        text: """
          王姐：下个月起房租想涨 300，你看行不？
          我：最多 200，热水器得先修好。
          王姐：那我跟家里商量一下，
          明天回你。
          """),
      record(
        2, .dictation, at: date(9, 22, 20, 31), app: "备忘录", bundle: "com.apple.Notes",
        text: "跟王姐说最多涨 200，热水器得先修好。"),
      record(
        3, .userItem, kind: .image, at: date(9, 24, 12, 5), app: "微信",
        bundle: "com.tencent.xinWeChat", text: "合同第 3 页：维修条款、押金一个月", title: "截图",
        thumbnail: "contract"),
      record(
        4, .roomMicrophone, at: date(9, 24, 19, 40), app: "内建麦克风",
        text: "热水器周六让师傅来看。那涨 200 我这边没问题。行，周五你过来签。",
        segments: [
          seg(wang, "王姐", "热水器周六让师傅来看。", 0),
          seg(me, "我", "那涨 200 我这边没问题。", 3_000),
          seg(wang, "王姐", "行，周五你过来签。", 6_000),
        ],
        people: [wangP, meP], duration: 192),
      record(
        5, .userItem, kind: .text, at: date(9, 25, 10, 2), app: "Claude",
        bundle: "com.anthropic.claudefordesktop",
        text: "签之前确认四件事：押金怎么退、维修谁出钱、提前退租怎么算、涨价写进哪一条。"),
      // 妈妈复查
      record(
        6, .userItem, kind: .text, at: date(9, 20, 9, 30), app: "微信",
        bundle: "com.tencent.xinWeChat", text: "妈妈：周四的号挂上了，上午十点。"),
      // A chat screenshot with nothing read on this Mac: the organizing
      // device's reading stands in for its text.
      record(
        14, .userItem, kind: .image, at: date(9, 25, 21, 30), app: "微信",
        bundle: "com.tencent.xinWeChat", text: "", title: "截图", thumbnail: "chat"),
      record(
        7, .roomMicrophone, at: date(9, 26, 11, 0), app: "内建麦克风",
        text: "结果下周出，先别担心。",
        segments: [seg(chen, "陈医生", "结果下周出，先别担心。", 0)],
        people: [.init(id: pid(chen), name: "陈医生")], duration: 95),
      // 季度汇报
      record(
        8, .systemAudio, at: date(9, 18, 15, 0), app: "腾讯会议",
        bundle: "com.tencent.meeting", text: "第三页数据还缺，周二前给小周。",
        segments: [seg(zhou, "小周", "第三页数据还缺，周二前给我。", 0)],
        people: [.init(id: pid(zhou), name: "小周"), .init(id: pid(unnamed), name: "")],
        duration: 1_860),
      record(
        9, .userItem, kind: .document, at: date(9, 26, 9, 0), app: "访达",
        bundle: "com.apple.finder", text: "季度汇报草稿 v3", title: "汇报.pdf"),
      // 周末露营
      record(
        10, .userItem, kind: .text, at: date(9, 24, 21, 0), app: "微信",
        bundle: "com.tencent.xinWeChat", text: "周六出发，帐篷还差一顶。"),
      // 车险续保
      record(
        11, .userItem, kind: .image, at: date(9, 21, 14, 0), app: "Safari",
        bundle: "com.apple.Safari", text: "", title: "截图", thumbnail: "quote"),
      record(
        12, .userItem, kind: .text, at: date(9, 23, 9, 0), app: "备忘录",
        bundle: "com.apple.Notes", text: "两家报价差 300"),
      // 新家宽带
      record(
        13, .roomMicrophone, at: date(9, 25, 18, 20), app: "内建麦克风",
        text: "师傅说周日上午来装。", segments: [seg(unnamed, nil, "师傅说周日上午来装。", 0)],
        people: [.init(id: pid(unnamed), name: "")], duration: 48),
      // Unfiled
      record(
        20, .userItem, kind: .text, at: date(9, 26, 16, 12), app: "Safari",
        bundle: "com.apple.Safari", text: "露营装备清单：睡袋、防潮垫、头灯"),
      record(
        21, .userItem, kind: .text, at: date(9, 25, 22, 40), app: "备忘录",
        bundle: "com.apple.Notes", text: "记得给车加油"),
      record(
        22, .roomMicrophone, at: date(9, 25, 8, 15), app: "内建麦克风",
        text: "早上的会改到十点半。", duration: 21),
    ]
  }

  static func event(
    _ id: String, _ title: String, status: String, items: [Int], people: [String],
    facts: [RemoteOrganizerEvent.StatusFact] = [], importance: Double, pinned: Bool = false
  ) -> RemoteOrganizerEvent {
    RemoteOrganizerEvent(
      eventID: id, title: title, statusLine: status, statusFacts: facts,
      importance: importance, updatedAt: "2026-09-26T12:00:00+08:00",
      itemIDs: items.map(item), personIDs: people, pinned: pinned, handle: "E1", anchor: title)
  }

  static var persons: [RemoteOrganizerPerson] {
    func person(_ id: String, _ name: String?, merged: String? = nil) -> RemoteOrganizerPerson {
      let nameJSON = name.map { "\"\($0)\"" } ?? "null"
      let mergedJSON = merged.map { "\"\($0)\"" } ?? "null"
      return try! JSONDecoder().decode(
        RemoteOrganizerPerson.self,
        from: Data(
          """
          {"person_id":"\(id)","display_name":\(nameJSON),"aliases":[],"origin":"voice",
           "merged_into":\(mergedJSON)}
          """.utf8))
    }
    return [
      person(wang, "王姐"), person(mom, "妈妈"), person(zhou, "小周"), person(jie, "阿杰"),
      person(chen, "陈医生"), person(me, "我"), person(unnamed, nil), person(jieGe, "杰哥"),
    ]
  }

  static func question(_ id: String, _ kind: String, a: String, b: String, prompt: String)
    -> RemoteOrganizerQuestion
  {
    try! JSONDecoder().decode(
      RemoteOrganizerQuestion.self,
      from: Data(
        """
        {"question_id":"\(id)","kind":"\(kind)","a":"\(a)","b":"\(b)",
         "prompt_zh":"\(prompt)","created_at":"2026-09-26T10:00:00+08:00"}
        """.utf8))
  }

  static func remote(questions: Bool) -> RemoteOrganizerProjection {
    let events = [
      event(
        "ev-rent", "租房续约", status: "说定涨 200，周五去签字", items: [1, 2, 3, 4, 5],
        people: [wang],
        // Listed out of order on purpose: the page sorts them.
        facts: [
          .init(text: "房租涨 200", itemIDs: [item(4)], state: "done", quote: "那涨 200 我这边没问题"),
          .init(text: "押金一个月", itemIDs: [item(3)], state: "info"),
          .init(text: "9月28日前把押金转过去", itemIDs: [item(5)], state: "planned", date: "2026-09-28"),
          .init(text: "热水器周六修", itemIDs: [item(4)], state: "in_progress"),
          .init(text: "周五去签字", itemIDs: [item(4)], state: "planned", date: "2026-09-26"),
        ], importance: 0.9),
      event(
        "ev-mom", "妈妈复查", status: "周二 9:30 B超，姐姐陪妈去；医保卡、就诊卡和上次的报告都要带上",
        items: [6, 14, 7], people: [mom, chen],
        facts: [
          .init(text: "周二9:30 B超", itemIDs: [item(14)], state: "planned", date: "2026-09-29"),
          .init(text: "号挂上了", itemIDs: [item(6)], state: "done"),
        ], importance: 0.85),
      event(
        "ev-report", "季度汇报", status: "第三页数据还缺，周二前给小周", items: [8, 9],
        people: [zhou, unnamed], importance: 0.8),
      event(
        "ev-camp", "周末露营", status: "周六出发，还差一顶帐篷", items: [10], people: [jie],
        importance: 0.7),
      event(
        "ev-car", "车险续保", status: "两家报价差 300，还没定", items: [11, 12], people: [],
        importance: 0.6),
      event(
        "ev-net", "新家宽带", status: "师傅约了周日上午来装", items: [13],
        people: [wang, unnamed], importance: 0.5),
    ]
    let asked =
      questions
      ? [
        question(
          "q-person", "same_person", a: jie, b: jieGe, prompt: "「阿杰」和微信里的「杰哥」是同一个人吗？"),
        // The organizer's own shape: the item named by its words.
        question(
          "q-item", "same_event", a: item(13), b: "ev-rent",
          prompt: "这条「师傅说周日上午来装。」和「租房续约」是同一件事吗？"),
      ] : []
    return RemoteOrganizerProjection(
      cursor: 9, events: events, questions: asked, persons: persons,
      unfiled: [
        .init(itemID: item(20), reason: "none"), .init(itemID: item(21), reason: "none"),
        .init(itemID: item(22), reason: "removed_by_user"),
      ],
      readings: [item(14): screenshotReading],
      readingSummaries: [item(14): screenshotSummary])
  }

  /// The organizing device's reading of the chat screenshot, in the form
  /// the Spark sends it: "sender：text" per message (the screenshot's one
  /// time label is not repeated on each line), its summary sent apart.
  static let screenshotReading = """
    姐姐：妈妈的号约好了，下周二上午 9:30 市一医院 B 超
    我：好，我请半天假陪她去
    姐姐：医保卡、就诊卡和上次的报告都带上
    """
  static let screenshotSummary = "姐姐约好妈妈周二的 B 超复查，我请假陪同"

  static func sparkProjection(questions: Bool) -> MemoryProjection {
    MemoryProjection(
      remote: remote(questions: questions), records: records, now: now, ownerPersonIDs: [me])
  }

  /// The same library organized on the Mac: no status lines written (the
  /// newest item stands in), no pin, questions from local candidates.
  static var localProjection: MemoryProjection {
    let sources = remote(questions: false).events.map { event in
      MemoryEventSource(
        eventID: event.eventID, origin: .local, title: event.title,
        statusLine: event.eventID == "ev-rent" ? "周五去签字" : "", pinned: false,
        updatedAt: now, itemIDs: event.itemIDs, personIDs: event.personIDs)
    }
    return MemoryProjection(
      events: sources, records: records, persons: persons,
      unfiled: [
        .init(itemID: item(20), reason: "local"), .init(itemID: item(22), reason: "local"),
      ],
      localQuestions: [
        MemoryQuestion(
          questionID: "local-1", kind: .itemIntoEvent,
          prompt: MemoryQuestion.itemPrompt(
            itemText: "露营装备清单：睡袋、防潮垫、头灯", eventTitle: "周末露营"),
          a: item(20), b: "ev-camp", createdAt: now, origin: .local)
      ],
      now: now, ownerPersonIDs: [me])
  }

  /// Link off, nothing organized into an event yet, two items waiting.
  static var unfiledOnlyProjection: MemoryProjection {
    MemoryProjection(
      events: [], records: records,
      unfiled: [
        .init(itemID: item(20), reason: "local"), .init(itemID: item(21), reason: "local"),
      ],
      now: now, ownerPersonIDs: [me])
  }

  static let issues = [
    MemoryIssue(id: "d-1", title: "整理设备未接受：改标题（标题太长）", deliveryUnknown: false),
    MemoryIssue(id: "d-2", title: "确认同一件事：关闭链路时正在发送，可能已送达；重试以确认", deliveryUnknown: true),
  ]

  static var personReviews: [String: [MemoryPersonReview]] {
    [
      wang.uppercased(): [
        MemoryPersonReview(
          id: "r-1", prompt: "这段声音是王姐吗？", meta: "9月25日 18:20 · 当面 · 「新家宽带」",
          itemID: item(13), origin: .voiceMatch("speaker-1"), startNanoseconds: 0,
          endNanoseconds: 3_000_000_000)
      ]
    ]
  }

  /// Screenshot stand-ins drawn in code.
  static func thumbnail(_ path: String) -> NSImage? {
    if path == "chat" { return chatScreenshot() }
    // A page of text whose lines fall where the Home cover's frame ends, so
    // the crop has to find the gap above the line it would cut.
    let size = NSSize(width: 300, height: 220)
    let lines =
      path == "quote"
      ? ["车险报价对比", "甲公司：全险 4,860 元", "乙公司：全险 5,160 元", "差 300，含划痕险", "有效期至 9月30日"]
      : ["房屋租赁合同 · 第 3 页", "第七条 维修：房屋及设施", "由出租方负责维修", "第八条 押金：一个月租金", "退租时无损坏全额退还"]
    return NSImage(size: size, flipped: true) { rect in
      NSColor.white.setFill()
      rect.fill()
      for (index, line) in lines.enumerated() {
        let attributes: [NSAttributedString.Key: Any] = [
          .font: index == 0
            ? NSFont.systemFont(ofSize: 17, weight: .semibold) : NSFont.systemFont(ofSize: 15),
          .foregroundColor: index == 0 ? NSColor.black : NSColor.darkGray,
        ]
        (line as NSString).draw(
          at: NSPoint(x: 24, y: 30 + CGFloat(index) * 26), withAttributes: attributes)
      }
      return true
    }
  }

  /// A tall phone chat: a name bar on top, then bubbles, like a WeChat
  /// screenshot, so the top crop can be judged.
  static func chatScreenshot() -> NSImage {
    let size = NSSize(width: 590, height: 1_280)
    return NSImage(size: size, flipped: true) { rect in
      NSColor(white: 0.93, alpha: 1).setFill()
      rect.fill()
      NSColor(white: 0.97, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: size.width, height: 88).fill()
      let title: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black,
      ]
      ("姐姐" as NSString).draw(at: NSPoint(x: 265, y: 26), withAttributes: title)
      let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black,
      ]
      // Two-line bubbles placed so the Home cover's frame ends inside the
      // second line of the first bubble: the crop must end at a line edge.
      let bubbles: [([String], Bool)] = [
        (["妈妈的号约好了，下周二", "上午 9:30 市一医院 B 超"], false),
        (["好，我请半天假陪她去"], true), (["医保卡、就诊卡和上次的", "报告都带上"], false),
      ]
      var y: CGFloat = 170
      for (lines, mine) in bubbles {
        let width = lines.map { ($0 as NSString).size(withAttributes: body).width }.max()! + 36
        let height = CGFloat(lines.count) * 40 + 24
        let x = mine ? size.width - 96 - width : 96
        (mine ? NSColor(red: 0.58, green: 0.92, blue: 0.41, alpha: 1) : .white).setFill()
        NSBezierPath(
          roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 10, yRadius: 10
        ).fill()
        for (index, line) in lines.enumerated() {
          (line as NSString).draw(
            at: NSPoint(x: x + 18, y: y + 12 + CGFloat(index) * 40), withAttributes: body)
        }
        NSColor(red: 0.85, green: 0.55, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(
          roundedRect: NSRect(x: mine ? size.width - 80 : 16, y: y, width: 64, height: 64),
          xRadius: 8, yRadius: 8
        ).fill()
        y += height + 36
      }
      return true
    }
  }
}
