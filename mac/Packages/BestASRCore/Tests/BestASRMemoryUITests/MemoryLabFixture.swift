import BestASRDomain
import BestASRMemory
import Foundation

/// A lab-sized synthetic library for the v7 lenses: 59 matters, 1,510 items,
/// 30 people, 27 maps, 7 ropes (one inside another), 231 crossings and one
/// blocks edge. Matter 0 is a 214-item robot experiment with two strands
/// (the second closed) and eight knots; its quotes are verbatim in its items.
/// Every name, number and sentence is invented and generated from fixed
/// lists, so the fixture is deterministic.
enum MemoryLabFixture {
  typealias F = MemorySnapshotFixture

  static let itemCount = 1_510
  static let eventCount = 59
  static let mapCount = 27
  static let crossingCount = 231
  /// The big matter's items.
  static let twinItems = 214

  /// 2026-09-20 21:00 +08:00, the library's newest item.
  static let now = F.date(9, 20, 21, 0)

  static func eventID(_ e: Int) -> String {
    String(format: "e0000000-0000-4000-8000-%012d", e)
  }
  static func ropeID(_ r: Int) -> String { String(format: "r0000000-0000-4000-8000-%012d", r) }
  static func personID(_ n: Int) -> String {
    String(format: "D0000000-0000-4000-8000-%012d", n)
  }
  static func itemNumber(_ n: Int) -> Int { 200_000 + n }
  static func item(_ n: Int) -> String { F.item(itemNumber(n)) }

  static let names = [
    "林知远", "宋雨桐", "韩策", "孟凡", "赵晴", "郑可", "许嘉", "周明澜", "白楠", "陆川",
    "江枫", "何小雨", "高原", "顾一鸣", "唐一帆", "吴桐", "马骁", "陈默", "骆星", "叶知秋",
    "程远", "方圆", "秦朗", "安然", "夏至", "黎明", "向阳", "温暖", "齐天", "罗一",
  ]

  static let titles = [
    "Twin-7叠衣服真机实验", "GripDiff参会准备", "A800集群维护", "SkillKnit论文投稿", "TES论文大修返修",
    "穹顶具身组研究实习", "梧桐苑租房续约", "博士中期考核", "CoRA新加坡差旅", "TG-2夹爪更换",
    "TG-2安装标定", "TG-2驱动适配", "萤火杯组队", "萤火杯初赛提交", "课题组团建选址",
    "本科生科研实习招募", "TouchFold数据采集", "灰狼平台抓取实验", "Workshop短文", "组会汇报",
    "报销材料整理", "机房门禁申请", "显卡借用登记", "开源代码整理", "审稿任务",
  ]

  static func title(_ e: Int) -> String {
    e < titles.count ? titles[e] : "事项\(e + 1) · " + titles[e % titles.count].prefix(4)
  }

  static let phrases = [
    "今天先把数据跑完", "明天上午再对一下", "表格我更新好了", "这版先按上次说的来", "下午三点碰一下",
    "我把结果发群里了", "周五之前要交", "预算可能要加一点", "先别动那台机器", "记得带上充电器",
  ]

  // MARK: Items

  /// Which matter each item is in: 214 in matter 0, 90 in matter 1, the
  /// rest spread over the others.
  static let assignment: [Int] = {
    var result = Array(repeating: 0, count: twinItems) + Array(repeating: 1, count: 90)
    let rest = itemCount - result.count
    for k in 0..<rest { result.append(2 + k % (eventCount - 2)) }
    return result
  }()

  /// Items of matter 0 on the open-day strand (s2) and on the experiment
  /// strand (s1); the others are on its main thread.
  static let twinDemo = Array(20..<26)
  static let twinStrand = Array(100..<166)

  static func capturedAt(item n: Int) -> Date {
    let e = assignment[n]
    if e == 0 {
      // 8/17 … 9/19, spread evenly; the open day around 9/10–9/12.
      if twinDemo.contains(n) {
        return F.date(9, 10 + (n - 20) / 2, 10 + n % 6, 0)
      }
      let day = n * 33 / twinItems
      return F.date(8, 17, 9, 0).addingTimeInterval(Double(day) * 86_400 + Double(n % 9) * 3_600)
    }
    let span = e == 1 ? 30 : 6 + e % 20
    let start = F.date(8, 20, 9, 0).addingTimeInterval(Double((e * 5) % 25) * 86_400)
    let k = n % 97
    return min(
      start.addingTimeInterval(Double((k * 13) % max(span, 1)) * 86_400 + Double(k % 8) * 3_600),
      F.date(9, 20, 20, 0))
  }

  static func text(item n: Int) -> String {
    let e = assignment[n]
    let who = names[(e * 7 + n) % names.count]
    switch (e, n) {
    case (0, 3): return "孟凡：Twin-7 刚做完标定，恢复运行了\n我：好，下午开始跑叠T恤。"
    case (0, 21): return "郑可：郑老师说咱们组只演示叠T恤哈，灰狼那个先撤了\n我：收到。"
    case (0, 25): return "赵晴：今天开放日终于搞完了，大家辛苦\n韩策：辛苦辛苦。"
    case (0, 150): return "孟凡：左臂腕电机那个温升有点大，我刚换了导热硅脂\n我：好，再观察一天。"
    case (0, 190): return "宋雨桐：T恤那组我复核完了，改成 37 个，74% 了\n我：袋子呢？\n宋雨桐：33 个成功，66% 稳了"
    case (0, 205): return "林知远：数据齐了，明天还要跑A800的baseline\n韩策：集群那边我去问。"
    case (0, 60): return "韩策：9/10之前得把数据收完，不然赶不上\n我：明白。"
    case (0, 120): return "宋雨桐：袋子成功率为什么这么低，还没想明白\n我：明天看看录像。"
    case (2, _) where n % 5 == 0:
      return "唐一帆：node7 的问题他还没修，估计得等到月底集群维护\n我：那 Twin-7 的 baseline 得等 A800 维护完再跑。"
    default:
      let topic = title(e).prefix(6)
      return "\(who)：\(topic)，\(phrases[(n + e) % phrases.count])\n我：好，收到。"
    }
  }

  static var records: [MemoryItemRecord] {
    (0..<itemCount).map { n in
      let e = assignment[n]
      let at = capturedAt(item: n)
      if n % 29 == 7 {
        return F.record(
          itemNumber(n), .dictation, at: at, app: "备忘录", bundle: "com.apple.Notes",
          text: "记一下：\(title(e).prefix(6))，\(phrases[n % phrases.count])。")
      }
      if n % 31 == 11 {
        return F.record(
          itemNumber(n), .userItem, kind: .image, at: at, app: "微信",
          bundle: "com.tencent.xinWeChat", text: "", title: "截图")
      }
      let apps: [(String, String)] = [
        ("微信", "com.tencent.xinWeChat"), ("飞书", "com.electron.lark"),
        ("Claude", "com.anthropic.claudefordesktop"),
      ]
      let (app, bundle) = apps[(n + e) % apps.count]
      return F.record(
        itemNumber(n), .userItem, kind: .text, at: at, app: app, bundle: bundle,
        text: text(item: n))
    }
  }

  static var persons: [RemoteOrganizerPerson] {
    names.enumerated().map { index, name in
      try! JSONDecoder().decode(
        RemoteOrganizerPerson.self,
        from: Data(
          #"{"person_id": "\#(personID(index))", "display_name": "\#(name)", "aliases": [], "origin": "transcript"}"#
            .utf8))
    }
  }

  // MARK: Maps, ropes, relations

  /// Matter 0's map, as the organizer draws it.
  static var twinMap: RemoteOrganizerMatterMap {
    typealias K = RemoteOrganizerMatterMap.Knot
    return RemoteOrganizerMatterMap(
      strands: [
        .init(
          id: "s1", name: "真机实验与调试", summary: "电机修好，三组数据齐，9/19 跑 A800 baseline。",
          itemIDs: twinStrand.map(item), factIDs: ["f1", "f3"]),
        .init(
          id: "s2", name: "9/12 学院开放日", summary: "方案定为叠T恤，彩排完成，9/12 正式演示。",
          itemIDs: twinDemo.map(item), state: "closed"),
      ],
      knots: [
        K(
          id: "k1", strand: "s1", kind: "progress", text: "Twin-7 电机修好恢复实验",
          date: "2026-09-01", state: "done", who: ["孟凡", "韩策"], evidence: [item(3)],
          quote: "Twin-7 刚做完标定，恢复运行了", quoteItemID: item(3)),
        K(
          id: "k8", strand: "s2", kind: "decision", text: "开放日只演示叠T恤", date: "2026-09-11",
          state: "done", who: ["郑可", "赵晴"], evidence: [item(21)],
          quote: "郑老师说咱们组只演示叠T恤哈", quoteItemID: item(21)),
        K(
          id: "k9", strand: "s2", kind: "progress", text: "9/12 开放日演示完成",
          date: "2026-09-12", state: "done", who: ["赵晴", "孟凡", "韩策"], evidence: [item(25)],
          quote: "今天开放日终于搞完了", quoteItemID: item(25)),
        K(
          id: "k6", strand: "s1", kind: "progress", text: "左臂腕电机修好", date: "2026-09-16",
          state: "done", who: ["孟凡"], evidence: [item(150)],
          quote: "左臂腕电机那个温升有点大，我刚换了导热硅脂", quoteItemID: item(150)),
        K(
          id: "k4", strand: "s1", kind: "progress", text: "T恤数据复核改为 37/50",
          date: "2026-09-18", state: "done", who: ["宋雨桐"], evidence: [item(190)],
          quote: "改成 37 个，74% 了", quoteItemID: item(190)),
        K(
          id: "k5", strand: "s1", kind: "progress", text: "袋子数据确认为 33/50",
          date: "2026-09-18", state: "done", who: ["宋雨桐"], evidence: [item(190)],
          quote: "33 个成功，66% 稳了", quoteItemID: item(190)),
        K(
          id: "k7", strand: "s1", kind: "commitment", text: "跑 A800 baseline",
          date: "2026-09-21", state: "planned", who: ["林知远"], evidence: [item(205)],
          quote: "明天还要跑A800的baseline", quoteItemID: item(205)),
        K(
          id: "k3", strand: nil, kind: "deadline", text: "折袋子数据截止 9/10", date: nil,
          state: "done", who: ["韩策"], evidence: [item(60)], quote: "9/10之前得把数据收完",
          quoteItemID: item(60)),
        K(
          id: "k2", strand: nil, kind: "question", text: "袋子成功率偏低的原因", date: nil,
          state: "open", who: ["宋雨桐"], evidence: [item(120)], quote: "袋子成功率为什么这么低",
          quoteItemID: item(120)),
      ],
      health: .init(level: "ok", reason: "数据已齐，电机修好，9/21 跑 baseline", evidence: [item(205)]),
      skillVersion: "1.1.0", updatedAt: "2026-09-20T23:49:00+08:00")
  }

  /// A small map for matter `e` (1 … 26): one or two strands, four to six
  /// knots, quotes cut from its own items.
  static func map(for e: Int, items: [Int]) -> RemoteOrganizerMatterMap {
    typealias K = RemoteOrganizerMatterMap.Knot
    let half = items.count / 2
    let strands: [RemoteOrganizerMatterMap.Strand] =
      e % 3 == 0
      ? [.init(id: "s1", name: "\(title(e).prefix(5))推进", itemIDs: items.prefix(half).map(item))]
      : [
        .init(id: "s1", name: "\(title(e).prefix(4))准备", itemIDs: items.prefix(half).map(item)),
        .init(
          id: "s2", name: "材料与沟通", itemIDs: items.suffix(from: half).prefix(4).map(item),
          state: e % 2 == 0 ? "closed" : "open"),
      ]
    var knots: [K] = []
    for (k, n) in items.prefix(6).enumerated() {
      let date = capturedAt(item: n)
      let parts = F.calendar.dateComponents([.year, .month, .day], from: date)
      let iso = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
      let words =
        text(item: n).split(separator: "：").dropFirst().first.map {
          String($0.split(separator: "\n").first ?? "")
        } ?? ""
      let kinds = ["progress", "decision", "progress", "commitment", "question", "deadline"]
      let kind = kinds[(k + e) % kinds.count]
      knots.append(
        K(
          id: "k\(k + 1)", strand: k % 3 == 2 ? nil : (k % 2 == 0 ? "s1" : strands.last!.id),
          kind: kind, text: String(words.prefix(14)), date: kind == "question" ? nil : iso,
          state: kind == "question" ? "open" : (kind == "commitment" ? "planned" : "done"),
          who: [names[(e + k) % names.count]], evidence: [item(n)],
          quote: String(words.prefix(10)), quoteItemID: item(n)))
    }
    return RemoteOrganizerMatterMap(
      strands: strands, knots: knots,
      health: .init(level: ["ok", "risk", "stuck"][e % 3], reason: "按计划推进"))
  }

  static var remote: RemoteOrganizerProjection {
    var itemsOf: [Int: [Int]] = [:]
    for (n, e) in assignment.enumerated() { itemsOf[e, default: []].append(n) }
    var events: [RemoteOrganizerEvent] = []
    for e in 0..<eventCount {
      let items = itemsOf[e] ?? []
      let people = [personID(e % names.count), personID((e * 7 + 3) % names.count)]
      var facts: [RemoteOrganizerEvent.StatusFact] = []
      if e == 0 {
        facts = [
          .init(
            text: "左臂腕电机已修好，温升正常", itemIDs: [item(150)], state: "done", date: "2026-09-16"),
          .init(text: "袋子成功率 66% 偏低", itemIDs: [item(190)], state: "info"),
          .init(
            text: "A800 集群 baseline 待跑", itemIDs: [item(205)], state: "planned",
            date: "2026-09-21"),
        ]
      } else if e % 4 == 1 {
        let day = 18 + e % 14
        let date =
          day <= 30 ? String(format: "2026-09-%02d", day) : String(format: "2026-10-%02d", day - 30)
        facts = [.init(text: "\(title(e).prefix(6))截止", itemIDs: [], state: "planned", date: date)]
      }
      let map: RemoteOrganizerMatterMap? =
        e == 0 ? twinMap : (e < mapCount ? map(for: e, items: items) : nil)
      events.append(
        RemoteOrganizerEvent(
          eventID: eventID(e), title: title(e),
          statusLine: e == 0 ? "数据已定，电机修好，9月21日跑 baseline" : phrases[e % phrases.count],
          statusFacts: facts, importance: 1 - Double(e) / Double(eventCount),
          updatedAt: "2026-09-20T10:00:00+08:00", itemIDs: items.map(item), personIDs: people,
          handle: "E\(e + 1)",
          map: map,
          facets: RemoteOrganizerFacets(
            type: e % 2 == 0 ? "实验" : "论文", rope: nil, deadline: nil,
            health: map?.health?.level)))
    }
    // Seven ropes; the last sits inside the first.
    let ropeChildren: [[Int]] = [
      [1, 3, 18], [4, 23], [0, 2], [9, 10, 11, 24], [12, 13], [14, 15], [16, 17],
    ]
    var ropes: [RemoteOrganizerRope] = []
    let ropeTitles = ["GripDiff论文", "TES论文返修", "Twin-7真机实验", "TG-2硬件调试", "萤火杯黑客松", "课题组行政", "数据采集"]
    for (r, children) in ropeChildren.prefix(7).enumerated() {
      ropes.append(
        RemoteOrganizerRope(
          id: ropeID(r), handle: "R\(r + 1)", title: ropeTitles[r],
          kind: r == 5 ? "area" : "project", parent: r == 6 ? ropeID(0) : nil,
          children: children.map(eventID), proposed: r != 2, reason: "这些事属于同一个项目",
          evidence: []))
    }
    for index in events.indices {
      if let rope = ropes.first(where: { $0.children.contains(events[index].eventID) }) {
        events[index].facets?.rope = rope.id
      }
    }
    // 231 crossings between deterministic pairs, and matter 0 waits on 2.
    var relations: [RemoteOrganizerRelation] = []
    var seen = Set<String>()
    var k = 0
    while relations.count < crossingCount {
      k += 1
      let a = (k * 7) % eventCount
      let b = (k * 13 + k / eventCount) % eventCount
      guard a != b, seen.insert("\(min(a, b))-\(max(a, b))").inserted else { continue }
      let shared = (itemsOf[a] ?? []).prefix(2) + (itemsOf[b] ?? []).prefix(1)
      relations.append(
        RemoteOrganizerRelation(
          kind: "cross", a: eventID(a), b: eventID(b), count: 1 + (k * 5) % 37,
          itemIDs: shared.map(item)))
    }
    relations.append(
      RemoteOrganizerRelation(
        kind: "blocks", a: eventID(2), b: eventID(0),
        quote: "那 Twin-7 的 baseline 得等 A800 维护完再跑",
        itemID: item(itemsOf[2]!.first { $0 % 5 == 0 }!),
        proposed: true, sourceEvent: eventID(0)))
    return RemoteOrganizerProjection(
      cursor: 25_600, events: events, questions: [], persons: persons, ropes: ropes,
      relations: relations)
  }

  static var projection: MemoryProjection {
    MemoryProjection(remote: remote, records: records, now: now)
  }

  /// The same library without anything v7 (no maps, facets, ropes or
  /// relations): Home as it was, for the performance comparison.
  static var projectionWithoutV7: MemoryProjection {
    let full = remote
    let events = full.events.map { event -> RemoteOrganizerEvent in
      var event = event
      event.map = nil
      event.facets = nil
      return event
    }
    return MemoryProjection(
      remote: RemoteOrganizerProjection(
        cursor: full.cursor, events: events, questions: [], persons: full.persons),
      records: records, now: now)
  }
}
