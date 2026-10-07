import Foundation

/// The display guards (MAC-SPEC §13.2, §13.8): pure, deterministic rewrites
/// of organizer text so the Mac never shows an organizer defect as it is.
/// No model, no inference. Each rule is also a fix the organizer should make
/// at the source, so these rarely fire on real data. Autospace (the quarter
/// em between Chinese and Latin) is applied by the views, with the design
/// kit's `MLAutospace`, never here.
public enum MemoryDisplayText {
  /// Relative-date words that go stale once an item has an absolute date.
  static let relativeWords =
    #"(下下周|下周[一二三四五六日天]?|这周|本周|明早|明晚|明天|今晚|今天|后天|下个月|月底前?)"#

  /// 9/21 → 9月21日 (one date format in the UI). Scores such as 16/20 and
  /// full dates such as 2026/9/21 are left alone.
  public static func normalizedDates(_ text: String) -> String {
    let protected = #"(\d+/\d+/\d+|\d+/\d{3,})"#
    var result = ""
    var rest = Substring(text)
    while let range = rest.range(of: protected, options: .regularExpression) {
      result += monthDay(String(rest[..<range.lowerBound]))
      result += rest[range]
      rest = rest[range.upperBound...]
    }
    return result + monthDay(String(rest))
  }

  private static func monthDay(_ text: String) -> String {
    replace(#"(?<![\d/])(\d{1,2})/(\d{1,2})(?![\d/])"#, in: text) { groups in
      guard let a = Int(groups[1]), let b = Int(groups[2]), (1...12).contains(a), (1...31).contains(b)
      else { return groups[0] }
      return "\(a)月\(b)日"
    }
  }

  /// The owner's own name and 用户 in organizer text: 你, or dropped where it
  /// only opens the sentence ("林知远答应…" → "答应…" is dropped too).
  public static func withoutOwner(_ text: String, ownerNames: [String]) -> String {
    var s = text
    s = replace(#"^若用户同意"#, in: s) { _ in "若你同意" }
    s = replace(#"^用户需要?"#, in: s) { _ in "" }
    s = s.replacingOccurrences(of: "用户", with: "你")
    for name in ownerNames where !name.isEmpty {
      let escaped = NSRegularExpression.escapedPattern(for: name)
      s = replace("^" + escaped + "(答应|表示|让|给|找|将|按|完成|起草|拟好|拟|需|要|和|与)?", in: s) {
        groups in
        let verb = groups[1]
        return verb.isEmpty || ["答应", "表示", "需", "要"].contains(verb) ? "" : verb
      }
      s = s.replacingOccurrences(of: name + "一人", with: "你一人")
        .replacingOccurrences(of: name, with: "你")
    }
    return s
  }

  /// A step's, fact's or deadline's words as the UI shows them: the owner's
  /// name rewritten, dates normalised, stale relative words and the item's
  /// own date dropped (the UI shows the date once), 「…的截止日期」 → 「…截止」.
  public static func clean(
    _ text: String, date: DateComponents? = nil, inferred: Bool = true, openQuestion: Bool = false,
    ownerNames: [String] = []
  ) -> String {
    var t = normalizedDates(withoutOwner(text.trimmingCharacters(in: .whitespaces), ownerNames: ownerNames))
    if openQuestion || (date != nil && !inferred) {
      t = replace(relativeWords + #"（\d+月\d+日）"#, in: t) { _ in "" }
      t = replace(relativeWords, in: t) { _ in "" }
    }
    if let date, !inferred, let month = date.month, let day = date.day {
      t = replace("\(month)月\(day)[日号](前|那周)?", in: t) { _ in "" }
    }
    t = replace(#"的截止日期$"#, in: t) { _ in "" }
    t = replace(#"截止日期?$"#, in: t) { _ in "截止" }
    t = replace(#"(?<!截止)日期$"#, in: t) { _ in "" }
    t = replace(#"^[，、：:\s]+|[，、：:\s]+$"#, in: t) { _ in "" }
    t = replace(#"\s{2,}"#, in: t) { _ in " " }
    return t.isEmpty ? text : t
  }

  /// A step's label: `clean`, a leading 你 before 完/拟/起/写/交/发/改 dropped
  /// (「你完成…」 → 「完成…」), a question ending in 「？」.
  public static func stepLabel(
    _ text: String, kind: String, state: String, date: DateComponents?, inferred: Bool,
    ownerNames: [String]
  ) -> String {
    let open = kind == "question" && state == "open"
    var t = clean(
      text, date: date, inferred: inferred, openQuestion: open, ownerNames: ownerNames)
    t = replace(#"^你(?=[完拟起写交发改])"#, in: t) { _ in "" }
    if kind == "question", !(t.hasSuffix("？") || t.hasSuffix("?")) { t += "？" }
    return t
  }

  /// The one-line status: owner rewritten, dates normalised, a leading 「待你」
  /// dropped.
  public static func status(_ text: String, ownerNames: [String]) -> String {
    let s = normalizedDates(withoutOwner(text, ownerNames: ownerNames))
    return replace(#"^待你"#, in: s) { _ in "" }
  }

  /// A matter's or part's name: dates normalised and a CJK compound cut after
  /// its connector by the organizer's length cap repaired (「消融与」 → 「消融」).
  public static func name(_ text: String, ownerNames: [String]) -> String {
    var n = normalizedDates(text.trimmingCharacters(in: .whitespaces))
    // The owner's own name opening a title ("林知远的…").
    for owner in ownerNames where !owner.isEmpty && n.hasPrefix(owner) && n.count > owner.count + 1 {
      n = String(n.dropFirst(owner.count))
      if n.hasPrefix("的") { n = String(n.dropFirst()) }
    }
    n = replace(#"(与|和|及|、)[\x{4E00}-\x{9FA5}]?$"#, in: n) { _ in "" }
    return n.isEmpty ? text : n
  }

  /// The risk sentence (only for health level `risk`): the reason's clauses
  /// whose dates are not already in the status line, the first two joined by
  /// 「，」 (else the last clause), owner rewritten and dates normalised.
  public static func risk(reason: String, status: String, ownerNames: [String]) -> String? {
    let reasonText = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reasonText.isEmpty else { return nil }
    let statusDates = Set(matches(#"\d+月\d+日"#, in: Self.status(status, ownerNames: ownerNames)))
    let parts = reasonText.split(whereSeparator: { "，,；;".contains($0) })
      .map { normalizedDates(String($0).trimmingCharacters(in: .whitespaces)) }
      .filter { !$0.isEmpty }
    guard let last = parts.last else { return nil }
    let keep = parts.filter { Set(matches(#"\d+月\d+日"#, in: $0)).isDisjoint(with: statusDates) }
    let sentence = keep.isEmpty ? last : keep.prefix(2).joined(separator: "，")
    let result = withoutOwner(sentence, ownerNames: ownerNames)
    return result.isEmpty ? nil : result
  }

  // MARK: - Bigrams (matching words to parts and dates to items)

  static let genericWords = ["截止日期", "截止日", "截止", "提交", "日期", "之前", "前", "的", "需", "要", "完成"]

  /// Character bigrams of the CJK and Latin letters, with dates, digits and
  /// generic deadline words removed (`_bigrams` in the v9 guards).
  public static func bigrams(_ text: String) -> Set<String> {
    var s = replace(#"\d+月\d+日|\d+"#, in: text) { _ in "" }
    for word in genericWords { s = s.replacingOccurrences(of: word, with: "") }
    let letters = Array(s.filter { $0.isCJKIdeograph || ($0.isASCII && $0.isLetter) })
    guard letters.count >= 2 else { return [] }
    return Set((0..<(letters.count - 1)).map { String(letters[$0...($0 + 1)]) })
  }

  // MARK: - Status-line steps

  /// A dated next step written in a status line (「9月21日交回复信」).
  public struct StatusStep: Equatable, Sendable {
    public let date: DateComponents
    public let verb: String
    /// Written as a limit (「9月28日前确认」): it is due by that day, so it is
    /// overdue once the day has passed, whatever the verb.
    public var byDate = false
  }

  static let statusStepPattern =
    #"(\d{1,2})月(\d{1,2})日(前)?(交|签|截止|确认|注册|答辩|提交|回复)([^，,。；]*)"#
  static let pastStepPattern = #"(\d{1,2})月(\d{1,2})日(前)?(截稿|投稿|截止|提交|交|报名)([^，,。；]*)"#
  static let deadlineVerb = #"截止|截稿|投稿|提交|交|报名|ddl"#

  /// The dated steps of a status line: the next-step verbs (this year unless
  /// the date is more than two months back, then next year), plus deadline
  /// verbs whose date passed within the last `overdueDays` (year as today's).
  public static func statusSteps(
    _ status: String, today: DateComponents, overdueDays: Int = 7, calendar: Calendar
  ) -> [StatusStep] {
    guard let year = today.year, let month = today.month, let day = today.day,
      let todayDate = calendar.date(from: today)
    else { return [] }
    var result: [StatusStep] = []
    for groups in allGroups(statusStepPattern, in: status) {
      guard let mo = Int(groups[1]), let da = Int(groups[2]) else { continue }
      let y = (mo, da) >= (month, day) || mo >= month - 2 ? year : year + 1
      let components = DateComponents(year: y, month: mo, day: da)
      guard isValid(components, calendar: calendar) else { continue }
      result.append(
        StatusStep(
          date: components, verb: (groups[4] + groups[5]).trimmingCharacters(in: .whitespaces),
          byDate: !groups[3].isEmpty))
    }
    for groups in allGroups(pastStepPattern, in: status) {
      guard let mo = Int(groups[1]), let da = Int(groups[2]) else { continue }
      let components = DateComponents(year: year, month: mo, day: da)
      guard isValid(components, calendar: calendar), let date = calendar.date(from: components)
      else { continue }
      let back = calendar.dateComponents([.day], from: date, to: todayDate).day ?? 0
      guard back > 0, back <= overdueDays else { continue }
      result.append(
        StatusStep(
          date: components, verb: (groups[4] + groups[5]).trimmingCharacters(in: .whitespaces),
          byDate: !groups[3].isEmpty))
    }
    return result
  }

  static func isDeadlineVerb(_ verb: String) -> Bool {
    verb.range(of: deadlineVerb, options: .regularExpression) != nil
  }

  private static func isValid(_ components: DateComponents, calendar: Calendar) -> Bool {
    guard let date = calendar.date(from: components) else { return false }
    let back = calendar.dateComponents([.year, .month, .day], from: date)
    return back.month == components.month && back.day == components.day
  }

  // MARK: - Regex helpers

  static func replace(
    _ pattern: String, in text: String, with transform: ([String]) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let ns = text as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      result += transform(groups(match, in: ns))
      cursor = match.range.location + match.range.length
    }
    return result + ns.substring(from: cursor)
  }

  static func allGroups(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
      groups($0, in: ns)
    }
  }

  static func matches(_ pattern: String, in text: String) -> [String] {
    allGroups(pattern, in: text).map { $0[0] }
  }

  private static func groups(_ match: NSTextCheckingResult, in text: NSString) -> [String] {
    (0..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      return range.location == NSNotFound ? "" : text.substring(with: range)
    }
  }
}

extension Character {
  /// A CJK unified ideograph (the 一 – 龥 range the guards use).
  var isCJKIdeograph: Bool {
    unicodeScalars.first.map { (0x4E00...0x9FA5).contains($0.value) } ?? false
  }
}
