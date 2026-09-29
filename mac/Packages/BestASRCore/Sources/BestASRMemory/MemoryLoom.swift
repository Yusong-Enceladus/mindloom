import BestASRDomain
import Foundation

/// Home's 「最近在动的事」: the few most important matters that moved in the
/// last weeks, as ribbons along one time axis. Each matter is a lane from its
/// first to its last activity in the window, as thick each day as what it
/// took in (a knot per day); the organizer's dated done / under-way facts
/// are its milestones, and its planned facts in the 「接下来」 zone after
/// "now" are flags. An item filed in parts into several shown matters (one
/// meeting, several matters moving) is a weft crossing those lanes.
/// Home's header counts (due today / tomorrow, matters moved) come from the
/// same pass.
///
/// Pure and deterministic; derived with the rest of the read model (off the
/// main thread in the App). "Now" is the newest item in the library, so a
/// replayed library draws as it did then.
public struct MemoryLoom: Equatable, Sendable {
  public enum Span: Int, CaseIterable, Hashable, Sendable {
    case twoWeeks = 14
    case fiveWeeks = 35

    public var days: Int { rawValue }
  }

  /// The mark a source leaves on its lane.
  public enum KnotKind: String, Equatable, Sendable {
    /// A recording or a meeting App's transcript: rounded square.
    case meeting
    /// Pasted text or a chat: circle.
    case chat
    /// Sent from the phone: diamond.
    case phone
    /// Dictation: small bar.
    case dictation
    /// A screenshot or picture: square with an inner dot.
    case image
    /// A document or any other file: a small page.
    case file
  }

  /// One item of a knot, as the hover card lists it.
  public struct DayItem: Equatable, Sendable {
    /// Upper-case item ID.
    public let itemID: String
    /// The event page row that shows it (`MemoryEventItem.id`: the item, or
    /// its first part this matter holds).
    public let rowID: String
    public let time: Date
    public let sourceLabel: String
    public let snippet: String
  }

  /// One day of one lane: every item the matter took in that day.
  public struct Knot: Equatable, Identifiable, Sendable {
    /// Day index from `start` (0 is the window's first day).
    public let day: Int
    public let kind: KnotKind
    /// Items that day, oldest first (upper-case IDs).
    public let itemIDs: [String]
    /// The first item's time, source, and first words.
    public let time: Date
    public let sourceLabel: String
    public let snippet: String
    /// Every item that day, oldest first.
    public let items: [DayItem]

    public var count: Int { itemIDs.count }
    public var id: Int { day }
  }

  /// A dated done, under-way or cancelled fact on the lane's past days.
  public struct Milestone: Equatable, Sendable {
    public let day: Int
    /// A few words for the chip (no date: the position shows it).
    public let label: String
    /// The fact as the organizer wrote it.
    public let text: String
    public let state: MemoryStatusFact.State
    /// Event page rows backing it (its items, else that day's).
    public let rowIDs: [String]
  }

  /// How soon a flag is due.
  public enum Urgency: Equatable, Sendable {
    /// Today or tomorrow.
    case urgent
    /// In the next few days.
    case soon
    case later

    public init(daysAway: Int) {
      self = daysAway <= 1 ? .urgent : (daysAway <= MemoryLoom.soonDays ? .soon : .later)
    }
  }

  /// A planned (or under-way) fact dated today or later, on the axis.
  public struct Flag: Equatable, Sendable {
    public let day: Int
    public let date: Date
    public let daysAway: Int
    /// The action, short and without its date.
    public let text: String
    public var urgency: Urgency { Urgency(daysAway: daysAway) }
  }

  /// A matter's next dated step, from its status facts.
  public struct NextStep: Equatable, Sendable {
    public let text: String
    public let date: Date
    /// Whole days from "now"'s day (0 today, 1 tomorrow).
    public let daysAway: Int
    /// Day index on the axis when it falls in the 「接下来」 zone, else nil.
    public let day: Int?
  }

  public struct Lane: Equatable, Identifiable, Sendable {
    public let eventID: String
    public let title: String
    /// At most three, in the event's order.
    public let people: [MemoryPersonRef]
    /// Every person of the matter (upper-case), for highlighting.
    public let personIDs: Set<String>
    /// 「现在到哪一步」, at most `statusLength` characters.
    public let status: String
    public let statusIsFallback: Bool
    public let knots: [Knot]
    public let next: NextStep?
    /// At most `maximumMilestones`, oldest first.
    public var milestones: [Milestone] = []
    /// At most `maximumFlags`, soonest first.
    public var flags: [Flag] = []
    /// The ribbon's thickness per axis day (`totalDays` values): the square
    /// root of the day's items, smoothed; 0 outside the lane's first and last
    /// day.
    public var band: [Double] = []
    /// Items in the window.
    public var itemCount: Int { knots.reduce(0) { $0 + $1.count } }
    public var firstDay: Int { knots.first?.day ?? 0 }
    public var lastDay: Int { knots.last?.day ?? 0 }
    public var id: String { eventID }
  }

  /// One item filed in parts into several shown matters.
  public struct Weft: Equatable, Identifiable, Sendable {
    public let itemID: String
    public let day: Int
    public let time: Date
    public let kind: KnotKind
    /// Lane indices it crosses, top to bottom.
    public let lanes: [Int]
    public var id: String { itemID }
  }

  public static let maximumLanes = 5
  public static let futureDays = 7
  public static let statusLength = 18
  public static let snippetLength = 30
  public static let maximumMilestones = 3
  public static let maximumFlags = 3
  /// A flag this many days away or fewer (after tomorrow) is "soon".
  public static let soonDays = 4
  /// Widths of a milestone and a flag text, in CJK characters.
  public static let milestoneWidth = 8.0
  public static let flagWidth = 10.0

  public let span: Span
  /// Midnight of the window's first day.
  public let start: Date
  /// The newest item in the library.
  public let now: Date
  public let lanes: [Lane]
  public let wefts: [Weft]
  /// Home matters with an item in the window's past days.
  public let movedCount: Int
  /// Each Home matter's next dated step, by event ID.
  public let dues: [String: NextStep]
  /// Each Home matter's newest item, by event ID.
  public let lastActivity: [String: Date]

  /// Home matters whose next step is due today / tomorrow.
  public var dueToday: Int { dues.values.filter { $0.daysAway == 0 }.count }
  public var dueTomorrow: Int { dues.values.filter { $0.daysAway == 1 }.count }

  /// Days before and including today; today is `days - 1`.
  public var days: Int { span.days }
  public var todayIndex: Int { days - 1 }
  public var totalDays: Int { days + Self.futureDays }
  /// Shown only when at least two matters moved in the window.
  public var isShown: Bool { lanes.count >= 2 }

  public init(
    projection: MemoryProjection, home: [MemoryHomeEntry], span: Span,
    calendar: Calendar = .current
  ) {
    self.span = span
    // Only what the pages show counts: an event's items and Unfiled (a Home
    // cut off at an earlier day is given every record).
    let referenced = Set(
      projection.events.flatMap(\.itemIDs).map { $0.uppercased() }
        + projection.unfiled.map { $0.itemID.uppercased() })
    let now =
      referenced.compactMap { projection.records[$0] }.filter { !$0.isKeyframe }
      .map(\.startedAt).max() ?? projection.now
    self.now = now
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -(span.days - 1), to: today) ?? today
    self.start = start
    func dayIndex(_ date: Date) -> Int {
      calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? -1
    }

    let sources = Dictionary(
      projection.events.map { ($0.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    var lanes: [Lane] = []
    // Item → lanes holding it, for the wefts.
    var holders: [String: [Int]] = [:]
    var pending: [[Dated]] = []
    var dues: [String: NextStep] = [:]
    var lastActivity: [String: Date] = [:]
    var moved = 0
    for entry in home {
      guard let event = sources[entry.eventID] else { continue }
      if let next = Self.nextStep(
        event.statusFacts, today: today, calendar: calendar, days: span.days)
      {
        dues[event.eventID] = next
      }
      var seen = Set<String>()
      var dated: [Dated] = []
      var newest: Date?
      for id in event.itemIDs {
        let key = id.uppercased()
        guard seen.insert(key).inserted, let record = projection.records[key],
          !record.isKeyframe
        else { continue }
        newest = max(newest ?? record.startedAt, record.startedAt)
        let day = dayIndex(record.startedAt)
        guard (0..<span.days).contains(day) else { continue }
        let part = event.segments.first { $0.itemID.uppercased() == key }
        dated.append(
          Dated(
            record: record, day: day, gist: part?.gist,
            rowID: part.map { "\(id)#\($0.segID)" } ?? id))
      }
      if let newest { lastActivity[event.eventID] = newest }
      guard !dated.isEmpty else { continue }
      moved += 1
      guard lanes.count < Self.maximumLanes else { continue }
      dated.sort {
        ($0.record.startedAt, Self.key($0.record)) < ($1.record.startedAt, Self.key($1.record))
      }
      let index = lanes.count
      for item in dated {
        holders[Self.key(item.record), default: []].append(index)
      }
      var lane = Lane(
        eventID: event.eventID, title: entry.title,
        people: Array(entry.shownPeople.prefix(3)),
        personIDs: Set(entry.people.map { $0.personID.uppercased() }),
        status: Self.short(entry.statusLine, Self.statusLength),
        statusIsFallback: entry.statusIsFallback,
        knots: [],  // filled below, once the wefts are known
        next: dues[event.eventID])
      lane.flags = Self.flags(
        event.statusFacts, today: today, calendar: calendar, todayIndex: span.days - 1)
      lane.milestones = Self.milestones(
        event.statusFacts, event: event, dated: dated, calendar: calendar,
        dayIndex: dayIndex, todayIndex: span.days - 1)
      lanes.append(lane)
      pending.append(dated)
    }
    movedCount = moved
    self.dues = dues
    self.lastActivity = lastActivity

    var wefts: [Weft] = []
    var weftItems = Set<String>()
    for dated in pending {
      for item in dated {
        let key = Self.key(item.record)
        guard let crossing = holders[key], Set(crossing).count >= 2,
          weftItems.insert(key).inserted
        else { continue }
        wefts.append(
          Weft(
            itemID: key, day: item.day, time: item.record.startedAt,
            kind: Self.kind(item.record), lanes: Array(Set(crossing)).sorted()))
      }
    }
    wefts.sort {
      ($0.day, $0.lanes.first ?? 0, $0.itemID) < ($1.day, $1.lanes.first ?? 0, $1.itemID)
    }

    let totalDays = span.days + Self.futureDays
    self.lanes = zip(lanes, pending).map { lane, dated in
      var result = Lane(
        eventID: lane.eventID, title: lane.title, people: lane.people,
        personIDs: lane.personIDs, status: lane.status,
        statusIsFallback: lane.statusIsFallback,
        knots: Self.knots(dated, weftItems: weftItems), next: lane.next)
      result.milestones = lane.milestones
      result.flags = lane.flags
      result.band = Self.band(result.knots, totalDays: totalDays)
      return result
    }
    self.wefts = wefts
  }

  /// An item of a lane on its day.
  struct Dated {
    let record: MemoryItemRecord
    let day: Int
    let gist: String?
    let rowID: String
  }

  /// One knot per day; a day with an item that crosses lanes takes that
  /// item's shape, else the most frequent (the latest on a tie).
  static func knots(_ dated: [Dated], weftItems: Set<String>) -> [Knot] {
    var result: [Knot] = []
    var index = 0
    while index < dated.count {
      let day = dated[index].day
      var end = index
      while end < dated.count, dated[end].day == day { end += 1 }
      let group = Array(dated[index..<end])
      index = end
      let kinds = group.map { kind($0.record) }
      let shape: KnotKind
      if let crossing = group.firstIndex(where: { weftItems.contains(key($0.record)) }) {
        shape = kinds[crossing]
      } else {
        var counts: [KnotKind: Int] = [:]
        for kind in kinds { counts[kind, default: 0] += 1 }
        let best = counts.values.max() ?? 0
        shape = kinds.last { counts[$0] == best } ?? kinds[0]
      }
      let first = group[0]
      result.append(
        Knot(
          day: day, kind: shape, itemIDs: group.map { key($0.record) },
          time: first.record.startedAt, sourceLabel: first.record.sourceLabel,
          snippet: snippet(first.record, gist: first.gist),
          items: group.map {
            DayItem(
              itemID: key($0.record), rowID: $0.rowID, time: $0.record.startedAt,
              sourceLabel: $0.record.sourceLabel, snippet: snippet($0.record, gist: $0.gist))
          }))
    }
    return result
  }

  /// The earliest planned or under-way fact dated today or later.
  static func nextStep(
    _ facts: [MemoryStatusFact], today: Date, calendar: Calendar, days: Int
  ) -> NextStep? {
    let candidates = facts.filter { $0.state == .planned || $0.state == .inProgress }
      .compactMap { fact -> (MemoryStatusFact, Date)? in
        guard let day = fact.day, let date = calendar.date(from: day) else { return nil }
        let start = calendar.startOfDay(for: date)
        return start >= today ? (fact, start) : nil
      }
      .sorted { $0.1 < $1.1 }
    guard let (fact, date) = candidates.first else { return nil }
    let away = calendar.dateComponents([.day], from: today, to: date).day ?? 0
    let onAxis = away >= 1 && away <= futureDays ? days - 1 + away : (away == 0 ? days - 1 : nil)
    return NextStep(
      text: short(fact.text, statusLength), date: date, daysAway: away, day: onAxis)
  }

  /// Planned or under-way facts dated today up to the zone's last day, the
  /// soonest first (one per day and text), at most `maximumFlags`.
  static func flags(
    _ facts: [MemoryStatusFact], today: Date, calendar: Calendar, todayIndex: Int
  ) -> [Flag] {
    var seen = Set<String>()
    return facts.filter { $0.state == .planned || $0.state == .inProgress }
      .compactMap { fact -> Flag? in
        guard let day = fact.day, let date = calendar.date(from: day) else { return nil }
        let start = calendar.startOfDay(for: date)
        let away = calendar.dateComponents([.day], from: today, to: start).day ?? -1
        guard (0...futureDays).contains(away) else { return nil }
        let text = label(fact.text, width: flagWidth)
        guard !text.isEmpty, seen.insert("\(away)|\(text)").inserted else { return nil }
        return Flag(day: todayIndex + away, date: start, daysAway: away, text: text)
      }
      .sorted { $0.day < $1.day }
      .prefix(maximumFlags).map { $0 }
  }

  /// Done and cancelled facts dated in the window up to today, and under-way
  /// ones before today (today's is a flag), the latest `maximumMilestones`.
  static func milestones(
    _ facts: [MemoryStatusFact], event: MemoryEventSource, dated: [Dated], calendar: Calendar,
    dayIndex: (Date) -> Int, todayIndex: Int
  ) -> [Milestone] {
    var seen = Set<String>()
    var result: [(offset: Int, milestone: Milestone)] = []
    for (offset, fact) in facts.enumerated() {
      guard fact.state == .done || fact.state == .cancelled || fact.state == .inProgress,
        let components = fact.day, let date = calendar.date(from: components)
      else { continue }
      let day = dayIndex(date)
      let last = fact.state == .inProgress ? todayIndex - 1 : todayIndex
      guard (0...last).contains(day) else { continue }
      let text = label(fact.text, width: milestoneWidth)
      guard !text.isEmpty, seen.insert("\(day)|\(text)").inserted else { continue }
      // Its own items' rows, else the rows of that day.
      let own = Set(fact.itemIDs.map { $0.uppercased() })
      var rows = dated.filter { own.contains(key($0.record)) }.map(\.rowID)
      if rows.isEmpty {
        rows = event.itemIDs.filter { own.contains($0.uppercased()) }
      }
      if rows.isEmpty { rows = dated.filter { $0.day == day }.map(\.rowID) }
      result.append(
        (
          offset,
          Milestone(day: day, label: text, text: fact.text, state: fact.state, rowIDs: rows)
        ))
    }
    return result.sorted { ($0.milestone.day, $0.offset) < ($1.milestone.day, $1.offset) }
      .suffix(maximumMilestones).map(\.milestone)
  }

  /// The ribbon: √(items) per day, smoothed over the neighbours (½ weight),
  /// kept between the lane's first and last day.
  static func band(_ knots: [Knot], totalDays: Int) -> [Double] {
    guard let first = knots.first?.day, let last = knots.last?.day, totalDays > 0 else {
      return Array(repeating: 0, count: max(totalDays, 0))
    }
    var roots = Array(repeating: 0.0, count: totalDays)
    for knot in knots where (0..<totalDays).contains(knot.day) {
      roots[knot.day] = Double(knot.count).squareRoot()
    }
    return (0..<totalDays).map { day in
      guard day >= first, day <= last else { return 0 }
      var sum = 0.0
      var weight = 0.0
      for offset in -1...1 {
        let other = day + offset
        guard other >= first, other <= last else { continue }
        let w = offset == 0 ? 1.0 : 0.5
        sum += roots[other] * w
        weight += w
      }
      return weight > 0 ? sum / weight : 0
    }
  }

  /// A fact's few words: its first clause without dates (the axis shows
  /// the day), cut to `width` CJK characters (Latin counts about half).
  public static func label(_ text: String, width: Double) -> String {
    var line = text
    for pattern in datePatterns {
      line = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    // An ASCII colon stays: it is usually a time ("9:30 B超").
    let clauses = line.split(whereSeparator: { "，,。；;：！!？?（）()\n".contains($0) })
      .map {
        $0.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
      }
      .filter { !$0.isEmpty }
    guard let clause = clauses.first else { return "" }
    // Spaces left where a date was cut out collapse to one.
    let words = clause.split(separator: " ", omittingEmptySubsequences: true).joined(
      separator: " ")
    return fit(words, width: width)
  }

  /// The text itself when it fits `width`, else its start and "…".
  static func fit(_ text: String, width: Double) -> String {
    func units(_ c: Character) -> Double {
      c.unicodeScalars.first.map { $0.value < 0x2E80 ? 0.55 : 1 } ?? 1
    }
    guard text.reduce(0, { $0 + units($1) }) > width else { return text }
    var result = ""
    var used = 0.0
    for c in text {
      guard used + units(c) <= width - 0.6 else { break }
      result.append(c)
      used += units(c)
    }
    return result.trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Dates and day words, with the "前 / 起" that follows and the "于"
  /// before.
  static let datePatterns = [
    #"(于|在|截至|到)?\d{4}[-/年.]\d{1,2}[-/月.]\d{1,2}[日号]?(之前|以前|前|起|后)?"#,
    #"(于|在|截至|到)?\d{1,2}月\d{1,2}[日号]?(之前|以前|前|起|后)?"#,
    #"(于|在|截至|到)?(?<![\d.])\d{1,2}/\d{1,2}(?![\d/])(之前|以前|前|起|后)?"#,
    #"(于|在|截至|到)?(?<![\d.月/])\d{1,2}[日号](?!\d)(之前|以前|前|起|后)?"#,
    #"(本|下|这)?(周|星期)[一二三四五六日天](之前|以前|前|起|后)?"#,
    #"(今天|明天|后天|昨天|今晚|明早|今早)"#,
  ]

  static func kind(_ record: MemoryItemRecord) -> KnotKind {
    switch record.inputMode {
    case .dictation: return .dictation
    case .roomMicrophone, .systemAudio, .importedMedia: return .meeting
    case .userItem:
      if record.sourceBundleID == nil, isPhone(record.sourceDisplayName) { return .phone }
      switch record.itemKind {
      case .image?: return .image
      case .file?: return .file
      case .document?, .text?:
        if MemoryTranscriptText.parse(record.text ?? "") != nil { return .meeting }
        return record.itemKind == .document ? .file : .chat
      case nil: return .chat
      }
    }
  }

  static func isPhone(_ name: String?) -> Bool {
    guard let name = name?.lowercased() else { return false }
    return name.contains("iphone") || name.contains("ipad") || name.contains("手机")
  }

  /// The part's description when the matter holds a part, else the item's
  /// first words (its reading for a screenshot, its name for a file).
  static func snippet(_ record: MemoryItemRecord, gist: String?) -> String {
    if let gist, !gist.trimmingCharacters(in: .whitespaces).isEmpty {
      return short(gist, snippetLength)
    }
    let candidates = [record.text, record.localReading, record.title]
    for text in candidates {
      guard let text else { continue }
      if text == UserItemLimits.noTextLayerPlaceholder { continue }
      let words = text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .joined(separator: " ")
      if !words.isEmpty { return short(words, snippetLength) }
    }
    return ""
  }

  static func short(_ text: String, _ length: Int) -> String {
    let line =
      text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard line.count > length else { return line }
    return String(line.prefix(length - 1)) + "…"
  }

  static func key(_ record: MemoryItemRecord) -> String {
    record.sessionID.rawValue.uuidString.uppercased()
  }
}
