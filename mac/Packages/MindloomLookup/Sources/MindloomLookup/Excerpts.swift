import Foundation

/// What a model reads of a page, and how its answer is checked
/// (WEBSEARCH §4.4 last paragraph, §4.5; MATTER-MINIMUM §7.2 step 6).
public enum Excerpts {
  public static let maximumCharacters = 2_000

  /// Words that mark a passage as being about a gap.
  public static func keywords(for gap: LookupGap) -> [String] {
    switch gap {
    case .deadline:
      ["deadline", "due", "submission", "abstract", "registration", "截止", "提交", "摘要", "投稿", "报名"]
    case .callForPapers: ["call for papers", "cfp", "submission", "topics", "征稿", "投稿", "主题"]
    case .eventDates: ["dates", "venue", "location", "held", "conference", "时间", "地点", "举办", "召开"]
    case .paperInfo: ["authors", "abstract", "published", "作者", "摘要", "发表"]
    case .address: ["address", "located", "地址", "位于"]
    case .openingHours: ["hours", "open", "closed", "营业时间", "开放时间", "开放"]
    case .specification: ["specifications", "specs", "memory", "processor", "dimensions", "weight", "规格", "参数", "配置"]
    case .price: ["price", "pricing", "usd", "$", "价格", "售价", "元"]
    case .publicNotice: ["notice", "application", "deadline", "通知", "申报", "截止", "公告"]
    case .overview: []
    }
  }

  /// The focus words for a request: the subject's name, the year and the
  /// gap's keywords.
  public static func focus(for request: LookupRequest) -> [String] {
    var words: [String] = []
    if let name = request.subject?.name.trimmingCharacters(in: .whitespaces), !name.isEmpty { words.append(name) }
    if let year = request.year { words.append(String(year)) }
    return words + keywords(for: request.gap)
  }

  /// The passages of `text` about `focus`, each a verbatim line or sentence
  /// of it, in page order, joined by 「\n…\n」 where they are not adjacent.
  /// Without focus (or without a hit), the opening of the page.
  public static func select(from text: String, focus: [String], maximumCharacters: Int = maximumCharacters)
    -> String
  {
    let segments = segments(of: text)
    guard !segments.isEmpty else { return "" }
    let lowered = focus.map { $0.lowercased() }.filter { !$0.isEmpty }
    let name = lowered.first
    var scores = Array(repeating: 0, count: segments.count)
    if !lowered.isEmpty {
      for (index, segment) in segments.enumerated() {
        let line = segment.lowercased()
        var score = 0
        if let name, line.contains(name) { score += 3 }
        let hits = lowered.dropFirst().filter { line.contains($0) }.count
        score += min(hits, 3) * 2
        if line.contains(where: \.isNumber) { score += 1 }
        scores[index] = score
      }
    }
    var chosen = Set<Int>()
    if scores.contains(where: { $0 >= 3 }) {
      var used = 0
      for index in scores.indices.sorted(by: { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 < $1) })
      where scores[index] >= 3 {
        var wanted = [index]
        // A neighbouring line that says something of its own comes along.
        if scores[index] >= 5 {
          wanted += [index - 1, index + 1].filter { segments.indices.contains($0) && scores[$0] >= 1 }
        }
        for candidate in wanted where !chosen.contains(candidate) {
          let size = segments[candidate].count + 2
          guard used + size <= maximumCharacters else { continue }
          chosen.insert(candidate)
          used += size
        }
        if used >= maximumCharacters { break }
      }
    }
    if chosen.isEmpty {
      if !lowered.isEmpty, focus.count > 1 { return "" }
      var used = 0
      for index in segments.indices {
        let size = segments[index].count + 2
        guard used + size <= maximumCharacters else { break }
        chosen.insert(index)
        used += size
      }
    }
    var output = ""
    var previous: Int?
    for index in chosen.sorted() {
      if let previous { output += index == previous + 1 ? "\n" : "\n…\n" }
      output += segments[index]
      previous = index
    }
    return output
  }

  /// Lines, with long lines split into sentences; each a verbatim run of
  /// the text.
  static func segments(of text: String) -> [String] {
    var result: [String] = []
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      if trimmed.count <= 400 {
        result.append(trimmed)
        continue
      }
      var sentence = ""
      for character in trimmed {
        sentence.append(character)
        if "。！？!?".contains(character) || (character == "." && sentence.count > 40) {
          let piece = sentence.trimmingCharacters(in: .whitespaces)
          if !piece.isEmpty { result.append(piece) }
          sentence = ""
        }
      }
      let rest = sentence.trimmingCharacters(in: .whitespaces)
      if !rest.isEmpty { result.append(rest) }
    }
    return result
  }

  /// Where `quote` occurs in `text`, ignoring how whitespace is written; a
  /// range of Unicode scalar offsets in `text`, or nil.
  public static func locate(_ quote: String, in text: String) -> Range<Int>? {
    func squeeze(_ value: String) -> (scalars: [Unicode.Scalar], origin: [Int]) {
      var scalars: [Unicode.Scalar] = []
      var origin: [Int] = []
      var pendingSpace = false
      for (offset, scalar) in value.unicodeScalars.enumerated() {
        if scalar.properties.isWhitespace {
          pendingSpace = !scalars.isEmpty
          continue
        }
        if pendingSpace {
          scalars.append(" ")
          origin.append(offset)
          pendingSpace = false
        }
        scalars.append(scalar)
        origin.append(offset)
      }
      return (scalars, origin)
    }
    let needle = squeeze(quote).scalars
    let hay = squeeze(text)
    guard !needle.isEmpty, needle.count <= hay.scalars.count else { return nil }
    let last = hay.scalars.count - needle.count
    var start = 0
    while start <= last {
      if hay.scalars[start] == needle[0] {
        var matched = true
        for k in 1..<needle.count where hay.scalars[start + k] != needle[k] {
          matched = false
          break
        }
        if matched {
          return hay.origin[start]..<(hay.origin[start + needle.count - 1] + 1)
        }
      }
      start += 1
    }
    return nil
  }

  /// A fact from the web counts only when its quote is verbatim in the
  /// source and the source's text names the subject (and the year, when
  /// there is one); otherwise it is "not found" (MATTER-MINIMUM §7.2 step 6).
  /// The title is not consulted: only the visible text is evidence.
  public static func verify(quote: String, in item: WebSourceItem, subject: String?, year: Int?) -> Range<Int>? {
    guard let range = locate(quote, in: item.text) else { return nil }
    if let subject, !subject.isEmpty, item.text.range(of: subject, options: [.caseInsensitive]) == nil {
      return nil
    }
    if let year, !item.text.contains(String(year)) { return nil }
    return range
  }
}
