import Foundation

/// The product's clock for search and history: the time zone the user lives
/// in (10/5: Asia/Singapore), weeks starting on Monday. Time words, day
/// headers and the default "now" all use it, not the Mac's own zone.
public struct SearchClock: Sendable {
  /// The product time zone: Asia/Singapore until the App sets the library's
  /// own (ALIGNMENT 根-13: stored in the library, changed in 通用 › 时区), so
  /// 历史's day headers and time words count days where Home does.
  public static var productTimeZone: TimeZone {
    zoneLock.lock()
    defer { zoneLock.unlock() }
    return zone
  }

  /// Makes `zone` the product time zone (the App, at launch and when the
  /// owner changes it).
  public static func setProductTimeZone(_ zone: TimeZone) {
    zoneLock.lock()
    Self.zone = zone
    zoneLock.unlock()
  }

  /// The zone decided on 10/5.
  public static let defaultTimeZone = TimeZone(identifier: "Asia/Singapore")!

  private static let zoneLock = NSLock()
  nonisolated(unsafe) private static var zone = defaultTimeZone

  public let now: Date
  public let calendar: Calendar

  public init(now: Date = Date(), timeZone: TimeZone = SearchClock.productTimeZone) {
    self.now = now
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "zh_CN")
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    self.calendar = calendar
  }

  /// The product calendar (Monday first, product time zone).
  public static var productCalendar: Calendar { SearchClock().calendar }
}

/// One time condition read from the query.
public struct SearchTimeWord: Equatable, Sendable {
  /// The words as found in the normalized query.
  public let text: String
  public let interval: DateInterval
  /// 「上周 · 9月21日–9月27日」.
  public let label: String
  /// Where it was found (in `Character` offsets of the normalized query).
  public let range: Range<Int>
}

/// Time words in a query (B4 §3.2c): 今天, 昨天, 前天, 这周/上周, 这个月/上个月,
/// 今年/去年, 最近三天, 周三/上周三, 9月, 9月25日, 2026年9月25日. Read in the
/// product time zone; weeks start on Monday.
public enum SearchTimeWords {
  public static func find(in query: String, clock: SearchClock) -> [SearchTimeWord] {
    var found: [SearchTimeWord] = []
    var taken = [Bool](repeating: false, count: query.count)
    let characters = Array(query)
    let ns = query as NSString
    for (pattern, make) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: query, range: NSRange(location: 0, length: ns.length)) {
        guard let range = Range(match.range, in: query) else { continue }
        let lower = query.distance(from: query.startIndex, to: range.lowerBound)
        let upper = query.distance(from: query.startIndex, to: range.upperBound)
        guard lower < upper, !(lower..<upper).contains(where: { taken[$0] }) else { continue }
        // A digit run never starts or ends inside a longer number (「2026」).
        if lower > 0, characters[lower - 1].isNumber, characters[lower].isNumber { continue }
        var groups: [String?] = []
        for index in 0..<match.numberOfRanges {
          let r = match.range(at: index)
          groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        guard let (interval, label) = make(groups, clock) else { continue }
        for index in lower..<upper { taken[index] = true }
        found.append(
          SearchTimeWord(
            text: String(characters[lower..<upper]), interval: interval, label: label,
            range: lower..<upper))
      }
    }
    return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
  }

  // MARK: - Patterns

  private typealias Maker = @Sendable ([String?], SearchClock) -> (DateInterval, String)?

  private static let numeral = "(?:\\d{1,2}|[一二两三四五六七八九十]{1,3})"

  private static let patterns: [(String, Maker)] = [
    // 2026年9月25日 / 9月25日 / 9月25号 / 9月
    (
      "(?:(\\d{4})年)?(\(numeral))月(?:份)?(?:(\(numeral))[日号])?",
      { groups, clock in
        guard let month = number(groups[2]), (1...12).contains(month) else { return nil }
        let cal = clock.calendar
        let nowParts = cal.dateComponents([.year, .month, .day], from: clock.now)
        var year = groups[1].flatMap { Int($0) } ?? nowParts.year!
        if let day = number(groups[3]) {
          guard (1...31).contains(day) else { return nil }
          if groups[1] == nil,
            month > nowParts.month! || (month == nowParts.month! && day > nowParts.day!)
          {
            year -= 1
          }
          guard
            let start = cal.date(from: DateComponents(year: year, month: month, day: day)),
            cal.component(.day, from: start) == day,
            let end = cal.date(byAdding: .day, value: 1, to: start)
          else { return nil }
          return (DateInterval(start: start, end: end), "\(month)月\(day)日")
        }
        if groups[1] == nil, month > nowParts.month! { year -= 1 }
        guard let start = cal.date(from: DateComponents(year: year, month: month, day: 1)),
          let end = cal.date(byAdding: .month, value: 1, to: start)
        else { return nil }
        return (DateInterval(start: start, end: end), "\(month)月")
      }
    ),
    // 最近三天 / 近 2 周 / 最近一个月
    (
      "(?:最近|近)(\(numeral)|\\d+)(?:个)?(天|日|周|星期|礼拜|月)",
      { groups, clock in
        guard let count = number(groups[1]), count > 0, count <= 366 else { return nil }
        let cal = clock.calendar
        let today = cal.startOfDay(for: clock.now)
        guard let end = cal.date(byAdding: .day, value: 1, to: today) else { return nil }
        let start: Date?
        switch groups[2] ?? "" {
        case "月": start = cal.date(byAdding: .month, value: -count, to: end)
        case "周", "星期", "礼拜": start = cal.date(byAdding: .day, value: -7 * count, to: end)
        default: start = cal.date(byAdding: .day, value: -count, to: end)
        }
        guard let start else { return nil }
        return (DateInterval(start: start, end: end), groups[0] ?? "")
      }
    ),
    // 上周三 / 这周五 / 周三 / 星期天
    (
      "(上上|上|这|本)?(?:个)?(?:周|星期|礼拜)([一二三四五六日天1-7])",
      { groups, clock in
        let cal = clock.calendar
        let names = ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6]
        guard let day = groups[2].flatMap({ names[$0] ?? Int($0).map { $0 - 1 } }),
          (0...6).contains(day),
          let thisWeek = cal.dateInterval(of: .weekOfYear, for: clock.now)?.start
        else { return nil }
        var weekStart = thisWeek
        switch groups[1] {
        case "上上": weekStart = cal.date(byAdding: .day, value: -14, to: thisWeek)!
        case "上": weekStart = cal.date(byAdding: .day, value: -7, to: thisWeek)!
        case "这", "本": break
        default:
          // A bare weekday is the last one on or before today.
          let candidate = cal.date(byAdding: .day, value: day, to: thisWeek)!
          if candidate > clock.now {
            weekStart = cal.date(byAdding: .day, value: -7, to: thisWeek)!
          }
        }
        guard let start = cal.date(byAdding: .day, value: day, to: weekStart),
          let end = cal.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return (DateInterval(start: start, end: end), "\(groups[0] ?? "") · \(dayText(start, cal))")
      }
    ),
    (
      "上上(?:个)?(?:周|星期|礼拜)",
      { groups, clock in week(offset: -2, word: groups[0], clock: clock) }
    ),
    (
      "上(?:个)?(?:周|星期|礼拜)",
      { groups, clock in week(offset: -1, word: groups[0], clock: clock) }
    ),
    (
      "(?:这|本)(?:个)?(?:周|星期|礼拜)",
      { groups, clock in week(offset: 0, word: groups[0], clock: clock) }
    ),
    (
      "上(?:个)?月",
      { groups, clock in month(offset: -1, word: groups[0], clock: clock) }
    ),
    (
      "(?:这个|本)月",
      { groups, clock in month(offset: 0, word: groups[0], clock: clock) }
    ),
    ("今年", { groups, clock in year(offset: 0, word: groups[0], clock: clock) }),
    ("去年", { groups, clock in year(offset: -1, word: groups[0], clock: clock) }),
    ("大前天", { _, clock in day(offset: -3, label: "大前天", clock: clock) }),
    ("前天", { _, clock in day(offset: -2, label: "前天", clock: clock) }),
    ("(?:昨天|昨日)", { _, clock in day(offset: -1, label: "昨天", clock: clock) }),
    ("(?:今天|今日)", { _, clock in day(offset: 0, label: "今天", clock: clock) }),
  ]

  private static func day(offset: Int, label: String, clock: SearchClock) -> (DateInterval, String)?
  {
    let cal = clock.calendar
    guard let start = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: clock.now)),
      let end = cal.date(byAdding: .day, value: 1, to: start)
    else { return nil }
    return (
      DateInterval(start: start, end: end),
      offset == 0 ? label : "\(label) · \(dayText(start, cal))"
    )
  }

  private static func week(offset: Int, word: String?, clock: SearchClock) -> (
    DateInterval, String
  )? {
    let cal = clock.calendar
    guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: clock.now)?.start,
      let start = cal.date(byAdding: .day, value: 7 * offset, to: thisWeek),
      let end = cal.date(byAdding: .day, value: 7, to: start),
      let last = cal.date(byAdding: .day, value: 6, to: start)
    else { return nil }
    return (
      DateInterval(start: start, end: end),
      "\(word ?? "") · \(dayText(start, cal))–\(dayText(last, cal))"
    )
  }

  private static func month(offset: Int, word: String?, clock: SearchClock) -> (
    DateInterval, String
  )? {
    let cal = clock.calendar
    guard let thisMonth = cal.dateInterval(of: .month, for: clock.now)?.start,
      let start = cal.date(byAdding: .month, value: offset, to: thisMonth),
      let end = cal.date(byAdding: .month, value: 1, to: start)
    else { return nil }
    return (
      DateInterval(start: start, end: end), "\(word ?? "") · \(cal.component(.month, from: start))月"
    )
  }

  private static func year(offset: Int, word: String?, clock: SearchClock) -> (
    DateInterval, String
  )? {
    let cal = clock.calendar
    guard let thisYear = cal.dateInterval(of: .year, for: clock.now)?.start,
      let start = cal.date(byAdding: .year, value: offset, to: thisYear),
      let end = cal.date(byAdding: .year, value: 1, to: start)
    else { return nil }
    return (
      DateInterval(start: start, end: end), "\(word ?? "") · \(cal.component(.year, from: start))年"
    )
  }

  static func dayText(_ date: Date, _ cal: Calendar) -> String {
    "\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日"
  }

  /// 「25」, 「二十五」, 「十」, 「两」 → Int.
  static func number(_ text: String?) -> Int? {
    guard let text, !text.isEmpty else { return nil }
    if let value = Int(text) { return value }
    let digits: [Character: Int] = [
      "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    let chars = Array(text)
    if chars == ["十"] { return 10 }
    if let ten = chars.firstIndex(of: "十") {
      let tens = ten == 0 ? 1 : (digits[chars[0]] ?? -100)
      let ones = ten + 1 < chars.count ? (digits[chars[ten + 1]] ?? -100) : 0
      let value = tens * 10 + ones
      return value > 0 && chars.count <= ten + 2 ? value : nil
    }
    guard chars.count == 1 else { return nil }
    return digits[chars[0]]
  }
}
