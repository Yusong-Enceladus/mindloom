import Foundation

/// A paper's public record, from arXiv or Crossref.
public struct PaperRecord: Sendable, Equatable {
  public var source: PublicSourceID
  public var identifier: String
  public var title: String
  public var authors: [String]
  public var venue: String?
  public var published: String?
  public var updated: String?
  public var summary: String?
  public var note: String?
  public var doi: String?
  public var pageURL: URL

  /// The item text: one fact per line, labelled.
  public var text: String {
    var lines = [title]
    if !authors.isEmpty { lines.append("作者：" + authors.joined(separator: ", ")) }
    if let venue, !venue.isEmpty { lines.append("发表于：" + venue) }
    if let published, !published.isEmpty { lines.append("发布日期：" + published) }
    if let updated, !updated.isEmpty, updated != published { lines.append("更新日期：" + updated) }
    if let doi, !doi.isEmpty { lines.append("DOI：" + doi) }
    if source == .arXiv { lines.append("arXiv：" + identifier) }
    if let note, !note.isEmpty { lines.append("备注：" + note) }
    if let summary, !summary.isEmpty { lines.append(""); lines.append(summary) }
    return lines.joined(separator: "\n")
  }
}

// MARK: - arXiv

/// arXiv's API by identifier (one request per three seconds, one connection
/// at a time: https://info.arxiv.org/help/api/tou.html).
public enum ArXivSource {
  /// 「2401.01234」, 「2401.01234v2」, 「cs/0112017」, from a bare number, an
  /// 「arXiv:」 prefix or an abs/pdf link; nil for anything else.
  public static func normalizedID(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "https://arxiv.org/pdf/", "http://arxiv.org/pdf/", "arxiv.org/abs/", "arXiv:", "arxiv:"]
    where text.lowercased().hasPrefix(prefix.lowercased()) {
      text = String(text.dropFirst(prefix.count))
    }
    if text.hasSuffix(".pdf") { text = String(text.dropLast(4)) }
    let modern = #"^[0-9]{4}\.[0-9]{4,5}(v[0-9]{1,3})?$"#
    let legacy = #"^[a-z\-]+(\.[A-Z]{2})?/[0-9]{7}(v[0-9]{1,3})?$"#
    if text.range(of: modern, options: .regularExpression) != nil
      || text.range(of: legacy, options: .regularExpression) != nil
    {
      return text
    }
    return nil
  }

  public static func request(id: String) -> EgressRequest {
    var components = URLComponents(string: "https://export.arxiv.org/api/query")!
    components.queryItems = [
      URLQueryItem(name: "id_list", value: id), URLQueryItem(name: "max_results", value: "1"),
    ]
    return EgressRequest(
      url: components.url!, headers: ["Accept": "application/atom+xml"], kind: .publicSource,
      service: PublicSourceID.arXiv.rawValue, maximumBytes: 512 * 1024, timeout: 20)
  }

  public static func parse(_ data: Data, id: String) -> PaperRecord? {
    let parser = AtomEntryParser()
    let xml = XMLParser(data: data)
    xml.shouldResolveExternalEntities = false
    xml.delegate = parser
    guard xml.parse(), let entry = parser.entries.first else { return nil }
    guard let entryID = entry["id"], !entryID.contains("/api/errors"),
      let title = entry["title"].map(collapse), !title.isEmpty
    else { return nil }
    return PaperRecord(
      source: .arXiv, identifier: id, title: title, authors: parser.authors,
      venue: entry["arxiv:journal_ref"].map(collapse), published: entry["published"].map(day),
      updated: entry["updated"].map(day), summary: entry["summary"].map(collapse),
      note: entry["arxiv:comment"].map(collapse), doi: entry["arxiv:doi"].map(collapse),
      pageURL: URL(string: "https://arxiv.org/abs/\(id)")!)
  }

  static func collapse(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  /// 「2017-06-12T17:57:34Z」 → 「2017-06-12」.
  static func day(_ text: String) -> String {
    String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
  }
}

/// Reads the first `<entry>` of an Atom feed.
final class AtomEntryParser: NSObject, XMLParserDelegate {
  var entries: [[String: String]] = []
  var authors: [String] = []
  private var current: [String: String]?
  private var path: [String] = []
  private var buffer = ""

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes: [String: String] = [:]
  ) {
    path.append(elementName)
    buffer = ""
    if elementName == "entry", entries.isEmpty { current = [:] }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    buffer += string
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
  ) {
    defer { path.removeLast() }
    if elementName == "entry", let entry = current {
      entries.append(entry)
      current = nil
      return
    }
    guard current != nil else { return }
    let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if elementName == "name", path.dropLast().last == "author" {
      if !value.isEmpty { authors.append(ArXivSource.collapse(value)) }
    } else if path.count >= 2, path[path.count - 2] == "entry", current?[elementName] == nil {
      current?[elementName] = value
    }
    buffer = ""
  }
}

// MARK: - Crossref

/// Crossref's public API by DOI (public pool; no e-mail is sent, so the
/// "polite pool" is not used: MATTER-MINIMUM §7.1).
public enum CrossrefSource {
  public static func normalizedDOI(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:", "DOI:", "DOI "]
    where text.hasPrefix(prefix) {
      text = String(text.dropFirst(prefix.count))
    }
    guard text.count <= 200,
      text.range(of: #"^10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9<>\[\]]+$"#, options: .regularExpression) != nil
    else { return nil }
    return text
  }

  public static func request(doi: String) -> EgressRequest {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#;")
    let path = doi.addingPercentEncoding(withAllowedCharacters: allowed) ?? doi
    return EgressRequest(
      url: URL(string: "https://api.crossref.org/works/\(path)")!, headers: ["Accept": "application/json"],
      kind: .publicSource, service: PublicSourceID.crossref.rawValue, maximumBytes: 2 * 1024 * 1024,
      timeout: 20)
  }

  public static func parse(_ data: Data, doi: String) -> PaperRecord? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = object["message"] as? [String: Any],
      let title = (message["title"] as? [String])?.first.map(ArXivSource.collapse), !title.isEmpty
    else { return nil }
    let authors = (message["author"] as? [[String: Any]] ?? []).compactMap { author -> String? in
      let parts = [author["given"] as? String, author["family"] as? String].compactMap { $0 }
      if !parts.isEmpty { return parts.joined(separator: " ") }
      return author["name"] as? String
    }
    let venue = (message["container-title"] as? [String])?.first
    let issued = date(message["published"]) ?? date(message["issued"])
    var summary = message["abstract"] as? String
    if let abstract = summary {
      summary = ArXivSource.collapse(abstract.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
    }
    let page = (message["URL"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://doi.org/\(doi)")!
    return PaperRecord(
      source: .crossref, identifier: doi, title: title, authors: Array(authors.prefix(50)), venue: venue,
      published: issued, updated: nil, summary: summary, note: message["publisher"] as? String,
      doi: doi, pageURL: page)
  }

  /// `{"date-parts": [[2015, 5, 27]]}` → 「2015-05-27」.
  static func date(_ value: Any?) -> String? {
    guard let parts = ((value as? [String: Any])?["date-parts"] as? [[Any]])?.first, !parts.isEmpty else {
      return nil
    }
    let numbers = parts.compactMap { ($0 as? Int) ?? Int("\($0)") }
    guard let year = numbers.first else { return nil }
    var text = String(year)
    if numbers.count > 1 { text += String(format: "-%02d", numbers[1]) }
    if numbers.count > 2 { text += String(format: "-%02d", numbers[2]) }
    return text
  }
}
