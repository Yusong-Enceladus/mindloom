import AppKit
import BestASRDomain
import BestASRMemory
import Foundation

/// A synthetic library of dropped files and a video with its keyframes, as
/// the organizing device would read them (files contract §5). Every name,
/// address and number is invented.
enum MemoryFilesFixture {
  typealias F = MemorySnapshotFixture

  static let date = F.date

  static func file(
    _ n: Int, _ filename: String, at when: Date, app: String = "访达",
    bundle: String? = "com.apple.finder", text: String = "", size: Int64, uti: String? = nil,
    pages: Int? = nil
  ) -> MemoryItemRecord {
    var record = MemoryItemRecord(
      sessionID: F.sid(n), inputMode: .userItem, itemKind: .file, title: filename,
      startedAt: when, updatedAt: when, sourceBundleID: bundle, sourceDisplayName: app,
      sourceIdentifier: filename, text: text, pageCount: pages)
    record.fileSizeBytes = size
    record.uniformType = uti
    return record
  }

  static var records: [MemoryItemRecord] {
    var recording = MemoryItemRecord(
      sessionID: F.sid(40), inputMode: .importedMedia, itemKind: nil, title: "产品演示录像.mov",
      startedAt: date(9, 24, 15, 0), updatedAt: date(9, 24, 15, 20), sourceBundleID: nil,
      sourceDisplayName: "产品演示录像.mov", sourceIdentifier: "产品演示录像.mov",
      text: "先看首页的新布局。然后是报价单导出，一键生成 PDF。最后是移动端的签收流程。",
      segments: [
        .init(
          startMilliseconds: 0, endMilliseconds: 6_000, personID: F.pid(F.zhou),
          personName: "小周", text: "先看首页的新布局。"),
        .init(
          startMilliseconds: 6_000, endMilliseconds: 14_000, personID: F.pid(F.zhou),
          personName: "小周", text: "然后是报价单导出，一键生成 PDF。"),
        .init(
          startMilliseconds: 14_000, endMilliseconds: 30_000, personID: F.pid(F.chen),
          personName: "陈医生", text: "最后是移动端的签收流程。"),
      ],
      people: [.init(id: F.pid(F.zhou), name: "小周"), .init(id: F.pid(F.chen), name: "陈医生")],
      durationNanoseconds: 312_000_000_000, playbackAvailable: true)
    let stamps: [Int64] = [0, 48_000, 131_000, 247_000]
    recording.keyframes = stamps.enumerated().map { index, ms in
      MemoryItemRecord.Keyframe(
        sessionID: F.sid(41 + index), frameMilliseconds: ms, thumbnailAssetPath: "frame-\(index)")
    }
    let frames = stamps.enumerated().map { index, ms in
      var frame = MemoryItemRecord(
        sessionID: F.sid(41 + index), inputMode: .userItem, itemKind: .image,
        title: "产品演示录像.mov · \(MemoryDateText.clock(ms))",
        startedAt: date(9, 24, 15, 0).addingTimeInterval(Double(index + 1) * 0.001),
        updatedAt: date(9, 24, 15, 0), sourceBundleID: nil, sourceDisplayName: nil,
        sourceIdentifier: nil, text: "", thumbnailAssetPath: "frame-\(index)")
      frame.parentSessionID = F.sid(40)
      frame.frameMilliseconds = ms
      return frame
    }
    return [
      file(
        30, "供应商报价汇总.xlsx", at: date(9, 25, 9, 12), size: 48_213,
        uti: "org.openxmlformats.spreadsheetml.sheet"),
      file(
        31, "Re 包装盒报价.eml", at: date(9, 25, 9, 40), app: "邮件", bundle: "com.apple.mail",
        text: "From: 林经理 <lin@example.invalid>\nSubject: Re: 包装盒报价", size: 186_402),
      file(
        32, "新品发布会.pptx", at: date(9, 25, 10, 5), app: "微信",
        bundle: "com.tencent.xinWeChat", size: 8_604_117),
      file(
        33, "盖章合同-扫描件.pdf", at: date(9, 25, 11, 30), size: 2_313_778, pages: 3),
      file(34, "样品照片与规格.zip", at: date(9, 25, 11, 42), size: 5_210_004),
      file(35, "付款明细-有密码.pdf", at: date(9, 25, 14, 3), size: 91_320),
      file(
        36, "全年订单明细.parquet", at: date(9, 25, 14, 20), size: 41_943_040,
        uti: "public.data"),
      file(
        37, "验收标准 v2.docx", at: date(9, 25, 15, 1),
        text: "验收标准 v2\n一、外观：无划痕、无色差。\n二、尺寸误差不超过 0.5 mm。", size: 23_811),
      file(
        38, "供应商评审会.ics", at: date(9, 25, 16, 10), app: "日历",
        bundle: "com.apple.iCal", text: "BEGIN:VCALENDAR", size: 812),
      file(39, "林经理.vcf", at: date(9, 25, 16, 22), text: "BEGIN:VCARD", size: 402),
      recording,
    ] + frames
  }

  static let readings: [String: String] = [
    F.item(30): """
      ## 报价（第 1 页）
      | 供应商 | 单价（元） | 起订量 | 交期 |
      | --- | --- | --- | --- |
      | 甲包装 | 3.20 | 5,000 | 15 天 |
      | 乙印务 | 2.95 | 10,000 | 20 天 |
      | 丙纸品 | 3.05 | 3,000 | 12 天 |
      ## 运费（第 2 页）
      | 供应商 | 运费 |
      | --- | --- |
      | 甲包装 | 包邮 |
      | 乙印务 | 800 |
      | 丙纸品 | 300 |
      """,
    F.item(31): """
      陈姐你好，
      附件是按新尺寸重新算的报价，5,000 起订单价 3.20 元，10 月 8 日前确认可以排 15 天交期。
      样品照片也一并附上。
      林经理
      """,
    F.item(32): """
      第 1 页：新品发布会 · 10 月 18 日
      第 2 页：三款新包装，环保纸材
      第 3 页：定价与渠道
      第 4 页：现场流程与分工
      """,
    F.item(33): """
      第 1 页：采购合同，甲方：虚构贸易有限公司，乙方：甲包装
      第 2 页：数量 5,000 个，单价 3.20 元，合计 16,000 元
      第 3 页：交货日期 2026 年 10 月 25 日；双方盖章
      """,
    F.item(34): "压缩包里有 4 个文件：3 张样品照片和 1 份规格说明。",
    F.item(38): "供应商评审会，9 月 30 日 14:00，三楼会议室。",
    F.item(39): "林经理，甲包装销售经理。",
  ]

  static let summaries: [String: String] = [
    F.item(30): "三家包装报价：乙印务单价最低但起订量 1 万",
    F.item(31): "林经理发来新报价：3.20 元/个，10 月 8 日前确认",
    F.item(32): "发布会 10 月 18 日，三款新包装的定价与流程",
    F.item(33): "与甲包装的采购合同：5,000 个，合计 16,000 元",
    F.item(34): "样品照片与规格说明",
    F.item(38): "9 月 30 日 14:00 供应商评审会",
    F.item(39): "甲包装 林经理的联系方式",
  ]

  static let facts: [String: RemoteOrganizerReadingFacts] = [
    F.item(30): .init(type: "spreadsheet", counts: ["sheets": 2], source: "file-read"),
    F.item(31): .init(
      type: "email",
      fields: [
        .init(name: "from", value: "林经理 <lin@example.invalid>"),
        .init(name: "to", value: "陈姐 <chen@example.invalid>"),
        .init(name: "subject", value: "Re: 包装盒报价"),
        .init(name: "date", value: "2026-09-25 09:31"),
      ],
      counts: ["attachments": 2],
      attachments: [
        .init(filename: "报价单-新尺寸.xlsx", type: "spreadsheet", summary: "3 档起订量的单价"),
        .init(filename: "样品正面.jpg", type: "image", summary: "白色哑光盒，烫金标志"),
      ], source: "file-read"),
    F.item(32): .init(
      type: "slides", counts: ["slides": 4, "images_read": 3], source: "file-read"),
    F.item(33): .init(
      type: "scanned_pdf", counts: ["pages": 3, "images_read": 3], source: "file-read"),
    F.item(34): .init(
      type: "archive", counts: ["entries": 4],
      attachments: [
        .init(filename: "样品/正面.jpg", type: "image", summary: "白色哑光盒正面"),
        .init(filename: "样品/侧面.jpg", type: "image", summary: "侧面烫金条"),
        .init(filename: "样品/内衬.jpg", type: "image", summary: "纸浆内衬"),
        .init(filename: "规格说明.docx", type: "document", summary: "尺寸 20×15×8 cm"),
      ], source: "file-read"),
    F.item(35): .init(type: "pdf", error: "encrypted", source: "file-read"),
    F.item(38): .init(
      type: "calendar",
      fields: [
        .init(name: "title", value: "供应商评审会"),
        .init(name: "start", value: "2026-09-30 14:00"),
        .init(name: "end", value: "2026-09-30 15:30"),
        .init(name: "location", value: "三楼会议室"),
      ], source: "file-read"),
    F.item(39): .init(
      type: "contact",
      fields: [
        .init(name: "name", value: "林经理"), .init(name: "org", value: "甲包装"),
        .init(name: "phone", value: "+86 000 0000 0000"),
        .init(name: "email", value: "lin@example.invalid"),
      ], source: "file-read"),
  ]

  static var remote: RemoteOrganizerProjection {
    let base = F.remote(questions: false)
    func event(_ id: String, _ title: String, _ status: String, _ items: [Int], people: [String])
      -> RemoteOrganizerEvent
    {
      F.event(id, title, status: status, items: items, people: people, importance: 0.95)
    }
    let events = [
      event(
        "ev-supplier", "包装供应商选定", "甲包装合同已盖章，10 月 8 日前确认新报价",
        [30, 31, 32, 33, 34, 35, 36, 37, 38, 39], people: [F.chen]),
      event(
        "ev-demo", "产品演示录像", "首页新布局、报价单导出、移动端签收", [40, 41, 42, 43, 44],
        people: [F.zhou, F.chen]),
    ]
    var readings = base.readings
    var summaries = base.readingSummaries
    for (key, value) in Self.readings { readings[key] = value }
    for (key, value) in Self.summaries { summaries[key] = value }
    return RemoteOrganizerProjection(
      cursor: 12, events: events + base.events, questions: [], persons: base.persons,
      unfiled: base.unfiled, readings: readings, readingSummaries: summaries,
      readingFacts: facts)
  }

  static var projection: MemoryProjection {
    MemoryProjection(
      remote: remote, records: F.records + records, now: F.now, ownerPersonIDs: [F.me])
  }

  /// Slides drawn in code, standing in for the video's frames.
  static func thumbnail(_ path: String) -> NSImage? {
    guard path.hasPrefix("frame-"), let index = Int(path.dropFirst(6)) else {
      return F.thumbnail(path)
    }
    let titles = ["新品发布会", "首页 · 新布局", "报价单导出", "移动端签收"]
    let colors: [NSColor] = [
      NSColor(red: 0.16, green: 0.23, blue: 0.40, alpha: 1),
      NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1),
      NSColor(red: 0.90, green: 0.96, blue: 0.91, alpha: 1),
      NSColor(red: 0.99, green: 0.93, blue: 0.87, alpha: 1),
    ]
    let size = NSSize(width: 480, height: 270)
    return NSImage(size: size, flipped: true) { rect in
      colors[index % colors.count].setFill()
      rect.fill()
      let dark = index == 0
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 38, weight: .semibold),
        .foregroundColor: dark ? NSColor.white : NSColor.black,
      ]
      (titles[index % titles.count] as NSString).draw(
        at: NSPoint(x: 40, y: 100), withAttributes: attributes)
      (dark ? NSColor.white : NSColor.gray).withAlphaComponent(0.4).setFill()
      NSRect(x: 40, y: 170, width: 300, height: 14).fill()
      NSRect(x: 40, y: 196, width: 220, height: 14).fill()
      return true
    }
  }
}
