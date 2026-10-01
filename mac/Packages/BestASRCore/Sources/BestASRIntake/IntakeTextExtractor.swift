import AppKit
import BestASRDomain
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Local text extraction. Nothing here loads remote resources, runs scripts,
/// or uses a model.
public enum IntakeTextExtractor {
  public struct Extracted: Equatable, Sendable {
    public let text: String
    public let extractor: String
    public let pageCount: Int?
    /// A PDF: how many of its pages have a text layer.
    public let pagesWithText: Int?

    public init(text: String, extractor: String, pageCount: Int? = nil, pagesWithText: Int? = nil)
    {
      self.text = text
      self.extractor = extractor
      self.pageCount = pageCount
      self.pagesWithText = pagesWithText
    }

    /// A PDF with a page that has no text layer (a scan, or scanned pages).
    public var hasPagesWithoutText: Bool {
      guard let pageCount, let pagesWithText else { return false }
      return pagesWithText < pageCount
    }
  }

  public enum ExtractionError: Error, Equatable, Sendable {
    case unreadable
    case empty
    case tooLong
  }

  /// Newlines normalized to `\n`; NUL and other C0/C1 control characters
  /// (except tab and newline) removed, so stored text is safe to index.
  public static func sanitized(_ text: String) -> String {
    let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var scalars = String.UnicodeScalarView()
    for scalar in unified.unicodeScalars {
      if scalar == "\n" || scalar == "\t" {
        scalars.append(scalar)
        continue
      }
      // C0/C1 controls and a byte-order mark are dropped. Format characters
      // such as the zero-width joiner inside emoji sequences are kept.
      if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0xFEFF {
        continue
      }
      scalars.append(scalar)
    }
    return String(scalars)
  }

  public static func plainText(fileURL: URL) throws -> Extracted {
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    // Refused before decoding when even the most compact decoding (UTF-16
    // to UTF-8 at most halves the bytes) cannot fit the stored-text limit.
    guard data.count <= UserItemLimits.maximumStoredTextBytes * 2 else {
      throw ExtractionError.tooLong
    }
    guard let text = decodedText(data) else { throw ExtractionError.unreadable }
    return try nonEmpty(sanitized(text), extractor: "plain-text-v1")
  }

  /// UTF-8, then a UTF-16/32 byte-order mark, then GB 18030 (older Chinese
  /// text files), then Windows-1252. Fixed order, so the result is stable.
  public static func decodedText(_ data: Data) -> String? {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    let bytes = [UInt8](data.prefix(4))
    if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
      if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
    }
    let gb18030 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    if let chinese = String(data: data, encoding: gb18030) { return chinese }
    return String(data: data, encoding: .windowsCP1252)
  }

  public static func rtfText(_ data: Data) -> String? {
    guard
      let string = try? NSAttributedString(
        data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
      )
    else { return nil }
    let text = sanitized(string.string)
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }

  public static func attributedFileText(
    fileURL: URL, type: NSAttributedString.DocumentType, extractor: String
  ) throws -> Extracted {
    guard
      let string = try? NSAttributedString(
        url: fileURL, options: [.documentType: type], documentAttributes: nil
      )
    else { throw ExtractionError.unreadable }
    return try nonEmpty(sanitized(string.string), extractor: extractor)
  }

  /// HTML to text through the XML tidy parser, with scripts, styles, and other
  /// non-content elements removed. External entities are never loaded.
  public static func htmlText(_ data: Data) -> String? {
    // Decoded first: the tidy parser reading raw bytes without a declared
    // charset drops non-ASCII text.
    guard let source = decodedText(data),
      let document = try? XMLDocument(
        xmlString: source, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
      )
    else { return nil }
    let removable = ["script", "style", "noscript", "template", "head", "iframe", "object"]
    for name in removable {
      for node in (try? document.nodes(forXPath: "//*[local-name()='\(name)']")) ?? [] {
        node.detach()
      }
    }
    // The tidy parser already ends block elements with a newline.
    let raw = document.rootElement()?.stringValue ?? ""
    let lines = sanitized(raw).split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    var collapsed: [String] = []
    for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) {
      collapsed.append(line)
    }
    let text = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  public static func htmlText(fileURL: URL) throws -> Extracted {
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard let text = htmlText(data) else { throw ExtractionError.empty }
    return Extracted(text: text, extractor: "html-xml-v1")
  }

  /// PDF text layer via PDFKit, page by page. A PDF with pages that have no
  /// text layer (a scan) is kept as a file item with the text that was
  /// there, for the organizing device to read the pages. No placeholder is
  /// stored as its text. An encrypted PDF that needs a password is unreadable.
  public static func pdfText(document: PDFDocument?) throws -> Extracted {
    guard let document, document.pageCount > 0 else { throw ExtractionError.unreadable }
    if document.isLocked { throw ExtractionError.unreadable }
    var pages: [String] = []
    for index in 0..<document.pageCount {
      if let page = document.page(at: index), let text = page.string {
        let cleaned = sanitized(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { pages.append(cleaned) }
      }
    }
    let text = pages.joined(separator: "\n\n")
    return Extracted(
      text: text, extractor: UserItemLimits.pdfExtractor, pageCount: document.pageCount,
      pagesWithText: pages.count
    )
  }

  public static func pdfText(data: Data) throws -> Extracted {
    try pdfText(document: PDFDocument(data: data))
  }

  public static func pdfText(fileURL: URL) throws -> Extracted {
    try pdfText(document: PDFDocument(url: fileURL))
  }

  /// A Safari web archive: the saved main page's HTML, read like HTML. The
  /// archive is a property list; nothing in it is loaded or fetched.
  public static func webArchiveText(fileURL: URL) throws -> Extracted {
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let main = plist["WebMainResource"] as? [String: Any],
      let html = main["WebResourceData"] as? Data,
      let text = htmlText(html)
    else { throw ExtractionError.unreadable }
    let url = (main["WebResourceURL"] as? String).flatMap(savedLink)
    return Extracted(
      text: [url, text].compactMap { $0 }.joined(separator: "\n\n"), extractor: "webarchive-v1")
  }

  /// A saved link (`.webloc` property list, or `.url` Windows shortcut): its
  /// name and address as text. The address is never opened.
  public static func webLocationText(fileURL: URL) throws -> Extracted {
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard data.count <= 1_000_000 else { throw ExtractionError.tooLong }
    var link: String?
    if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
      as? [String: Any]
    {
      link = plist["URL"] as? String
    } else if let text = decodedText(data) {
      link =
        text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.uppercased().hasPrefix("URL=") }
        .map { String($0.dropFirst(4)) }
    }
    guard let link = link.flatMap(savedLink) else { throw ExtractionError.empty }
    let name = fileURL.deletingPathExtension().lastPathComponent
    return Extracted(text: "\(name)\n\(link)", extractor: "web-location-v1")
  }

  /// A saved address as plain text (one line, sanitized, bounded).
  static func savedLink(_ value: String) -> String? {
    let line = sanitized(value).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, !line.contains("\n"), line.count <= 4_096 else { return nil }
    return line
  }

  /// Text a file declares as text (csv, ics, vcf, eml, svg, …) for a file
  /// item's local text; nil for a binary or a file above the stored-text
  /// limit.
  public static func declaredText(fileURL: URL) -> String? {
    // Only a type that says it is text (or has no known type and is valid
    // UTF-8): the last-resort Windows-1252 decoding reads any bytes.
    let ext = fileURL.pathExtension.lowercased()
    let type = UTType(filenameExtension: ext)
    let declared =
      IntakeFileClass.structuredTextExtensions.contains(ext) || ext == "svg"
      || (type.map { !$0.isDynamic && $0.conforms(to: .text) } ?? false)
    let unknown = type == nil || type?.isDynamic == true
    guard declared || unknown else { return nil }
    guard
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
      (values.fileSize ?? 0) <= UserItemLimits.maximumStoredTextBytes,
      let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
      !data.prefix(8_192).contains(0),
      let text = declared ? decodedText(data) : String(data: data, encoding: .utf8)
    else { return nil }
    let cleaned = sanitized(text)
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleaned
  }

  private static func nonEmpty(_ text: String, extractor: String) throws -> Extracted {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ExtractionError.empty
    }
    return Extracted(text: text, extractor: extractor)
  }
}

/// What a file becomes. Every file is taken in (files contract): what this
/// Mac reads completely becomes a document (its text); a word-processing
/// file keeps its text read here and goes as a file; images are normalized;
/// audio and video go to the existing media import (audio never leaves this
/// Mac); anything else is kept byte for byte as a file for the organizing
/// device to read.
public enum IntakeFileClass: Equatable, Sendable {
  /// Plain text, Markdown, logs, source code, JSON/YAML/XML: a document.
  case plainText
  case rtf
  case html
  /// A Safari `.webarchive`: its saved page as text (a document).
  case webArchive
  /// A `.webloc`/`.url` saved link: its address as text (a document).
  case webLocation
  /// A document when every page has a text layer, else a file.
  case pdf
  /// Word-processing files this Mac reads natively (docx, odt, doc): a file
  /// item with that text as its local text.
  case wordProcessing(WordFormat)
  case image
  /// Rasterized on this Mac when it references nothing outside itself.
  case svg
  case audio
  case video
  /// Pages/Numbers/Keynote, as a single file or a package directory.
  case iWork
  /// Anything else: kept and sent as a file (with its text when it
  /// declares itself text).
  case file

  public enum WordFormat: String, Equatable, Sendable {
    case docx
    case odt
    case doc

    var documentType: NSAttributedString.DocumentType {
      switch self {
      case .docx: .officeOpenXML
      case .odt: .openDocument
      case .doc: .docFormat
      }
    }

    var extractor: String { "\(rawValue)-attributed-v1" }
  }

  public static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "jpe", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp",
  ]
  public static let iWorkExtensions: Set<String> = ["pages", "numbers", "key"]
  /// Text formats the organizing device reads better as their own type (a
  /// table, an email, an event, a contact): sent as files, their text kept
  /// as local text.
  public static let structuredTextExtensions: Set<String> = [
    "csv", "tsv", "tab", "ics", "ical", "ifb", "vcf", "vcard", "eml", "emlx", "mbox", "msg",
  ]

  public static func classify(_ url: URL) -> IntakeFileClass {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "txt", "text", "md", "markdown": return .plainText
    case "rtf": return .rtf
    case "html", "htm", "xhtml": return .html
    case "webarchive": return .webArchive
    case "webloc", "url": return .webLocation
    case "pdf": return .pdf
    case "docx": return .wordProcessing(.docx)
    case "odt": return .wordProcessing(.odt)
    case "doc": return .wordProcessing(.doc)
    case "svg": return .svg
    default:
      if imageExtensions.contains(ext) { return .image }
      if MediaImportFormats.audioExtensions.contains(ext) { return .audio }
      if MediaImportFormats.videoExtensions.contains(ext) { return .video }
      if iWorkExtensions.contains(ext) { return .iWork }
      if structuredTextExtensions.contains(ext) { return .file }
      if isOtherPlainText(ext) { return .plainText }
      // What the system declares audio or video is media whatever its name
      // (`.avi`, `.wma`, `.3gp`, …; privacy contract §5), and any declared
      // image — camera RAW, PSD — goes through the image path.
      if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic {
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .image) { return .image }
      }
      return .file
    }
  }

  /// Documents the organizing device reads from their bytes (Office,
  /// iWork, OpenDocument, e-books, mail, calendars, contacts, tables, PDF,
  /// SVG). Any other file this Mac cannot read as text is kept here.
  public static let sendableFileExtensions: Set<String> = [
    "xlsx", "xlsm", "xltx", "xls", "pptx", "ppsx", "potx", "ppt", "pps", "key", "numbers",
    "pages", "epub", "odt", "ods", "odp", "odg", "docx", "dotx", "doc", "rtfd", "pdf", "svg",
    "csv", "tsv", "tab", "ics", "ical", "ifb", "vcf", "vcard", "eml", "emlx", "mbox", "msg",
  ]

  /// Archives other than zip: never expanded or sent; kept on this Mac.
  public static let archiveExtensions: Set<String> = [
    "tar", "tgz", "gz", "gzip", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma", "z", "7z",
    "rar", "zipx", "cab", "arj", "lzh", "zst", "dmg", "iso", "pkg", "xip", "sit", "sitx",
  ]

  /// A zip or any other archive: never sent (a zip's files are taken in
  /// one by one).
  public static func isArchive(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "zip" || archiveExtensions.contains(ext)
  }

  /// Whether a `.file` item may be sent as bytes: a document the organizing
  /// device reads, or a file the system declares as text. (A file whose
  /// bytes this Mac reads as text is sent too, with that text.)
  public static func isSendableFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if isArchive(url) { return false }
    if sendableFileExtensions.contains(ext) { return true }
    if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic {
      return type.conforms(to: .text) || type.conforms(to: .spreadsheet)
        || type.conforms(to: .presentation)
    }
    return false
  }

  /// Any other extension the system declares as text (json, log, yaml,
  /// diff/patch, source code, ...), read as plain text. Rich formats that
  /// conform to text but need their own reader are excluded.
  static func isOtherPlainText(_ ext: String) -> Bool {
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .text)
    else { return false }
    let ownReaders: [UTType] = [.rtf, .rtfd, .flatRTFD, .html, .image, .vCard]
    return !ownReaders.contains { type.conforms(to: $0) }
  }

  public var isMedia: Bool { self == .audio || self == .video }

  /// The file's Uniform Type Identifier, when the system knows the extension.
  public static func uniformType(_ url: URL) -> String? {
    let ext = url.pathExtension
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else {
      return nil
    }
    return type.identifier
  }

  /// The file's media type; `application/octet-stream` when unknown.
  public static func mediaType(_ url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "md", "markdown": return "text/markdown"
    case "csv": return "text/csv"
    case "tsv", "tab": return "text/tab-separated-values"
    case "eml": return "message/rfc822"
    case "mbox": return "application/mbox"
    case "msg": return "application/vnd.ms-outlook"
    case "ics", "ical", "ifb": return "text/calendar"
    case "vcf", "vcard": return "text/vcard"
    case "epub": return "application/epub+zip"
    case "pages": return "application/vnd.apple.pages"
    case "numbers": return "application/vnd.apple.numbers"
    case "key": return "application/vnd.apple.keynote"
    default:
      return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
  }
}
