import Foundation

// MARK: - Wikipedia

/// Wikipedia's page summary by a public name (the REST API asks programs to
/// name themselves in the User-Agent, which the egress does).
public enum WikipediaSource {
  public struct Summary: Sendable, Equatable {
    public var title: String
    public var extract: String
    public var description: String?
    public var pageURL: URL
    public var timestamp: String?
  }

  public static func request(name: String, chinese: Bool) -> EgressRequest {
    let language = chinese ? "zh" : "en"
    let title = name.replacingOccurrences(of: " ", with: "_")
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#;")
    let path = title.addingPercentEncoding(withAllowedCharacters: allowed) ?? title
    var headers = ["Accept": "application/json"]
    if chinese { headers["Accept-Language"] = "zh-hans" }
    return EgressRequest(
      url: URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(path)")!,
      headers: headers, kind: .publicSource, service: PublicSourceID.wikipedia.rawValue,
      maximumBytes: 512 * 1024, timeout: 15, followRedirects: true)
  }

  /// A standard article's summary; nil for a disambiguation page, a missing
  /// page or anything else.
  public static func parse(_ data: Data) -> Summary? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (object["type"] as? String) == "standard",
      let title = object["title"] as? String,
      let extract = object["extract"] as? String, !extract.isEmpty,
      let page = ((object["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String,
      let url = URL(string: page)
    else { return nil }
    return Summary(
      title: title, extract: extract, description: object["description"] as? String, pageURL: url,
      timestamp: object["timestamp"] as? String)
  }
}

// MARK: - OpenStreetMap

/// OpenStreetMap's Nominatim by a public place name: at most one request a
/// second, answers cached, the program named, no type-ahead
/// (https://operations.osmfoundation.org/policies/nominatim/).
public enum OpenStreetMapSource {
  public struct Place: Sendable, Equatable {
    public var name: String
    public var address: String
    public var openingHours: String?
    public var website: String?
    public var pageURL: URL
    /// The data licence as OpenStreetMap states it (ODbL asks for it).
    public var licence: String?

    /// The item text. No phone number or e-mail is kept.
    public var text: String {
      var lines = [name, "地址：" + address]
      if let openingHours, !openingHours.isEmpty { lines.append("营业时间：" + openingHours) }
      if let website, !website.isEmpty { lines.append("网站：" + website) }
      lines.append(licence ?? "Data © OpenStreetMap contributors, ODbL 1.0. https://osm.org/copyright")
      return lines.joined(separator: "\n")
    }
  }

  public static func request(name: String) -> EgressRequest {
    var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
    components.queryItems = [
      URLQueryItem(name: "q", value: name), URLQueryItem(name: "format", value: "jsonv2"),
      URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "extratags", value: "1"),
      URLQueryItem(name: "accept-language", value: "zh-CN,en"),
    ]
    return EgressRequest(
      url: components.url!, headers: ["Accept": "application/json"], kind: .publicSource,
      service: PublicSourceID.openStreetMap.rawValue, maximumBytes: 256 * 1024, timeout: 15)
  }

  public static func parse(_ data: Data) -> Place? {
    guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      let row = rows.first, let display = row["display_name"] as? String,
      let osmType = row["osm_type"] as? String, let osmID = row["osm_id"]
    else { return nil }
    let tags = row["extratags"] as? [String: Any] ?? [:]
    let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? display.components(separatedBy: ",").first ?? display
    return Place(
      name: name, address: display, openingHours: tags["opening_hours"] as? String,
      website: (tags["website"] as? String) ?? (tags["contact:website"] as? String),
      pageURL: URL(string: "https://www.openstreetmap.org/\(osmType)/\(osmID)")!, licence: row["licence"] as? String)
  }
}
