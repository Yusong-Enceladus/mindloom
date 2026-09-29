import BestASRDomain
import Foundation

/// The organizing device's reading of a file item, split for display: its
/// one-line summary, what it read, and the file facts it sent.
public struct MemoryFileReading: Equatable, Sendable {
  public let summary: String?
  public let text: String
  public let facts: RemoteOrganizerReadingFacts?

  public init(summary: String?, text: String, facts: RemoteOrganizerReadingFacts?) {
    self.summary = summary
    self.text = text
    self.facts = facts
  }

  public var isEmpty: Bool { summary == nil && text.isEmpty && (facts?.isEmpty ?? true) }
}

/// What kind of file an item is, for its icon and label: the organizing
/// device's reading type when it sent one, else the file's extension.
public enum MemoryFileKind: String, Equatable, Sendable, CaseIterable {
  case text, document, spreadsheet, slides, pdf, scannedPDF, email, calendar, contact, ebook
  case archive, web, code, data, image, video, audio, other

  public init(readingType: String?, filename: String?) {
    if let readingType, let kind = Self.fromReading[readingType] {
      self = kind
      return
    }
    let ext = ((filename ?? "") as NSString).pathExtension.lowercased()
    self = Self.byExtension[ext] ?? .other
  }

  static let fromReading: [String: MemoryFileKind] = [
    "text": .text, "document": .document, "spreadsheet": .spreadsheet, "slides": .slides,
    "pdf": .pdf, "scanned_pdf": .scannedPDF, "email": .email, "calendar": .calendar,
    "contact": .contact, "ebook": .ebook, "archive": .archive, "web": .web, "code": .code,
    "data": .data, "image": .image,
  ]

  static let byExtension: [String: MemoryFileKind] = {
    var map: [String: MemoryFileKind] = [:]
    let groups: [(MemoryFileKind, [String])] = [
      (.text, ["txt", "text", "md", "markdown", "log", "rtf"]),
      (.document, ["doc", "docx", "odt", "pages", "wps"]),
      (.spreadsheet, ["xls", "xlsx", "xlsm", "ods", "csv", "tsv", "tab", "numbers"]),
      (.slides, ["ppt", "pptx", "odp", "key"]),
      (.pdf, ["pdf"]),
      (.email, ["eml", "emlx", "msg", "mbox"]),
      (.calendar, ["ics", "ical", "ifb"]),
      (.contact, ["vcf", "vcard"]),
      (.ebook, ["epub", "mobi", "azw3"]),
      (.archive, ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz"]),
      (.web, ["html", "htm", "xhtml", "webarchive", "webloc", "url", "mhtml"]),
      (
        .code,
        [
          "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "m",
          "go", "rs", "rb", "php", "sh", "zsh", "sql", "css", "scss", "ipynb",
        ]
      ),
      (.data, ["json", "xml", "yaml", "yml", "toml", "plist", "sqlite", "db", "parquet"]),
      (
        .image,
        ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg"]
      ),
      (.video, ["mp4", "mov", "m4v", "mkv", "webm"]),
      (.audio, ["wav", "m4a", "mp3", "aac", "flac", "ogg", "opus", "amr", "caf"]),
    ]
    for (kind, extensions) in groups { for ext in extensions { map[ext] = kind } }
    return map
  }()

  /// "表格", "邮件", …
  public var label: String {
    switch self {
    case .text: "文本"
    case .document: "文档"
    case .spreadsheet: "表格"
    case .slides: "演示文稿"
    case .pdf: "PDF"
    case .scannedPDF: "扫描件"
    case .email: "邮件"
    case .calendar: "日程"
    case .contact: "联系人"
    case .ebook: "电子书"
    case .archive: "压缩包"
    case .web: "网页"
    case .code: "代码"
    case .data: "数据"
    case .image: "图片"
    case .video: "视频"
    case .audio: "音频"
    case .other: "文件"
    }
  }

  /// SF Symbol for the item's tile.
  public var symbol: String {
    switch self {
    case .text: "doc.text"
    case .document: "doc.richtext"
    case .spreadsheet: "tablecells"
    case .slides: "rectangle.on.rectangle"
    case .pdf: "doc.text.fill"
    case .scannedPDF: "doc.viewfinder"
    case .email: "envelope"
    case .calendar: "calendar"
    case .contact: "person.crop.rectangle"
    case .ebook: "book"
    case .archive: "archivebox"
    case .web: "globe"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .data: "curlybraces"
    case .image: "photo"
    case .video: "film"
    case .audio: "waveform"
    case .other: "doc"
    }
  }
}

/// Plain words about a file item, shared by the pages and the export.
public enum MemoryFileText {
  /// "2.3 MB", "812 KB", "96 字节".
  public static func size(_ bytes: Int64) -> String {
    if bytes < 1_024 { return "\(bytes) 字节" }
    let units = ["KB", "MB", "GB"]
    var value = Double(bytes) / 1_024
    var unit = 0
    while value >= 1_024, unit < units.count - 1 {
      value /= 1_024
      unit += 1
    }
    let digits = value < 10 ? "%.1f" : "%.0f"
    return String(format: digits, value) + " " + units[unit]
  }

  /// "3 页", "2 个工作表", "12 张幻灯片", "4 个附件", "读了 5 张图"; in a
  /// fixed order, unknown counts left out.
  public static func counts(_ counts: [String: Int]) -> [String] {
    let known: [(String, (Int) -> String)] = [
      ("pages", { "\($0) 页" }), ("sheets", { "\($0) 个工作表" }),
      ("slides", { "\($0) 张幻灯片" }), ("messages", { "\($0) 封邮件" }),
      ("entries", { "\($0) 个文件" }), ("attachments", { "\($0) 个附件" }),
      ("images_read", { "读了 \($0) 张图" }),
    ]
    return known.compactMap { key, text in counts[key].flatMap { $0 > 0 ? text($0) : nil } }
  }

  /// Why the organizing device could not read the file.
  public static func error(_ code: String) -> String {
    switch code {
    case "encrypted": "文件有密码，整理设备没有打开"
    case "unsupported": "整理设备还读不了这种文件"
    case "too_large": "文件太大，整理设备没有读"
    case "corrupt": "文件已损坏，整理设备读不了"
    default: "整理设备没能读这个文件"
    }
  }

  /// A key field's name in Chinese when it is a common one.
  public static func fieldName(_ name: String) -> String {
    let names: [String: String] = [
      "from": "发件人", "to": "收件人", "cc": "抄送", "subject": "主题", "date": "日期",
      "title": "标题", "summary": "摘要", "start": "开始", "end": "结束", "location": "地点",
      "organizer": "组织者", "attendees": "参与人", "name": "姓名", "organization": "单位",
      "org": "单位", "phone": "电话", "tel": "电话", "email": "邮箱", "address": "地址",
      "vendor": "商家", "merchant": "商家", "total": "金额", "amount": "金额",
      "currency": "币种", "author": "作者",
    ]
    return names[name.lowercased()] ?? name
  }

  /// Why a file item stays on this Mac, when it does: larger than the
  /// organizer's limit with no text read here.
  public static func notSentReason(_ record: MemoryItemRecord) -> String? {
    guard record.itemKind == .file, let size = record.fileSizeBytes,
      size > UserItemLimits.maximumSendableFileBytes
    else { return nil }
    let hasText = !(record.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasText
      ? "超过 25 MB，只把本机读出的文字交给整理设备"
      : "超过 25 MB，只留在这台 Mac"
  }

  /// "表格 · 2.3 MB · 2 个工作表" (the row's meta line already names the
  /// kind, so the row leaves it out).
  public static func facts(
    _ record: MemoryItemRecord, reading: MemoryFileReading?, includeKind: Bool = true
  ) -> String {
    let kind = MemoryFileKind(
      readingType: reading?.facts?.type, filename: record.sourceIdentifier ?? record.title)
    var parts = includeKind ? [kind.label] : []
    if let size = record.fileSizeBytes, size > 0 { parts.append(self.size(size)) }
    if let counts = reading?.facts?.counts { parts.append(contentsOf: self.counts(counts)) }
    if reading?.facts?.counts["pages"] == nil, let pages = record.pageCount, pages > 0 {
      parts.append("\(pages) 页")
    }
    return parts.joined(separator: " · ")
  }
}

/// Text the organizing device wrote with Markdown tables (a spreadsheet's
/// sheets), split into headings, tables and plain lines for display.
public enum MemoryReadingBlocks {
  public enum Block: Equatable, Sendable {
    case heading(String)
    case table(header: [String], rows: [[String]])
    case text(String)
  }

  public static func parse(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var table: [[String]] = []
    func flushParagraph() {
      if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: "\n"))) }
      paragraph = []
    }
    func flushTable() {
      guard !table.isEmpty else { return }
      let header = table[0]
      blocks.append(.table(header: header, rows: Array(table.dropFirst())))
      table = []
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("|"), line.hasSuffix("|"), line.count >= 2 {
        flushParagraph()
        let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
          .map { $0.trimmingCharacters(in: .whitespaces) }
        // The `| --- |` rule under the header is not a row.
        if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
        table.append(cells)
        continue
      }
      flushTable()
      if line.hasPrefix("#") {
        flushParagraph()
        let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { blocks.append(.heading(title)) }
      } else if line.isEmpty {
        flushParagraph()
      } else {
        paragraph.append(String(raw))
      }
    }
    flushParagraph()
    flushTable()
    return blocks
  }

  public static func hasTable(_ text: String) -> Bool {
    parse(text).contains { if case .table = $0 { return true } else { return false } }
  }
}
