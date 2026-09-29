import AppKit
import BestASRDomain
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An invented, ordinary week (Thursday 2026-09-24 to Saturday 09-26, UTC+8)
/// of one invented person, 林晓. Every name, number, place and message is
/// fabricated. Three matters (renewing a lease, the mother's checkup, a
/// quarterly work report), one item with the report's people about something
/// else (a team dinner), and one unrelated item.
enum SyntheticWeek {
  static let zone = TimeZone(secondsFromGMT: 8 * 3_600)!

  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }

  static func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
  }

  enum Matter: String, CaseIterable, Codable, Sendable {
    case lease
    case checkup
    case report
    /// Same people as the report, a different matter.
    case decoy
    case noise
  }

  struct App: Sendable {
    let bundleID: String
    let name: String

    var source: ItemSourceApplication { ItemSourceApplication(bundleID: bundleID, name: name)! }

    static let weChat = App(bundleID: "com.tencent.xinWeChat", name: "微信")
    static let weCom = App(bundleID: "com.tencent.WeWorkMac", name: "企业微信")
    static let claude = App(bundleID: "com.anthropic.claudefordesktop", name: "Claude")
    static let notes = App(bundleID: "com.apple.Notes", name: "备忘录")
    static let safari = App(bundleID: "com.apple.Safari", name: "Safari")
    static let finder = App(bundleID: "com.apple.finder", name: "访达")
  }

  struct Bubble: Sendable {
    let fromMe: Bool
    let sender: String
    let text: String
  }

  enum Content: Sendable {
    /// Copied text, pasted into bestASR.
    case pastedText(String)
    /// A chat screenshot, pasted as PNG data.
    case pastedScreenshot(title: String, clock: String, bubbles: [Bubble])
    /// A PDF file dropped from Finder.
    case droppedPDF(filename: String, lines: [String])

    var kind: String {
      switch self {
      case .pastedText: "text"
      case .pastedScreenshot: "screenshot"
      case .droppedPDF: "pdf"
      }
    }
  }

  struct Item: Sendable {
    let label: String
    let matter: Matter
    let app: App
    let capturedAt: Date
    let content: Content
  }

  /// In capture order.
  static let items: [Item] = [
    Item(
      label: "checkup-chat-1", matter: .checkup, app: .weChat, capturedAt: at(24, 8, 5),
      content: .pastedText(
        """
        妈妈：体检报告出来了，医生说甲状腺结节要复查，让下周去医院做个B超。
        我：妈你别担心，我在市一医院公众号上帮你挂号。
        """)),
    Item(
      label: "lease-chat-1", matter: .lease, app: .weChat, capturedAt: at(24, 9, 12),
      content: .pastedText(
        """
        陈阿姨：小林，你租的那套房子10月31号到期，续签的话房租每月涨200，从4000涨到4200，你考虑一下。
        我：陈阿姨好，我想再续一年，涨200能不能再商量一下？
        """)),
    Item(
      label: "report-chat-1", matter: .report, app: .weCom, capturedAt: at(24, 14, 5),
      content: .pastedText(
        """
        周经理：林晓，Q3运营数据汇报定在下周一上午10点，PPT周日晚上前发我。
        我：好的周经理，我今天先把用户增长那部分数据拉出来。
        """)),
    Item(
      label: "checkup-screenshot", matter: .checkup, app: .weChat, capturedAt: at(24, 19, 30),
      content: .pastedScreenshot(
        title: "姐姐", clock: "9月24日 19:28",
        bubbles: [
          Bubble(fromMe: true, sender: "我", text: "妈妈的B超约好了，下周二上午9点半，市一医院超声科。"),
          Bubble(fromMe: false, sender: "姐姐", text: "好，我那天请假陪妈去。就诊卡在妈那吧？"),
          Bubble(fromMe: true, sender: "我", text: "在她那，我提醒她带上。"),
        ])),
    Item(
      label: "noise-weather", matter: .noise, app: .safari, capturedAt: at(24, 21, 40),
      content: .pastedText("天气预报：本周末多云转晴，气温18到26度，空气质量良。")),
    Item(
      label: "decoy-team-dinner", matter: .decoy, app: .weCom, capturedAt: at(25, 11, 20),
      content: .pastedText(
        """
        周经理：下周五晚上部门团建聚餐，小刘负责订餐厅，大家周三前把忌口告诉小刘。
        小刘：好的，我先订了公司对面那家湘菜馆，8个人的包间。
        """)),
    Item(
      label: "report-chat-2", matter: .report, app: .weCom, capturedAt: at(25, 16, 30),
      content: .pastedText(
        "小刘：林晓，渠道转化率的表我更新好了，放在共享盘“Q3汇报”文件夹里，第7页的图你再看看要不要调整。")),
    Item(
      label: "lease-screenshot", matter: .lease, app: .weChat, capturedAt: at(25, 19, 40),
      content: .pastedScreenshot(
        title: "陈阿姨", clock: "9月25日 19:36",
        bubbles: [
          Bubble(fromMe: false, sender: "陈阿姨", text: "小林，我跟家里商量了，最多涨150，每月4150，押金不变。"),
          Bubble(fromMe: true, sender: "我", text: "谢谢陈阿姨！那就按4150续一年。"),
          Bubble(fromMe: false, sender: "陈阿姨", text: "那周六下午三点你过来签合同，带上身份证。"),
          Bubble(fromMe: true, sender: "我", text: "好的，周六下午三点见。"),
        ])),
    Item(
      label: "checkup-note", matter: .checkup, app: .notes, capturedAt: at(25, 21, 5),
      content: .pastedText(
        "周二陪妈妈复查：带医保卡、就诊卡和上次的体检报告；B超不用空腹；9点20前到市一医院门诊楼三楼超声科。")),
    Item(
      label: "lease-contract-pdf", matter: .lease, app: .finder, capturedAt: at(26, 9, 5),
      content: .droppedPDF(
        filename: "续租合同草案.pdf",
        lines: [
          "房屋续租合同（草案）",
          "甲方（出租人）：陈美华",
          "乙方（承租人）：林晓",
          "租期：2026年11月1日至2027年10月31日",
          "月租金：人民币4150元",
          "押金：人民币8000元，原合同押金直接转入本合同",
          "付款方式：押一付三",
          "维修：房屋及附属设施的自然损坏由甲方负责维修",
          "签约时间：2026年9月26日下午",
        ])),
    Item(
      label: "lease-claude-checklist", matter: .lease, app: .claude, capturedAt: at(26, 9, 30),
      content: .pastedText(
        """
        签续租合同前要确认的几件事：
        1. 原来8000元押金是否直接转入新合同；
        2. 热水器维修费用由谁承担；
        3. 提前退租的违约金怎么算；
        4. 涨价后的4150元是否写进第三条。
        """)),
    Item(
      label: "report-claude-outline", matter: .report, app: .claude, capturedAt: at(26, 15, 10),
      content: .pastedText(
        """
        Q3运营汇报提纲：
        一、核心指标（新增用户同比增长18%，30日留存率41%）；
        二、渠道转化分析（第7页改成按周展示）；
        三、问题与Q4计划。
        周日晚上前发给周经理。
        """)),
    Item(
      label: "lease-note-signed", matter: .lease, app: .notes, capturedAt: at(26, 16, 20),
      content: .pastedText("续租合同签好了：月租4150，押金转入新合同，热水器陈阿姨下周找师傅来修。")),
    Item(
      label: "checkup-chat-2", matter: .checkup, app: .weChat, capturedAt: at(26, 20, 10),
      content: .pastedText(
        """
        姐姐：我周二的假请好了，早上8点半到妈家接她，你直接去医院跟我们会合。
        我：好，我9点15到超声科门口。
        """)),
  ]
}

// MARK: - Rendering

enum SyntheticRendering {
  struct RenderError: Error {}

  static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size)
      ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
  }

  /// A generic phone chat screenshot: a title bar, a time stamp, grey
  /// bubbles on the left (with the sender's name) and green ones on the
  /// right. Chinese text at a size a screenshot reader can read.
  @MainActor
  static func chatScreenshotPNG(title: String, clock: String, bubbles: [SyntheticWeek.Bubble])
    throws -> Data
  {
    let width: CGFloat = 750
    let side: CGFloat = 24
    let avatar: CGFloat = 76
    let gap: CGFloat = 16
    let padding: CGFloat = 22
    let maxText: CGFloat = 440
    let textFont = font(32)
    let nameFont = font(22)
    func attributed(_ text: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
      NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
    func measure(_ string: NSAttributedString, width: CGFloat) -> CGSize {
      let rect = string.boundingRect(
        with: CGSize(width: width, height: 10_000),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
      return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
    // Layout pass.
    let barHeight: CGFloat = 110
    var y = barHeight + 30
    let clockText = attributed(clock, font(22), NSColor(white: 0.55, alpha: 1))
    let clockSize = measure(clockText, width: width)
    let clockY = y
    y += clockSize.height + 30
    struct Placed {
      let bubble: SyntheticWeek.Bubble
      let text: NSAttributedString
      let size: CGSize
      let top: CGFloat
    }
    var placed: [Placed] = []
    for bubble in bubbles {
      let text = attributed(bubble.text, textFont, NSColor(white: 0.1, alpha: 1))
      let size = measure(text, width: maxText)
      if !bubble.fromMe { y += 30 }  // sender name line
      placed.append(Placed(bubble: bubble, text: text, size: size, top: y))
      y += max(avatar, size.height + padding * 2) + 28
    }
    let height = y + 40
    let pixelWidth = Int(width)
    let pixelHeight = Int(height)
    guard
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw RenderError() }
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: barHeight).fill()
    NSColor(white: 0.85, alpha: 1).setFill()
    NSRect(x: 0, y: barHeight - 1, width: width, height: 1).fill()
    let titleText = attributed(title, font(34, bold: true), NSColor(white: 0.1, alpha: 1))
    let titleSize = measure(titleText, width: width)
    titleText.draw(
      with: NSRect(
        x: (width - titleSize.width) / 2, y: 50, width: titleSize.width + 2,
        height: titleSize.height),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    let backText = attributed("‹", font(44), NSColor(white: 0.1, alpha: 1))
    backText.draw(
      with: NSRect(x: side, y: 36, width: 40, height: 60),
      options: [.usesLineFragmentOrigin])
    clockText.draw(
      with: NSRect(
        x: (width - clockSize.width) / 2, y: clockY, width: clockSize.width + 2,
        height: clockSize.height),
      options: [.usesLineFragmentOrigin, .usesFontLeading])

    for entry in placed {
      let bubbleWidth = entry.size.width + padding * 2
      let bubbleHeight = entry.size.height + padding * 2
      let avatarX = entry.bubble.fromMe ? width - side - avatar : side
      let bubbleX =
        entry.bubble.fromMe ? avatarX - gap - bubbleWidth : side + avatar + gap
      let avatarRect = NSRect(x: avatarX, y: entry.top, width: avatar, height: avatar)
      (entry.bubble.fromMe
        ? NSColor(red: 0.36, green: 0.52, blue: 0.78, alpha: 1)
        : NSColor(red: 0.85, green: 0.55, blue: 0.35, alpha: 1)).setFill()
      NSBezierPath(roundedRect: avatarRect, xRadius: 10, yRadius: 10).fill()
      let initial = attributed(
        String(entry.bubble.sender.prefix(1)), font(34, bold: true), .white)
      let initialSize = measure(initial, width: avatar)
      initial.draw(
        with: NSRect(
          x: avatarX + (avatar - initialSize.width) / 2,
          y: entry.top + (avatar - initialSize.height) / 2, width: initialSize.width + 2,
          height: initialSize.height),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
      if !entry.bubble.fromMe {
        attributed(entry.bubble.sender, nameFont, NSColor(white: 0.5, alpha: 1)).draw(
          with: NSRect(x: bubbleX + 4, y: entry.top - 32, width: 300, height: 30),
          options: [.usesLineFragmentOrigin, .usesFontLeading])
      }
      (entry.bubble.fromMe
        ? NSColor(red: 0.58, green: 0.92, blue: 0.41, alpha: 1)
        : NSColor.white).setFill()
      NSBezierPath(
        roundedRect: NSRect(x: bubbleX, y: entry.top, width: bubbleWidth, height: bubbleHeight),
        xRadius: 12, yRadius: 12
      ).fill()
      entry.text.draw(
        with: NSRect(
          x: bubbleX + padding, y: entry.top + padding, width: entry.size.width + 2,
          height: entry.size.height + 2),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    graphics.flushGraphics()
    guard let image = context.makeImage() else { throw RenderError() }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { throw RenderError() }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError() }
    return output as Data
  }

  /// A one-page A4 PDF whose lines are real text (a text layer PDFKit reads).
  static func textPDF(title: String, lines: [String]) throws -> Data {
    let output = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let consumer = CGDataConsumer(data: output as CFMutableData),
      let context = CGContext(
        consumer: consumer, mediaBox: &box,
        [kCGPDFContextTitle as String: title] as CFDictionary)
    else { throw RenderError() }
    context.beginPDFPage(nil)
    var baseline: CGFloat = 770
    for (index, line) in lines.enumerated() {
      let size: CGFloat = index == 0 ? 20 : 14
      let ctFont = CTFontCreateWithName(
        (index == 0 ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
      let ctLine = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: line,
          attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
              CGColor(gray: 0, alpha: 1),
          ]))
      context.textPosition = CGPoint(x: index == 0 ? 200 : 60, y: baseline)
      CTLineDraw(ctLine, context)
      baseline -= index == 0 ? 44 : 28
    }
    context.endPDFPage()
    context.closePDF()
    return output as Data
  }
}
