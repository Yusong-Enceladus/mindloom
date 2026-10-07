import Foundation

#if canImport(PDFKit)
  import PDFKit
#endif

/// A page's readable text, read on this device.
public struct ExtractedPage: Sendable, Equatable {
  public var title: String
  public var text: String
  /// Which extractor and version (kept with the item, so a better one can
  /// read the stored bytes again).
  public var extractor: String
  public var contentType: String
}

/// Reads a downloaded page on the device (WEBSEARCH §4.4): HTML through
/// this package's parser with hidden content removed and the main content
/// chosen by readability scoring; PDF through PDFKit; plain text as is.
/// Every result goes through `TextCleaner`.
public enum PageReader {
  public static let htmlExtractor = "mindloom-readability-v1"
  public static let pdfExtractor = "pdfkit-text-v1"
  public static let textExtractor = "plain-text-v1"
  /// Less text than this (Han characters count twice: they carry about
  /// twice the content) means the page needs a script to show its text, or
  /// is empty.
  public static let minimumReadableLength = 150

  public static func isReadable(_ text: String) -> Bool {
    var length = 0
    for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
      length += (0x3000...0x9FFF).contains(scalar.value) ? 2 : 1
      if length >= minimumReadableLength { return true }
    }
    return false
  }

  /// How long one page may take to read inside a lookup.
  public static let readingSeconds: TimeInterval = 15

  /// Reads off the caller's actor (the lookup stays free to answer Settings
  /// and to be switched off), within `seconds`; nil when the page could not
  /// be read in time or the task was cancelled.
  @concurrent
  public static func readConcurrently(
    _ data: Data, contentType: String?, focus: [String] = [], seconds: TimeInterval = readingSeconds
  ) async -> ExtractedPage? {
    read(data, contentType: contentType, focus: focus, seconds: seconds)
  }

  /// `seconds` nil: no time limit (cancellation still stops it).
  public static func read(
    _ data: Data, contentType: String?, focus: [String] = [], seconds: TimeInterval? = nil
  ) -> ExtractedPage? {
    let budget = ReadBudget(seconds: seconds)
    let type = (contentType ?? "").lowercased()
    let mime = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    if mime == "application/pdf" || (mime.isEmpty && data.starts(with: Array("%PDF".utf8))) {
      return pdf(data)
    }
    if mime == "text/html" || mime == "application/xhtml+xml" || (mime.isEmpty && looksLikeHTML(data)) {
      return html(data, contentType: type, focus: focus, budget: budget)
    }
    if mime == "text/plain" || mime == "text/markdown" || mime.isEmpty {
      guard let text = decode(data, contentType: type) else { return nil }
      let cleaned = TextCleaner.clean(text)
      guard !cleaned.isEmpty else { return nil }
      let title = cleaned.split(separator: "\n").first.map { String($0.prefix(120)) } ?? ""
      return ExtractedPage(title: title, text: cleaned, extractor: textExtractor, contentType: "text/plain")
    }
    return nil
  }

  static func looksLikeHTML(_ data: Data) -> Bool {
    let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
    return head.contains("<html") || head.contains("<!doctype html") || head.contains("<body") || head.contains("<head")
  }

  // MARK: HTML

  static func html(_ data: Data, contentType: String, focus: [String], budget: ReadBudget) -> ExtractedPage? {
    guard let source = decode(data, contentType: contentType) else { return nil }
    let root = HTMLParser.parse(source, budget: budget)
    // The page's declared title (og:title, <title>) is read before cleaning
    // removes the head; a heading stands in for it only after cleaning, so
    // a hidden heading never becomes the title.
    let declared = declaredTitle(root)
    guard PageCleaner.clean(root, budget: budget), !budget.exceeded else { return nil }
    let title = TextCleaner.clean(declared.isEmpty ? root.first("h1").map(PageText.text(of:)) ?? "" : declared)
    let body = root.first("body") ?? root
    let full = TextCleaner.clean(PageText.text(of: body))
    var chosen = full
    if let parts = Readability.mainContent(body, budget: budget) {
      let article = TextCleaner.clean(parts.map(PageText.text(of:)).joined(separator: "\n"))
      if focus.isEmpty {
        if article.count >= 250 { chosen = article }
      } else if !article.isEmpty, focusHits(article, focus) >= max(1, focusHits(full, focus)) {
        chosen = article
      }
    }
    if budget.exceeded { return nil }
    return ExtractedPage(title: title, text: chosen, extractor: htmlExtractor, contentType: "text/html")
  }

  /// og:title, else <title>; "" when neither says anything.
  static func declaredTitle(_ root: HTMLNode) -> String {
    for node in root.descendants() where node.name == "meta" {
      let property = (node.attributes["property"] ?? node.attributes["name"] ?? "").lowercased()
      if property == "og:title", let content = node.attributes["content"], !content.isEmpty { return content }
    }
    if let title = root.first("title") {
      let text = title.children.map(\.text).joined()
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
    }
    return ""
  }

  /// Distinct focus words found (case-insensitive).
  static func focusHits(_ text: String, _ focus: [String]) -> Int {
    focus.filter { !$0.isEmpty && text.range(of: $0, options: [.caseInsensitive]) != nil }.count
  }

  // MARK: Character sets

  /// The header's charset, then a `<meta>` charset, then a byte-order mark,
  /// then UTF-8, GB 18030 and Windows-1252, in that order.
  static func decode(_ data: Data, contentType: String) -> String? {
    if let name = charset(in: contentType) ?? metaCharset(data), let encoding = encoding(named: name),
      let text = String(data: data, encoding: encoding)
    {
      return text
    }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16)
    }
    if let text = String(data: data, encoding: .utf8) { return text }
    if let gb = encoding(named: "gb18030"), let text = String(data: data, encoding: gb) { return text }
    return String(data: data, encoding: .windowsCP1252)
  }

  static func charset(in contentType: String) -> String? {
    guard let range = contentType.range(of: "charset=") else { return nil }
    let value = contentType[range.upperBound...].prefix(while: { $0 != ";" && $0 != " " })
    let name = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    return name.isEmpty ? nil : name
  }

  static func metaCharset(_ data: Data) -> String? {
    let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
    guard let range = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression)
    else { return nil }
    let match = head[range]
    guard let equals = match.firstIndex(of: "=") else { return nil }
    return match[match.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
  }

  static func encoding(named name: String) -> String.Encoding? {
    var name = name.lowercased()
    if ["gb2312", "gbk", "x-gbk", "cp936"].contains(name) { name = "gb18030" }
    let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard cf != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
  }

  // MARK: PDF

  static func pdf(_ data: Data) -> ExtractedPage? {
    #if canImport(PDFKit)
      guard let document = PDFDocument(data: data) else { return nil }
      var parts: [String] = []
      var total = 0
      for index in 0..<min(document.pageCount, 300) {
        guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
        parts.append(text)
        total += text.count
        if total > WebSourceItem.maximumTextCharacters { break }
      }
      let text = TextCleaner.clean(parts.joined(separator: "\n\n"))
      guard !text.isEmpty else { return nil }
      let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        ?? text.split(separator: "\n").first.map { String($0.prefix(120)) } ?? ""
      return ExtractedPage(title: TextCleaner.clean(title), text: text, extractor: pdfExtractor, contentType: "application/pdf")
    #else
      return nil
    #endif
  }
}

/// Text from a page, cleaned of invisible characters before it is stored or
/// shown to a model: control characters, zero-width and joiner characters,
/// bidirectional controls, Unicode tag characters (they can carry invisible
/// instructions), variation selectors, private-use characters and other
/// invisible formatting are removed; unusual spaces become spaces; lines
/// are trimmed and blank runs collapsed. (Unlike stored transcripts, a web
/// page keeps no format character: WEBSEARCH §4.4 step 4.) The result is
/// still untrusted page text, never instructions.
public enum TextCleaner {
  static func isInvisible(_ value: UInt32) -> Bool {
    switch value {
    case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F, 0x200B...0x200F,
      0x202A...0x202E, 0x2060...0x206F, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0, 0xFFF9...0xFFFB,
      0xE000...0xF8FF, 0x1D173...0x1D17A, 0xE0000...0xE007F, 0xE0100...0xE01EF, 0xF0000...0x10FFFF:
      return true
    default:
      return false
    }
  }

  static func isSpace(_ value: UInt32) -> Bool {
    value == 0x00A0 || (0x2000...0x200A).contains(value) || value == 0x202F || value == 0x205F
      || value == 0x3000 || value == 0x1680
  }

  public static func clean(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      let value = scalar.value
      if scalar == "\n" || scalar == "\t" {
        scalars.append(scalar)
      } else if scalar == "\r" || value == 0x2028 || value == 0x2029 || value == 0x0085 {
        scalars.append("\n")
      } else if value < 0x20 || (0x7F...0x9F).contains(value) || isInvisible(value) {
        continue
      } else if isSpace(value) {
        scalars.append(" ")
      } else {
        scalars.append(scalar)
      }
    }
    var lines: [String] = []
    for raw in String(scalars).split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
      if line.isEmpty, lines.last?.isEmpty ?? true { continue }
      lines.append(line)
    }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.joined(separator: "\n")
  }
}
