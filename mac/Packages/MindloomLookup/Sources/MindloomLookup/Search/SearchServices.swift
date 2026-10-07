import Foundation

/// The search services with a key (WEBSEARCH §4.2, second layer), in the
/// fallback order. Google's and Bing's own web-search APIs no longer take
/// new customers or forbid storing results (WEBSEARCH §0); grounding
/// services and result-page scrapers are left out on purpose (§4.2 table).
public enum SearchServiceID: String, Codable, Sendable, CaseIterable, Identifiable {
  case brave
  case tavily
  case exa
  case perplexity
  case baidu
  case bocha
  case zhipu

  public var id: String { rawValue }

  /// Brand names, as each service writes its own.
  public var displayName: String {
    switch self {
    case .brave: "Brave"
    case .tavily: "Tavily"
    case .exa: "Exa"
    case .perplexity: "Perplexity"
    case .baidu: "百度千帆"
    case .bocha: "博查"
    case .zhipu: "智谱"
    }
  }

  /// Reachable from mainland China.
  public var isDomestic: Bool {
    switch self {
    case .baidu, .bocha, .zhipu: true
    default: false
    }
  }

  public var host: String {
    switch self {
    case .brave: "api.search.brave.com"
    case .tavily: "api.tavily.com"
    case .exa: "api.exa.ai"
    case .perplexity: "api.perplexity.ai"
    case .baidu: "qianfan.baidubce.com"
    case .bocha: "api.bochaai.com"
    case .zhipu: "open.bigmodel.cn"
    }
  }

  /// Where the owner signs up and gets a key.
  public var signUpURL: URL {
    switch self {
    case .brave: URL(string: "https://api-dashboard.search.brave.com/")!
    case .tavily: URL(string: "https://app.tavily.com/")!
    case .exa: URL(string: "https://dashboard.exa.ai/")!
    case .perplexity: URL(string: "https://www.perplexity.ai/account/api")!
    case .baidu: URL(string: "https://console.bce.baidu.com/qianfan/")!
    case .bocha: URL(string: "https://open.bochaai.com/")!
    case .zhipu: URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/apikeys")!
    }
  }

  /// WEBSEARCH §4.2: Brave, Tavily, Exa, Perplexity, then the domestic ones.
  public static let fallbackOrder: [SearchServiceID] = [.brave, .tavily, .exa, .perplexity, .baidu, .bocha, .zhipu]

  /// The order for one query: a subject written in Chinese starts with the
  /// domestic services (chosen by the words, never by probing the network).
  public static func order(chineseFirst: Bool) -> [SearchServiceID] {
    guard chineseFirst else { return fallbackOrder }
    return fallbackOrder.filter(\.isDomestic) + fallbackOrder.filter { !$0.isDomestic }
  }

  /// The service a pasted key most likely belongs to, from its shape alone
  /// (nothing is sent): Settings preselects it, the owner confirms. A key
  /// only ever goes to the service the owner chose.
  public static func likelyService(forKey key: String) -> SearchServiceID? {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.hasPrefix("tvly-") { return .tavily }
    if key.hasPrefix("pplx-") { return .perplexity }
    if key.hasPrefix("BSA") { return .brave }
    if key.hasPrefix("bce-v3/") { return .baidu }
    if key.range(of: #"^[0-9a-f]{32}\.[A-Za-z0-9]{16}$"#, options: .regularExpression) != nil { return .zhipu }
    if key.range(of: #"^sk-[0-9a-f]{32}$"#, options: .regularExpression) != nil { return .bocha }
    if key.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil {
      return .exa
    }
    return nil
  }

  /// A pasted key looks like a key at all (one line, printable, not absurd).
  public static func isPlausibleKey(_ key: String) -> Bool {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (8...512).contains(key.count) else { return false }
    return key.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
  }
}

/// One search result. Only the address, title and rank are kept; snippets
/// are not stored (WEBSEARCH §4.3: Brave's terms sell storage separately).
public struct SearchHit: Codable, Sendable, Hashable {
  public var title: String
  public var url: URL
  public var rank: Int
  public var published: String?

  public init(title: String, url: URL, rank: Int, published: String? = nil) {
    self.title = title
    self.url = url
    self.rank = rank
    self.published = published
  }
}

public enum SearchFailure: Error, Sendable, Equatable {
  case badKey
  case quotaUsed
  case rateLimited(retryAfter: TimeInterval?)
  case server
  case malformed
}

public enum SearchReply: Sendable, Equatable {
  case hits([SearchHit])
  case failure(SearchFailure)
}

/// Each service's request and answer.
public enum SearchAdapter {
  public static let resultCount = 10

  public static func request(_ service: SearchServiceID, terms: String, key: String) -> EgressRequest {
    let json = ["Content-Type": "application/json", "Accept": "application/json"]
    let bearer = json.merging(["Authorization": "Bearer \(key)"]) { $1 }
    func post(_ url: String, _ body: [String: Any], _ headers: [String: String]) -> EgressRequest {
      EgressRequest(
        url: URL(string: url)!, method: "POST", headers: headers,
        body: try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
        kind: .search, service: service.rawValue, maximumBytes: 2 * 1024 * 1024, timeout: 15)
    }
    switch service {
    case .brave:
      var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
      components.queryItems = [
        URLQueryItem(name: "q", value: terms), URLQueryItem(name: "count", value: String(resultCount)),
      ]
      return EgressRequest(
        url: components.url!, headers: ["Accept": "application/json", "X-Subscription-Token": key],
        kind: .search, service: service.rawValue, maximumBytes: 2 * 1024 * 1024, timeout: 15)
    case .tavily:
      return post(
        "https://api.tavily.com/search",
        ["query": terms, "max_results": resultCount, "search_depth": "basic", "include_answer": false],
        bearer)
    case .exa:
      return post(
        "https://api.exa.ai/search", ["query": terms, "numResults": resultCount],
        json.merging(["x-api-key": key]) { $1 })
    case .perplexity:
      return post("https://api.perplexity.ai/search", ["query": terms, "max_results": resultCount], bearer)
    case .baidu:
      return post(
        "https://qianfan.baidubce.com/v2/ai_search/web_search",
        [
          "messages": [["role": "user", "content": terms]], "search_source": "baidu_search_v2",
          "resource_type_filter": [["type": "web", "top_k": resultCount]],
        ], bearer)
    case .bocha:
      return post(
        "https://api.bochaai.com/v1/web-search",
        ["query": terms, "summary": false, "count": resultCount, "freshness": "noLimit"], bearer)
    case .zhipu:
      return post(
        "https://open.bigmodel.cn/api/paas/v4/web_search",
        ["search_query": terms, "search_engine": "search_std", "search_intent": false, "count": resultCount],
        bearer)
    }
  }

  /// The answer: results, or which failure (decides whether and for how
  /// long the service is skipped).
  public static func interpret(_ service: SearchServiceID, status: Int, headers: [String: String], body: Data)
    -> SearchReply
  {
    switch status {
    case 200...299: break
    case 401, 403: return .failure(service == .bocha && status == 403 ? .quotaUsed : .badKey)
    case 402: return .failure(.quotaUsed)
    case 429: return .failure(.rateLimited(retryAfter: retryAfter(headers)))
    case 400...499:
      // Brave answers an invalid key with 422 SUBSCRIPTION_TOKEN_INVALID
      // (checked live 2026-10-06); other services name the reason in the body.
      return .failure(errorBodyFailure(body, headers: headers) ?? .server)
    default: return .failure(.server)
    }
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return .failure(.malformed)
    }
    if let failure = bodyFailure(service, object) { return .failure(failure) }
    let rows: [[String: Any]]?
    var titleKey = "title"
    var urlKey = "url"
    var dateKey: String?
    switch service {
    case .brave:
      rows = ((object["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? (object["web"] == nil ? [] : nil)
      dateKey = "page_age"
    case .tavily:
      rows = object["results"] as? [[String: Any]]
      dateKey = "published_date"
    case .exa:
      rows = object["results"] as? [[String: Any]]
      dateKey = "publishedDate"
    case .perplexity:
      rows = object["results"] as? [[String: Any]]
      dateKey = "date"
    case .baidu:
      rows = (object["references"] as? [[String: Any]])?.filter { ($0["type"] as? String ?? "web") == "web" }
      dateKey = "date"
    case .bocha:
      let data = object["data"] as? [String: Any]
      rows = ((data?["webPages"] as? [String: Any])?["value"] as? [[String: Any]]) ?? (data == nil ? nil : [])
      titleKey = "name"
      dateKey = "datePublished"
    case .zhipu:
      rows = object["search_result"] as? [[String: Any]] ?? (object["id"] != nil ? [] : nil)
      urlKey = "link"
      dateKey = "publish_date"
    }
    guard let rows else { return .failure(.malformed) }
    var hits: [SearchHit] = []
    var seen: Set<String> = []
    for row in rows {
      guard let address = row[urlKey] as? String, let url = URL(string: address),
        let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil,
        seen.insert(url.absoluteString).inserted
      else { continue }
      let title = (row[titleKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      hits.append(
        SearchHit(
          title: title, url: url, rank: hits.count + 1, published: dateKey.flatMap { row[$0] as? String }))
    }
    return .hits(hits)
  }

  /// The reason a 4xx error body gives: `{"error": {"code": "SUBSCRIPTION_TOKEN_INVALID",
  /// "meta": {"component": "authentication"}}}` (Brave), or a top-level `code`.
  static func errorBodyFailure(_ body: Data, headers: [String: String]) -> SearchFailure? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    let error = object["error"] as? [String: Any]
    let code = "\(error?["code"] ?? object["code"] ?? "")".uppercased()
    let meta = (error?["meta"] as? [String: Any]) ?? (object["meta"] as? [String: Any])
    let component = "\(meta?["component"] ?? "")".lowercased()
    if component == "authentication" || code.contains("TOKEN_INVALID") || code.contains("INVALID_API_KEY")
      || code.contains("INVALID_KEY") || code.contains("UNAUTHORIZED") || code.contains("AUTHENTICATION")
    {
      return .badKey
    }
    if code.contains("RATE_LIMIT") { return .rateLimited(retryAfter: retryAfter(headers)) }
    if code.contains("QUOTA") || code.contains("USAGE_LIMIT") || code.contains("INSUFFICIENT") {
      return .quotaUsed
    }
    return nil
  }

  /// Services that report errors inside a 200 answer.
  static func bodyFailure(_ service: SearchServiceID, _ object: [String: Any]) -> SearchFailure? {
    switch service {
    case .bocha:
      guard let code = (object["code"] as? Int) ?? Int(object["code"] as? String ?? ""), code != 200 else {
        return nil
      }
      switch code {
      case 401: return .badKey
      case 403: return .quotaUsed
      case 429: return .rateLimited(retryAfter: nil)
      default: return .server
      }
    case .baidu:
      guard object["references"] == nil, let code = object["code"] else { return nil }
      let message = ((object["message"] as? String) ?? "").lowercased()
      let codeText = "\(code)".lowercased()
      if message.contains("auth") || message.contains("token") || message.contains("key")
        || codeText.contains("401") || codeText.contains("auth")
      {
        return .badKey
      }
      if message.contains("quota") || message.contains("limit") || message.contains("balance")
        || message.contains("arrear")
      {
        return .quotaUsed
      }
      return .server
    case .zhipu:
      guard let error = object["error"] as? [String: Any] else { return nil }
      let code = "\(error["code"] ?? "")"
      switch code {
      case "1000", "1001", "1002", "1003", "1004": return .badKey
      case "1113": return .quotaUsed
      case "1302", "1303", "1305": return .rateLimited(retryAfter: nil)
      default: return .server
      }
    default:
      return nil
    }
  }

  static func retryAfter(_ headers: [String: String]) -> TimeInterval? {
    guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value
      .trimmingCharacters(in: .whitespaces)
    else { return nil }
    if let seconds = TimeInterval(value) { return seconds }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
  }
}
