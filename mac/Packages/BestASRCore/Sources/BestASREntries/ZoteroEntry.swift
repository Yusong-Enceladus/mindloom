import BestASRDomain
import BestASRIntake
import Foundation

/// Zotero research entry (V8 contract A7), off by default. Zotero 7 can open
/// a local API on this Mac (Zotero → 设置 → 高级 → 允许本机其他应用与 Zotero
/// 通信). Only when it does, new library items, notes and annotations become
/// items with a citation. The entry talks to 127.0.0.1 only, never follows a
/// redirect elsewhere, uses no proxy, and never fetches an item's URL or
/// attachment.
public struct ZoteroRecord: Equatable, Sendable {
  public let key: String
  public let version: Int
  public let itemType: String
  public let title: String
  public let creators: [String]
  public let date: String
  public let publication: String
  public let doi: String
  public let url: String
  public let abstract: String
  public let tags: [String]
  public let parentKey: String?
  /// A note's text (from its HTML, tags removed).
  public let note: String
  public let annotationText: String
  public let annotationComment: String
  public let annotationPage: String
  public let dateAdded: Date?

  public var isNote: Bool { itemType == "note" }
  public var isAnnotation: Bool { itemType == "annotation" }
  public var isAttachment: Bool { itemType == "attachment" }
  public var isRegular: Bool { !isNote && !isAnnotation && !isAttachment }

  /// One item of the local API's JSON (`{"key", "version", "data": {…}}`).
  public init?(json: [String: Any]) {
    let data = (json["data"] as? [String: Any]) ?? json
    guard let key = (data["key"] as? String) ?? (json["key"] as? String),
      let itemType = data["itemType"] as? String
    else { return nil }
    self.key = key
    version = (data["version"] as? Int) ?? (json["version"] as? Int) ?? 0
    self.itemType = itemType
    title = (data["title"] as? String) ?? ""
    creators = ((data["creators"] as? [[String: Any]]) ?? []).compactMap { creator in
      if let name = creator["name"] as? String, !name.isEmpty { return name }
      let last = (creator["lastName"] as? String) ?? ""
      let first = (creator["firstName"] as? String) ?? ""
      let joined = [last, first].filter { !$0.isEmpty }
      return joined.isEmpty ? nil : last.isEmpty ? first : last
    }
    date = (data["date"] as? String) ?? ""
    publication =
      (data["publicationTitle"] as? String) ?? (data["proceedingsTitle"] as? String)
      ?? (data["bookTitle"] as? String) ?? ""
    doi = (data["DOI"] as? String) ?? ""
    url = (data["url"] as? String) ?? ""
    abstract = (data["abstractNote"] as? String) ?? ""
    tags = ((data["tags"] as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String }
    parentKey = data["parentItem"] as? String
    note = ZoteroText.plain(html: (data["note"] as? String) ?? "")
    annotationText = (data["annotationText"] as? String) ?? ""
    annotationComment = (data["annotationComment"] as? String) ?? ""
    annotationPage = (data["annotationPageLabel"] as? String) ?? ""
    dateAdded = (data["dateAdded"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
  }
}

public enum ZoteroText {
  /// A note's HTML as plain text: paragraphs and line breaks kept, tags
  /// dropped, the common entities decoded. Nothing is loaded.
  public static func plain(html: String) -> String {
    var text = html
    for (pattern, replacement) in [
      ("<br\\s*/?>", "\n"), ("</p\\s*>", "\n"), ("</h[1-6]\\s*>", "\n"), ("</li\\s*>", "\n"),
      ("<[^>]+>", ""),
    ] {
      text = text.replacingOccurrences(
        of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
    for (entity, character) in [
      ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
      ("&amp;", "&"),
    ] {
      text = text.replacingOccurrences(of: entity, with: character)
    }
    return text.components(separatedBy: .newlines).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  /// "Zhang, Li & Wang (2024). Title. Journal. https://doi.org/…" (APA-like,
  /// from the item's own fields; the DOI and URL are text, never opened).
  public static func citation(_ record: ZoteroRecord) -> String {
    var authors: String
    switch record.creators.count {
    case 0: authors = ""
    case 1: authors = record.creators[0]
    case 2: authors = "\(record.creators[0]) & \(record.creators[1])"
    case 3: authors = "\(record.creators[0]), \(record.creators[1]) & \(record.creators[2])"
    default: authors = "\(record.creators[0]) et al."
    }
    let year = record.date.range(of: "\\d{4}", options: .regularExpression).map {
      String(record.date[$0])
    }
    var parts: [String] = []
    if !authors.isEmpty {
      parts.append(authors + (year.map { " (\($0))." } ?? "."))
    } else if let year {
      parts.append("(\(year)).")
    }
    if !record.title.isEmpty {
      parts.append(record.title.hasSuffix(".") ? record.title : record.title + ".")
    }
    if !record.publication.isEmpty { parts.append(record.publication + ".") }
    if !record.doi.isEmpty {
      parts.append(
        record.doi.lowercased().hasPrefix("http") ? record.doi : "https://doi.org/\(record.doi)")
    } else if !record.url.isEmpty {
      parts.append(record.url)
    }
    authors = parts.joined(separator: " ")
    return authors.isEmpty ? "（没有题录信息）" : authors
  }

  public static func text(_ record: ZoteroRecord, parent: ZoteroRecord?) -> String {
    let cited = parent ?? record
    var lines: [String] = []
    if record.isNote {
      lines.append("Zotero 笔记\(parent.map { "（\($0.title)）" } ?? "")：")
      lines.append(record.note.isEmpty ? "（空笔记）" : record.note)
    } else if record.isAnnotation {
      let page = record.annotationPage.isEmpty ? "" : " 第 \(record.annotationPage) 页"
      lines.append("Zotero 批注\(parent.map { "（\($0.title)\(page)）" } ?? page)：")
      if !record.annotationText.isEmpty { lines.append("「\(record.annotationText)」") }
      if !record.annotationComment.isEmpty { lines.append(record.annotationComment) }
    } else {
      lines.append("Zotero 文献：\(record.title.isEmpty ? "（没有标题）" : record.title)")
      if !record.tags.isEmpty { lines.append("标签：\(record.tags.joined(separator: "、"))") }
      if !record.abstract.isEmpty { lines.append("摘要：\(record.abstract)") }
    }
    lines.append("引用：\(citation(cited))")
    return lines.joined(separator: "\n")
  }
}

/// How the entry reaches Zotero. The real one is `ZoteroLoopbackTransport`;
/// tests give a fake.
public protocol ZoteroTransport: Sendable {
  /// `GET <path>` with a query; the status, the body and the
  /// `Last-Modified-Version` header.
  func get(_ path: String, query: [URLQueryItem]) async throws -> ZoteroResponse
}

public struct ZoteroResponse: Equatable, Sendable {
  public let status: Int
  public let body: Data
  public let libraryVersion: Int?

  public init(status: Int, body: Data, libraryVersion: Int?) {
    self.status = status
    self.body = body
    self.libraryVersion = libraryVersion
  }
}

/// Zotero's local API on this Mac only: `http://127.0.0.1:23119/api/…`. No
/// proxy, no cookies, no cache, and a redirect is refused.
public final class ZoteroLoopbackTransport: NSObject, ZoteroTransport, URLSessionTaskDelegate,
  @unchecked Sendable
{
  public static let host = "127.0.0.1"
  public static let port = 23119

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 30
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  public override init() {}

  public enum TransportError: Error, Equatable, Sendable {
    case notLoopback
    case unavailable
  }

  /// The request for a path under `/api/`; nil for anything that would not
  /// stay on this Mac.
  public static func request(_ path: String, query: [URLQueryItem]) -> URLRequest? {
    guard path.hasPrefix("/api/"), !path.contains(".."), !path.contains("//") else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = port
    components.path = path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url, url.host == host, url.port == port else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
    request.httpShouldHandleCookies = false
    return request
  }

  public func get(_ path: String, query: [URLQueryItem]) async throws -> ZoteroResponse {
    guard let request = Self.request(path, query: query) else { throw TransportError.notLoopback }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.url?.host == Self.host else {
        throw TransportError.notLoopback
      }
      let version = (http.value(forHTTPHeaderField: "Last-Modified-Version")).flatMap { Int($0) }
      return ZoteroResponse(status: http.statusCode, body: data, libraryVersion: version)
    } catch let error as TransportError {
      throw error
    } catch {
      throw TransportError.unavailable
    }
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    nil
  }
}

/// What the entry has accounted for: the library version last looked at
/// and the keys already taken.
public struct ZoteroWatchState: Codable, Equatable, Sendable {
  public var libraryVersion: Int?
  public var taken: [String] = []

  public init() {}
}

public enum ZoteroWatch {
  public static let pageSize = 50
  public static let maximumPerPass = 300
  public static let maximumRemembered = 20_000

  public enum Outcome: Equatable, Sendable {
    case items([EntryIntakeItem])
    /// Zotero is not running, or its local API is off.
    case unavailable
  }

  /// One pass: the first one only records the library version; later ones
  /// take items, notes and annotations added since (attachments are
  /// skipped: files are never read).
  public static func pass(
    transport: any ZoteroTransport, state: inout ZoteroWatchState, now: Date
  ) async -> Outcome {
    guard let base = state.libraryVersion else {
      guard
        let probe = try? await transport.get(
          "/api/users/0/items", query: [.init(name: "limit", value: "1")]),
        probe.status == 200, let version = probe.libraryVersion
      else { return .unavailable }
      state.libraryVersion = version
      return .items([])
    }
    var records: [ZoteroRecord] = []
    var newest = base
    var start = 0
    while start < maximumPerPass {
      guard
        let response = try? await transport.get(
          "/api/users/0/items",
          query: [
            .init(name: "since", value: String(base)), .init(name: "format", value: "json"),
            .init(name: "limit", value: String(pageSize)),
            .init(name: "start", value: String(start)),
          ]),
        response.status == 200
      else { return .unavailable }
      newest = max(newest, response.libraryVersion ?? newest)
      let page = parse(response.body)
      records += page
      guard page.count == pageSize else { break }
      start += pageSize
    }
    var taken = Set(state.taken)
    var parents: [String: ZoteroRecord] = [:]
    var items: [EntryIntakeItem] = []
    for record in records.sorted(by: {
      ($0.dateAdded ?? now, $0.key) < ($1.dateAdded ?? now, $1.key)
    })
    where !record.isAttachment && !taken.contains(record.key) {
      taken.insert(record.key)
      state.taken.append(record.key)
      let parent = await citedParent(of: record, transport: transport, cache: &parents)
      items.append(
        EntryIntakeItem(
          candidate: .text(
            ZoteroText.text(record, parent: parent), extractor: EntryExtractor.zoteroItem),
          source: EntrySource.named(EntrySource.zotero),
          capturedAt: min(record.dateAdded ?? now, now),
          id: EntryIdentity.itemID(.zotero, key: record.key)))
    }
    if state.taken.count > maximumRemembered {
      state.taken.removeFirst(state.taken.count - maximumRemembered)
    }
    state.libraryVersion = newest
    return .items(items)
  }

  /// The regular item a note or annotation belongs to (an annotation's
  /// parent is the attachment; its parent is the item), for the citation.
  static func citedParent(
    of record: ZoteroRecord, transport: any ZoteroTransport, cache: inout [String: ZoteroRecord]
  ) async -> ZoteroRecord? {
    var key = record.parentKey
    for _ in 0..<2 {
      guard let current = key, ZoteroKey.isValid(current) else { return nil }
      let parent: ZoteroRecord
      if let cached = cache[current] {
        parent = cached
      } else {
        guard
          let response = try? await transport.get(
            "/api/users/0/items/\(current)", query: [.init(name: "format", value: "json")]),
          response.status == 200,
          let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let fetched = ZoteroRecord(json: object)
        else { return nil }
        cache[current] = fetched
        parent = fetched
      }
      if parent.isRegular { return parent }
      key = parent.parentKey
    }
    return nil
  }

  static func parse(_ body: Data) -> [ZoteroRecord] {
    guard let array = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
      return []
    }
    return array.compactMap(ZoteroRecord.init(json:))
  }
}

enum ZoteroKey {
  /// Zotero keys are eight characters of `[23456789ABCDEFGHIJKLMNPQRSTUVWXYZ]`.
  static func isValid(_ key: String) -> Bool {
    key.count == 8 && key.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
  }
}
