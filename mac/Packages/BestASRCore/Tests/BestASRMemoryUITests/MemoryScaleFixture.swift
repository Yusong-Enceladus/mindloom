import BestASRDomain
import BestASRMemory
import Foundation

/// A large synthetic library for the scale snapshots: 60 events, 2000
/// items, 30 people, and one Tencent Meeting export the organizer split
/// over three events. Every name, place and sentence is invented; the text
/// is generated from fixed word lists, so it is deterministic.
enum MemoryScaleFixture {
  typealias F = MemorySnapshotFixture

  static let itemCount = 2_000
  /// The last dozen items are in no event (Unfiled).
  static let unfiledCount = 12
  static var filedCount: Int { itemCount - unfiledCount }
  static let eventCount = 60
  static let meetingItem = 1_000_000

  /// A weekly meeting that covered three matters, exported from 腾讯会议.
  static let meeting = """
    工作室周会（虚构）
    2026年9月25日 14:00

    苗青禾 Miao QINGHE(00:00:04):
    先说秋季市集。摊位确认在东门第三排，周六早上七点进场。

    欧阳帆(00:01:10):
    招牌我改成竖版了，周四前打样。易拉宝要两个吗？

    苗青禾 Miao QINGHE(00:02:02):
    两个，一个放摊位里面。价签也一起印。

    欧阳帆(00:03:15):
    第二件，仓库十月中搬到二楼，货架要重新量。

    石小满(00:04:01):
    我周三去量，顺便把要扔的旧箱子列个单子。

    欧阳帆(00:05:30):
    最后，新同事贝贝下周一入职，电脑和工牌还没申请。

    苗青禾 Miao QINGHE(00:06:12):
    我今天把申请提了，周一上午我带她熟悉一下流程。
    """

  static var meetingTurns: [MemoryTranscriptText.Turn] {
    MemoryTranscriptText.parse(meeting)!.turns
  }

  static let topics = [
    "秋季市集摆摊", "仓库搬到二楼", "新同事入职", "租房续约", "妈妈复查", "季度汇报", "周末露营",
    "车险续保", "新家宽带", "猫咪疫苗", "驾照换证", "牙科复诊", "年会节目", "报税材料", "旧手机回收",
    "阳台漏水", "护照续签", "老同学聚会", "健身卡转让", "装修报价", "孩子入学", "婚礼伴郎",
    "二手相机", "公司团建", "出差报销", "书房改造", "国庆回家", "体检预约", "咖啡机维修", "邻居快递",
    "吉他课", "搬家公司", "信用卡年费", "社保转移", "外婆生日", "植物换盆", "打印机墨盒", "网站续费",
    "论文投稿", "摄影展", "志愿活动", "家长会", "洗衣机安装", "奶茶店选址", "读书会", "马拉松报名",
    "电脑升级", "朋友借款", "保险理赔", "小区停车", "发票抬头", "宠物寄养", "滑雪行程", "油画课",
    "物业费", "新年礼物", "菜园排班", "乐队排练", "展会物料", "客户回访",
  ]

  static let names = [
    "苗青禾", "欧阳帆", "石小满", "贝贝", "韩溪", "顾一鸣", "林青", "周野", "唐果", "宋知远",
    "何小雨", "陆川", "叶子", "孟星", "白露", "程远", "方圆", "江枫", "罗一", "夏至",
    "秦朗", "安然", "许诺", "柯南星", "郑重", "温暖", "齐天", "简单", "黎明", "向阳",
  ]

  static func personID(_ n: Int) -> String { String(format: "C0000000-0000-4000-8000-%012d", n) }

  static let apps: [(String, String)] = [
    ("微信", "com.tencent.xinWeChat"), ("飞书", "com.electron.lark"),
    ("备忘录", "com.apple.Notes"), ("Claude", "com.anthropic.claudefordesktop"),
    ("企业微信", "com.tencent.WeWorkMac"),
  ]

  static let phrases = [
    "这周能定下来吗", "我先问一下价格", "明天上午给你答复", "表格我更新好了", "照片发群里了",
    "周五之前要交", "地址我再发一遍", "预算可能要加一点", "先按上次说的来", "记得带上收据",
  ]

  /// Which event each filed item is in, in item order: the three events
  /// sharing the meeting hold four chats each, the rest share the others.
  static var assignment: [Int] {
    var result: [Int] = []
    for e in 0..<3 { result += Array(repeating: e, count: 4) }
    let rest = filedCount - result.count
    for k in 0..<rest { result.append(3 + k % (eventCount - 3)) }
    return result
  }

  /// When item `n` (the `k`-th of event `e`) was taken in: each event's
  /// items within a few days, the events spread over September.
  static func capturedAt(event e: Int, k: Int) -> Date {
    if e < 3 {
      // Around the meeting on 9月25日 14:00: two before, two after.
      let offsets: [Double] = [-30, -6, 4, 26]
      return F.date(9, 25, 14, 0).addingTimeInterval(offsets[k] * 3_600 + Double(e) * 600)
    }
    let day = 1 + (e * 7) % 24
    return F.date(9, day, 8, 0).addingTimeInterval(Double(k) * 2.4 * 3_600)
  }

  /// Every forty-third item is a screenshot; the rest are chats.
  static var records: [MemoryItemRecord] {
    var result: [MemoryItemRecord] = []
    var seen: [Int: Int] = [:]
    let events = assignment
    for n in 0..<itemCount {
      let e = n < filedCount ? events[n] : eventCount + n
      let k = seen[e, default: 0]
      seen[e] = k + 1
      let at =
        n < filedCount
        ? capturedAt(event: e, k: k) : F.date(9, 26, 9, 0).addingTimeInterval(Double(n) * 60)
      let (app, bundle) = apps[(n + k) % apps.count]
      let who = names[(e * 5 + k * 3) % names.count]
      if n % 43 == 5 {
        result.append(
          F.record(
            n + 100, .userItem, kind: .image, at: at, app: app, bundle: bundle, text: "",
            title: "截图", thumbnail: n % 2 == 0 ? "chat" : "quote"))
      } else {
        let topic = topics[e % topics.count]
        result.append(
          F.record(
            n + 100, .userItem, kind: .text, at: at, app: app, bundle: bundle,
            text: "\(who)：\(topic)，\(phrases[(k + e) % phrases.count])。\n我：好，收到。"))
      }
    }
    result.append(
      MemoryItemRecord(
        sessionID: F.sid(meetingItem), inputMode: .userItem, itemKind: .document,
        title: "工作室周会.txt", startedAt: F.date(9, 25, 14, 0), updatedAt: F.date(9, 25, 15, 0),
        sourceBundleID: "com.tencent.meeting", sourceDisplayName: "腾讯会议",
        sourceIdentifier: "工作室周会.txt", text: meeting))
    return result
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

  static var remote: RemoteOrganizerProjection {
    let turns = meetingTurns
    let meetingID = F.item(meetingItem)
    // Parts: the market (turns 0–2), the storeroom (3–4), onboarding (5–6).
    let parts = [
      RemoteOrganizerEvent.Segment(
        itemID: meetingID, segID: "s1", start: turns[0].start, end: turns[2].end, gist: "市集摊位和招牌"),
      RemoteOrganizerEvent.Segment(
        itemID: meetingID, segID: "s2", start: turns[3].start, end: turns[4].end, gist: "仓库搬家量货架"),
      RemoteOrganizerEvent.Segment(
        itemID: meetingID, segID: "s3", start: turns[5].start, end: turns[6].end, gist: "新同事入职准备"),
    ]
    let statuses = [
      "周六七点进场，招牌周四打样", "周三量货架，十月中搬", "周一入职，电脑和工牌已申请",
    ]
    // The next dated step of the three matters the meeting moved.
    let next: [(String, String)] = [
      ("招牌打样", "2026-10-01"), ("去量货架", "2026-09-30"), ("贝贝入职", "2026-09-28"),
    ]
    var events: [RemoteOrganizerEvent] = []
    for e in 0..<eventCount {
      var items = assignment.enumerated().filter { $0.element == e }.map { F.item($0.offset + 100) }
      var segments: [RemoteOrganizerEvent.Segment] = []
      if e < 3 {
        items.append(meetingID)
        segments = [parts[e]]
      }
      let people = [personID(e % names.count), personID((e * 11 + 3) % names.count)]
      events.append(
        RemoteOrganizerEvent(
          eventID: "ev-\(e)", title: topics[e],
          statusLine: e < 3 ? statuses[e] : "\(phrases[e % phrases.count])",
          statusFacts: e < 3
            ? [.init(text: next[e].0, itemIDs: [meetingID], state: "planned", date: next[e].1)]
            : [],
          importance: 1 - Double(e) / Double(eventCount),
          updatedAt: String(format: "2026-09-%02dT10:00:00+08:00", 28 - e % 27),
          itemIDs: items, personIDs: people, handle: "E\(e + 1)", anchor: topics[e],
          segments: segments))
    }
    return RemoteOrganizerProjection(
      cursor: 99, events: events, questions: [], persons: persons,
      unfiled: (filedCount..<itemCount).map {
        RemoteOrganizerUnfiledItem(itemID: F.item(100 + $0), reason: "none")
      })
  }

  static var projection: MemoryProjection {
    MemoryProjection(remote: remote, records: records, now: F.now)
  }
}
