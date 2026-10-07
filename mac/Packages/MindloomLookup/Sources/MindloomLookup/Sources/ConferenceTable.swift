import Foundation

/// The ccf-deadlines conference table (MIT; https://github.com/ccfddl/ccf-
/// deadlines), downloaded whole and matched on this device: the download
/// says nothing about which conference the owner cares about
/// (MATTER-MINIMUM §7.1).
public enum ConferenceTableSource {
  public static let url = URL(string: "https://ccfddl.com/conference/allconf.yml")!

  public struct Conference: Sendable, Equatable {
    public var title: String
    public var description: String
    public var dblp: String?
    public var editions: [Edition]
  }

  public struct Edition: Sendable, Equatable {
    public var year: Int
    public var link: String?
    public var timeline: [Milestone]
    public var timezone: String?
    public var date: String?
    public var place: String?
  }

  public struct Milestone: Sendable, Equatable {
    public var abstractDeadline: String?
    public var deadline: String?
    public var rebuttalDeadline: String?
    public var decisionDeadline: String?
    public var comment: String?
  }

  /// One deadline with its moment, when the table gives one.
  public struct Deadline: Sendable, Equatable {
    public enum Kind: String, Sendable { case abstract, paper, rebuttal, decision }
    public var kind: Kind
    /// As written in the table (「2026-05-11 23:59:59」).
    public var written: String
    public var timezone: String?
    public var moment: Date?
    public var comment: String?
  }

  public static func request() -> EgressRequest {
    EgressRequest(
      url: url, headers: ["Accept": "text/yaml, text/plain"], kind: .conferenceTable,
      service: PublicSourceID.conferenceTable.rawValue, maximumBytes: 8 * 1024 * 1024, timeout: 30)
  }

  public static func parse(_ data: Data) -> [Conference] {
    guard let text = String(data: data, encoding: .utf8), case .list(let items) = MiniYAML.parse(text) else {
      return []
    }
    return items.compactMap { item -> Conference? in
      guard case .map(let fields) = item, let title = fields["title"]?.string else { return nil }
      let editions = (fields["confs"]?.list ?? []).compactMap { value -> Edition? in
        guard case .map(let conf) = value, let year = conf["year"]?.string.flatMap({ Int($0) }) else {
          return nil
        }
        let timeline = (conf["timeline"]?.list ?? []).compactMap { entry -> Milestone? in
          guard case .map(let row) = entry else { return nil }
          return Milestone(
            abstractDeadline: row["abstract_deadline"]?.string, deadline: row["deadline"]?.string,
            rebuttalDeadline: row["rebuttal_deadline"]?.string, decisionDeadline: row["decision_deadline"]?.string,
            comment: row["comment"]?.string)
        }
        return Edition(
          year: year, link: conf["link"]?.string, timeline: timeline, timezone: conf["timezone"]?.string,
          date: conf["date"]?.string, place: conf["place"]?.string)
      }
      return Conference(
        title: title, description: fields["description"]?.string ?? "", dblp: fields["dblp"]?.string,
        editions: editions)
    }
  }

  /// The conference named `name` (its short title, full name or DBLP key)
  /// and the edition for `year`; without a year, the next edition with a
  /// deadline still ahead, else the latest.
  public static func match(_ conferences: [Conference], name: String, year: Int?, now: Date = Date())
    -> (Conference, Edition)?
  {
    let key = PublicNameDirectory.normalized(name)
    guard !key.isEmpty,
      let conference = conferences.first(where: {
        PublicNameDirectory.normalized($0.title) == key || PublicNameDirectory.normalized($0.description) == key
          || ($0.dblp.map(PublicNameDirectory.normalized) == key)
      })
    else { return nil }
    if let year {
      guard let edition = conference.editions.first(where: { $0.year == year }) else { return nil }
      return (conference, edition)
    }
    let upcoming = conference.editions.filter { edition in
      deadlines(of: edition).contains { ($0.moment ?? .distantPast) > now }
    }
    if let next = upcoming.min(by: { $0.year < $1.year }) { return (conference, next) }
    guard let latest = conference.editions.max(by: { $0.year < $1.year }) else { return nil }
    return (conference, latest)
  }

  public static func deadlines(of edition: Edition) -> [Deadline] {
    var result: [Deadline] = []
    for milestone in edition.timeline {
      let rows: [(Deadline.Kind, String?)] = [
        (.abstract, milestone.abstractDeadline), (.paper, milestone.deadline),
        (.rebuttal, milestone.rebuttalDeadline), (.decision, milestone.decisionDeadline),
      ]
      for (kind, written) in rows {
        guard let written, !written.isEmpty else { continue }
        result.append(
          Deadline(
            kind: kind, written: written, timezone: edition.timezone,
            moment: moment(written, timezone: edition.timezone), comment: milestone.comment))
      }
    }
    return result
  }

  /// 「2026-05-11 23:59:59」 in 「AoE」 (UTC−12), 「UTC-8」, 「UTC+0」 or 「PT」.
  static func moment(_ written: String, timezone: String?) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    switch timezone?.trimmingCharacters(in: .whitespaces) {
    case nil, "AoE", "": formatter.timeZone = TimeZone(secondsFromGMT: -12 * 3600)
    case "PT": formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
    case let zone?:
      let offset = zone.replacingOccurrences(of: "UTC", with: "")
      guard let hours = Int(offset.isEmpty ? "0" : offset) else { return nil }
      formatter.timeZone = TimeZone(secondsFromGMT: hours * 3600)
    }
    return formatter.date(from: written.trimmingCharacters(in: .whitespaces))
  }

  /// The item text for one edition, every value as the table writes it.
  public static func text(_ conference: Conference, _ edition: Edition) -> String {
    var lines = ["\(conference.title) \(edition.year)（\(conference.description)）"]
    let zone = edition.timezone.map { " " + $0 } ?? ""
    for milestone in edition.timeline {
      if let value = milestone.abstractDeadline { lines.append("摘要截止：\(value)\(zone)") }
      if let value = milestone.deadline { lines.append("论文截止：\(value)\(zone)") }
      if let value = milestone.rebuttalDeadline { lines.append("答辩截止：\(value)\(zone)") }
      if let value = milestone.decisionDeadline { lines.append("录用通知：\(value)\(zone)") }
      if let comment = milestone.comment { lines.append("说明：\(comment)") }
    }
    if let date = edition.date { lines.append("会议日期：\(date)") }
    if let place = edition.place { lines.append("地点：\(place)") }
    if let link = edition.link { lines.append("网站：\(link)") }
    return lines.joined(separator: "\n")
  }

  /// Every conference's short and full name, with its official site.
  public static func names(_ conferences: [Conference]) -> PublicNameDirectory {
    var directory = PublicNameDirectory()
    for conference in conferences {
      let site = conference.editions.max(by: { $0.year < $1.year })?.link.flatMap { URL(string: $0)?.host }
      directory.add(conference.title, kind: .conference, officialSite: site, source: .conferenceTable)
      if !conference.description.isEmpty {
        directory.add(conference.description, kind: .conference, officialSite: site, source: .conferenceTable)
      }
    }
    return directory
  }
}

/// The YAML the table is written in (block maps and lists, plain and
/// quoted scalars, multi-line scalars); not a general YAML parser.
enum MiniYAML: Equatable {
  case string(String)
  case list([MiniYAML])
  case map([String: MiniYAML])

  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var list: [MiniYAML]? {
    if case .list(let value) = self { return value }
    return nil
  }

  struct Line {
    var indent: Int
    var text: Substring
  }

  static func parse(_ source: String) -> MiniYAML {
    var lines: [Line] = []
    for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
      let content = line.drop(while: { $0 == " " })
      if content.isEmpty || content.hasPrefix("#") || content == "---" { continue }
      lines.append(Line(indent: line.count - content.count, text: content))
    }
    var index = 0
    guard !lines.isEmpty else { return .map([:]) }
    return block(&lines, &index, indent: lines[0].indent)
  }

  private static func isItem(_ text: Substring) -> Bool { text == "-" || text.hasPrefix("- ") }

  private static func block(_ lines: inout [Line], _ index: inout Int, indent: Int) -> MiniYAML {
    guard index < lines.count else { return .string("") }
    return isItem(lines[index].text) ? list(&lines, &index, indent: indent) : map(&lines, &index, indent: indent)
  }

  private static func list(_ lines: inout [Line], _ index: inout Int, indent: Int) -> MiniYAML {
    var items: [MiniYAML] = []
    while index < lines.count, lines[index].indent == indent, isItem(lines[index].text) {
      let rest = lines[index].text.dropFirst(min(2, lines[index].text.count))
      if rest.isEmpty {
        index += 1
        if index < lines.count, lines[index].indent > indent {
          let childIndent = lines[index].indent
          items.append(block(&lines, &index, indent: childIndent))
        } else {
          items.append(.string(""))
        }
      } else if keyValue(rest) != nil {
        // The item is a map whose first key sits after the dash.
        lines[index] = Line(indent: indent + 2, text: rest)
        items.append(map(&lines, &index, indent: indent + 2))
      } else {
        index += 1
        items.append(.string(scalar(rest, &lines, &index, parentIndent: indent)))
      }
    }
    return .list(items)
  }

  private static func map(_ lines: inout [Line], _ index: inout Int, indent: Int) -> MiniYAML {
    var fields: [String: MiniYAML] = [:]
    while index < lines.count, lines[index].indent == indent, !isItem(lines[index].text),
      let pair = keyValue(lines[index].text)
    {
      let (key, value) = pair
      index += 1
      if value.isEmpty {
        if index < lines.count, lines[index].indent > indent {
          let childIndent = lines[index].indent
          fields[key] = block(&lines, &index, indent: childIndent)
        } else if index < lines.count, lines[index].indent == indent, isItem(lines[index].text) {
          fields[key] = list(&lines, &index, indent: indent)
        } else {
          fields[key] = .string("")
        }
      } else {
        fields[key] = .string(scalar(value, &lines, &index, parentIndent: indent))
      }
    }
    return .map(fields)
  }

  /// 「key: value」 → (key, value); nil when the line is not a mapping.
  private static func keyValue(_ text: Substring) -> (String, Substring)? {
    if text.first == "'" || text.first == "\"" { return nil }
    if text.hasSuffix(":"), !text.contains(": ") { return (String(text.dropLast()), "") }
    guard let range = text.range(of: ": ") else { return nil }
    let key = text[..<range.lowerBound]
    guard !key.isEmpty, !key.contains(" #") else { return nil }
    return (String(key), text[range.upperBound...].drop(while: { $0 == " " }))
  }

  /// A scalar and its continuation lines (more indented than its key).
  private static func scalar(_ first: Substring, _ lines: inout [Line], _ index: inout Int, parentIndent: Int)
    -> String
  {
    var parts = [String(first)]
    while index < lines.count, lines[index].indent > parentIndent {
      parts.append(String(lines[index].text))
      index += 1
    }
    let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    if joined.count >= 2, joined.hasPrefix("'"), joined.hasSuffix("'") {
      return String(joined.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    if joined.count >= 2, joined.hasPrefix("\""), joined.hasSuffix("\"") {
      return String(joined.dropFirst().dropLast())
        .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
    return joined
  }
}
