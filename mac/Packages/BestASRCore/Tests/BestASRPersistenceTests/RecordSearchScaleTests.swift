import BestASRDictation
import BestASRDomain
import BestASRMemory
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// v12 find (ALIGNMENT 查-5, B4 §4.1): the first screen of a search or of the
/// history at 6,000 and 20,000 records stays within 150 ms on this Mac.
///
/// The library is synthetic (`SyntheticLibrary`, a fixed seed): never the
/// user's. "First screen" is what the page waits for: reading the query, the
/// one MATCH (or the time-ordered page), and the 50 rows' records.
final class RecordSearchScaleTests: XCTestCase {
  static let budget: TimeInterval = 0.150

  func testFirstScreenAt6kRecords() async throws {
    try await measureFirstScreen(records: 6_000)
  }

  func testFirstScreenAt20kRecords() async throws {
    try await measureFirstScreen(records: 20_000)
  }

  private func measureFirstScreen(records: Int) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("record-search-scale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    do { _ = try GRDBDictationStore(databaseURL: url) }  // the schema
    var started = Date()
    let library = try SyntheticLibrary.generate(records: records, into: url, seed: 7)
    let generated = Date().timeIntervalSince(started)
    let store = try GRDBDictationStore(databaseURL: url)
    started = Date()
    let sync = try await store.syncRecordSearchIndex()
    let indexing = Date().timeIntervalSince(started)
    XCTAssertEqual(sync.indexed, records)
    started = Date()
    var tokens = 0
    for text in library.texts { tokens += SearchText.indexTokens(text).body.count }
    let tokenizing = Date().timeIntervalSince(started)

    let context = SearchContext(
      people: library.people, ownerNames: ["林知远"],
      lexicon: [SearchLexiconEntry(canonical: "GripDiff", spoken: ["格瑞普迪夫"])],
      sourceNames: ["微信", "腾讯会议", "邮件", "Fn 口述"], clock: SearchClock(now: library.now))
    let typical = [
      "", "实验", "论文 返修", "GripDiff", "grip diff", "穹鼎", "上周", "微信", "上周 微信 报价",
      library.people[3].name, "\(library.people[5].name) 实习", "格瑞普迪夫", "9月", "数据集 标注 进度",
    ]
    var report: [String] = []
    for text in typical {
      var times: [TimeInterval] = []
      var searchTimes: [TimeInterval] = []
      var shown = 0
      for run in 0..<6 {
        let start = Date()
        let query = SearchQueryParser.parse(text, context: context)
        let page = try await store.searchRecords(query, limit: 50, now: library.now)
        let searched = Date().timeIntervalSince(start)
        let rows = try await store.memoryItemRecords(ids: page.hits.map(\.sessionID))
        let elapsed = Date().timeIntervalSince(start)
        if run > 0 {  // the first run warms the caches
          times.append(elapsed)
          searchTimes.append(searched)
        }
        shown = rows.count
      }
      times.sort()
      searchTimes.sort()
      let median = times[times.count / 2]
      report.append(
        "「\(text)」 median \(Int(median * 1000)) ms (search \(Int(searchTimes[searchTimes.count / 2] * 1000)) ms), "
          + "max \(Int(times.last! * 1000)) ms, \(shown) rows")
      XCTAssertLessThanOrEqual(
        median, Self.budget, "first screen for 「\(text)」 at \(records) records: \(median) s")
    }
    print(
      "record search at \(records): generated \(String(format: "%.1f", generated)) s, "
        + "indexed \(String(format: "%.1f", indexing)) s (tokenizing alone "
        + "\(String(format: "%.1f", tokenizing)) s, \(tokens) chars)\n  "
        + report.joined(separator: "\n  "))
  }
}

/// A synthetic library for scale checks: realistic shapes (chats, dictation,
/// meetings, mails; Chinese with English terms; people; two years of days),
/// invented words only. Rows are written as `createUserItem` and the Typeless
/// import write them, in one transaction.
enum SyntheticLibrary {
  struct Result {
    let people: [SearchPerson]
    let now: Date
    let texts: [String]
  }

  static let words = [
    "实验", "论文", "返修", "数据集", "标注", "进度", "导师", "组会", "报价", "合同", "预算", "采购", "服务器",
    "显卡", "训练", "推理", "部署", "测试", "评审", "截止", "提交", "补充", "材料", "代码", "仓库", "版本",
    "会议", "纪要", "安排", "时间", "地点", "实习", "面试", "入职", "简历", "推荐信", "签证", "机票", "酒店",
    "报销", "发票", "房租", "续租", "房东", "搬家", "体检", "医院", "快递", "课程", "作业", "考试", "成绩",
    "答辩", "海报", "视频", "演示", "比赛", "队友", "分工", "需求", "设计", "原型", "接口", "文档", "日志",
    "机器人", "机械臂", "抓取", "叠衣服", "仿真", "真机", "相机", "标定", "传感器", "电机", "电池", "充电",
    "穹顶", "具身", "智能", "模型", "参数", "消融", "基线", "指标", "曲线", "图表", "表格", "附录", "引用",
    "周报", "月报", "计划", "风险", "问题", "方案", "结论", "反馈", "意见", "修改", "确认", "取消", "推迟",
  ]
  static let fillers = ["我们", "今天", "明天", "然后", "已经", "先", "再", "需要", "可以", "这个", "那边", "还是"]
  static let terms = [
    "GripDiff", "TouchFold", "RoboPrior", "SkillKnit", "Twin-7", "PyTorch", "CUDA", "LaTeX",
    "Overleaf",
    "GitHub", "NC27-4471", "AoE", "baseline", "rebuttal", "checkpoint", "dataset", "PR", "OKR",
  ]
  static let surnames = Array(
    "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾萧田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤"
  )
  static let given = Array("思成雨桐嘉禾子涵浩然欣怡宇轩梓萱博文诗涵俊杰佳琪天宇静怡明轩晓彤一鸣若曦致远书瑶")
  static let sources: [(String, Double)] = [
    ("微信", 0.30), ("iPhone 键盘", 0.18), ("Fn 口述", 0.12), ("邮件", 0.10), ("腾讯会议", 0.08),
    ("企业微信", 0.06), ("Claude", 0.05), ("飞书", 0.04), ("Codex", 0.03), ("网页", 0.02),
    ("Typeless", 0.02),
  ]

  struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
  }

  static func generate(records: Int, into url: URL, seed: UInt64) throws -> Result {
    var random = Generator(state: seed)
    var people: [SearchPerson] = []
    for index in 0..<40 {
      let name =
        String(surnames[index % surnames.count]) + String(given[(index * 2) % given.count])
        + String(given[(index * 2 + 1) % given.count])
      people.append(
        SearchPerson(id: "p\(index)", name: name, aliases: [String(name.first!) + "老师"]))
    }
    let now = Date(timeIntervalSince1970: 1_791_100_000)  // 2026-10-04
    let span: TimeInterval = 2 * 365 * 86_400
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var texts: [String] = []
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      for _ in 0..<records {
        let id = UUID().uuidString
        let at = now.timeIntervalSince1970 - span * pow(random.unit(), 1.6)
        var pick = random.unit()
        var source = sources[0].0
        for (name, weight) in sources {
          if pick < weight {
            source = name
            break
          }
          pick -= weight
        }
        var parts: [String] = []
        let length = 6 + random.int(30)
        for _ in 0..<length {
          let roll = random.int(100)
          if roll < 62 {
            parts.append(words[random.int(words.count)])
          } else if roll < 80 {
            parts.append(fillers[random.int(fillers.count)])
          } else if roll < 90 {
            parts.append(terms[random.int(terms.count)])
          } else {
            parts.append(people[random.int(people.count)].name)
          }
          if random.int(7) == 0 { parts.append(["，", "。", "；", " "][random.int(4)]) }
        }
        let text = parts.joined()
        texts.append(text)
        let dictation = source == "Typeless"
        let snapshot = try encoder.encode(
          DictationSessionSnapshot(
            sessionID: SessionID(UUID(uuidString: id)!), revision: 1, phase: .completed))
        try db.execute(
          sql: """
            INSERT INTO sessions (id, revision, input_mode, state, source_audio_retention, created_at, updated_at)
            VALUES (?, 1, ?, 'completed', 'retainedUntilExplicitDeletion', ?, ?)
            """, arguments: [id, dictation ? "dictation" : "userItem", at, at])
        try db.execute(
          sql: """
            INSERT INTO session_metadata (session_id, revision, title, title_is_user_edited, source_kind,
              source_identifier, source_display_name, source_bundle_id, recording_format, created_at, updated_at)
            VALUES (?, 1, ?, 0, ?, NULL, ?, NULL, 'text/plain', ?, ?)
            """,
          arguments: [
            id, String(text.prefix(20)), dictation ? "typeless-import" : "userItem", source, at, at,
          ])
        try db.execute(
          sql: """
            INSERT INTO dictation_snapshots (session_id, control_revision, phase, snapshot_json, is_ephemeral, updated_at)
            VALUES (?, 1, 'completed', ?, 0, ?)
            """, arguments: [id, snapshot, at])
        try db.execute(
          sql: """
            INSERT INTO transcript_revisions (id, session_id, revision, parent_id, kind, content,
              model_artifact_id, config_hash, created_at, language_hints_json)
            VALUES (?, ?, 1, NULL, 'final', ?, NULL, NULL, ?, ?)
            """, arguments: [UUID().uuidString, id, text, at, Data("[]".utf8)])
        if !dictation {
          try db.execute(
            sql: """
              INSERT INTO user_item_details (session_id, revision, item_kind, captured_at, source_origin,
                extractor, created_at, updated_at)
              VALUES (?, 1, 'text', ?, 'previousFrontmost', 'pasteboard-text-v1', ?, ?)
              """, arguments: [id, at, at, at])
        }
      }
    }
    try queue.close()
    return Result(people: people, now: now, texts: texts)
  }
}
