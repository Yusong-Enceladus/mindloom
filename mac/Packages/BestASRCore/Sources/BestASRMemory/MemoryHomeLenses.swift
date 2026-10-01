import BestASRDomain
import Foundation

/// A matter's recent activity as a small strip (the rows of Home's 按绳 and
/// 按人): items per day and planned days, over `MemoryHomeLenses`' window.
public struct MemoryActivityStrip: Equatable, Sendable {
  /// Window day index → items that day.
  public let days: [Int: Int]
  /// Window day indices of planned or due steps.
  public let flags: [Int]

  public var firstDay: Int? { days.keys.min() }
  public var lastDay: Int? { days.keys.max() }
}

/// What Home's lenses other than 按时间 show (MAP-CONTRACT §3), derived once
/// with the read model: 按绳 (rope bands, children indented), 按截止 (a
/// ladder from what just passed to later), 按人 (the people who matter and
/// their matters), and each matter's activity strip.
///
/// Pure and deterministic. "Now" is Home's (the library's newest item).
public struct MemoryHomeLenses: Equatable, Sendable {
  /// One rope and what is on it; ropes inside it are its `children` bands.
  public struct RopeBand: Equatable, Identifiable, Sendable {
    public let rope: RemoteOrganizerRope
    /// 0 for a rope at the top, 1 inside one, and so on.
    public let depth: Int
    /// Its matters in Home order.
    public let entries: [MemoryHomeEntry]
    public let children: [RopeBand]

    public var id: String { rope.id }
    /// Matters on it and on the ropes inside it.
    public var total: Int { entries.count + children.reduce(0) { $0 + $1.total } }
  }

  /// A dated step of a matter on the ladder.
  public struct Deadline: Equatable, Identifiable, Sendable {
    public let eventID: String
    public let title: String
    public let text: String
    public let date: Date
    /// Whole days from today (negative when it passed).
    public let daysAway: Int
    /// From the matter's map (a knot) rather than its facts.
    public let fromMap: Bool

    public var id: String { "\(eventID)|\(daysAway)|\(text)" }
  }

  public struct Rung: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Equatable, Sendable {
      /// The last week, still not marked done.
      case justPassed
      case today
      case tomorrow
      /// The rest of the next seven days.
      case thisWeek
      case later
    }

    public let kind: Kind
    /// The first and last day it covers (nil: open-ended).
    public let from: Date?
    public let to: Date?
    public let deadlines: [Deadline]

    public var id: String { kind.rawValue }
  }

  public struct PersonLane: Equatable, Identifiable, Sendable {
    public let person: MemoryPersonEntry
    /// Their matters in Home order, at most `PersonLane.shown`.
    public let entries: [MemoryHomeEntry]
    public let total: Int

    public var id: String { person.personID }
    public static let shown = 5
  }

  public let bands: [RopeBand]
  /// Home matters on no rope, in Home order.
  public let unroped: [MemoryHomeEntry]
  public let rungs: [Rung]
  public let people: [PersonLane]
  /// By event ID.
  public let activity: [String: MemoryActivityStrip]
  /// The strips' window: its first day (midnight), length, and today's index.
  public let windowStart: Date
  public let windowDays: Int
  public let todayIndex: Int
  public let now: Date

  public static let pastDays = 42
  public static let futureDays = 14
  public static let maximumPeople = 8
  /// Days back a planned step that passed stays on the ladder.
  public static let passedDays = 7
  /// Map knots that are steps due (a planned decision or an open question
  /// is not).
  static let dueKinds: Set<String> = ["deadline", "commitment", "progress"]

  public var hasRopes: Bool { !bands.isEmpty }

  public init(
    projection: MemoryProjection, home: [MemoryHomeEntry], featuredPeople: [MemoryPersonEntry],
    now: Date, calendar: Calendar
  ) {
    self.now = now
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -Self.pastDays, to: today) ?? today
    windowStart = start
    let windowLength = Self.pastDays + Self.futureDays + 1
    windowDays = windowLength
    todayIndex = Self.pastDays
    let entries = Dictionary(home.map { ($0.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    let order = Dictionary(
      home.enumerated().map { ($1.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    func away(_ date: Date) -> Int {
      calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
    }
    func windowDay(_ date: Date) -> Int { away(date) + Self.pastDays }

    // 按绳: each rope's matters, nested ropes under their parent.
    let ropes = projection.ropes
    var onRope = Set<String>()
    func band(_ rope: RemoteOrganizerRope, depth: Int, visited: Set<String>) -> RopeBand {
      let own = rope.children.compactMap { entries[$0] }.sorted {
        (order[$0.eventID] ?? .max) < (order[$1.eventID] ?? .max)
      }
      onRope.formUnion(own.map(\.eventID))
      let inner = ropes.filter { $0.parent == rope.id && !visited.contains($0.id) }
        .map { band($0, depth: depth + 1, visited: visited.union([$0.id])) }
      return RopeBand(rope: rope, depth: depth, entries: own, children: inner)
    }
    let top = ropes.filter { $0.parent == nil }
      .map { band($0, depth: 0, visited: [$0.id]) }
      .filter { $0.total > 0 }
    // Confirmed ropes first, then by their first matter's place on Home.
    func rank(_ band: RopeBand) -> Int {
      let own = band.entries.compactMap { order[$0.eventID] }.min() ?? .max
      let inner = band.children.map(rank).min() ?? .max
      return min(own, inner)
    }
    bands = top.sorted {
      if $0.rope.proposed != $1.rope.proposed { return !$0.rope.proposed }
      return (rank($0), $0.rope.id) < (rank($1), $1.rope.id)
    }
    unroped = home.filter { !onRope.contains($0.eventID) }

    // Activity strips and the ladder.
    var activity: [String: MemoryActivityStrip] = [:]
    var deadlines: [Deadline] = []
    for event in projection.events {
      guard let entry = entries[event.eventID] else { continue }
      var days: [Int: Int] = [:]
      var seen = Set<String>()
      for id in event.itemIDs where seen.insert(id.uppercased()).inserted {
        guard let record = projection.records[id.uppercased()], !record.isKeyframe else {
          continue
        }
        let day = windowDay(record.startedAt)
        if (0..<windowLength).contains(day) { days[day, default: 0] += 1 }
      }
      var steps: [(String, Date, Bool)] = []
      for fact in event.listedFacts where fact.state == .planned || fact.state == .inProgress {
        guard let day = fact.day, let date = calendar.date(from: day) else { continue }
        let start = calendar.startOfDay(for: date)
        // Something under way on a past day happened; it is not a step due.
        if fact.state == .inProgress, start < today { continue }
        steps.append((fact.text, start, false))
      }
      for knot in event.map?.knots ?? []
      where knot.state == "planned" && Self.dueKinds.contains(knot.kind) {
        guard let value = knot.date, let day = MemoryStatusFact.day(from: value),
          let date = calendar.date(from: day)
        else { continue }
        let start = calendar.startOfDay(for: date)
        // One step a day per matter: the facts win over the map.
        guard !steps.contains(where: { $0.1 == start }) else { continue }
        steps.append((knot.text, start, true))
      }
      let flags = steps.map { windowDay($0.1) }.filter { (0..<windowLength).contains($0) }
      activity[event.eventID] = MemoryActivityStrip(days: days, flags: Array(Set(flags)).sorted())
      for (text, date, fromMap) in steps {
        let days = away(date)
        guard days >= -Self.passedDays else { continue }
        deadlines.append(
          Deadline(
            eventID: event.eventID, title: entry.title, text: text, date: date, daysAway: days,
            fromMap: fromMap))
      }
    }
    self.activity = activity
    deadlines.sort {
      ($0.daysAway, order[$0.eventID] ?? .max, $0.text)
        < ($1.daysAway, order[$1.eventID] ?? .max, $1.text)
    }
    func day(_ offset: Int) -> Date {
      calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }
    rungs = Rung.Kind.allCases.map { kind in
      let (range, from, to): (ClosedRange<Int>, Date?, Date?) =
        switch kind {
        case .justPassed: (-Self.passedDays...(-1), day(-Self.passedDays), day(-1))
        case .today: (0...0, today, today)
        case .tomorrow: (1...1, day(1), day(1))
        case .thisWeek: (2...7, day(2), day(7))
        case .later: (8...(Int.max - 1), day(8), nil)
        }
      return Rung(
        kind: kind, from: from, to: to,
        deadlines: deadlines.filter { range.contains($0.daysAway) })
    }

    // 按人: the people who matter, in the most matters first.
    // Each person's matters: those they take part in first (heard, or
    // writing in them), then the ones that only name them, in Home order.
    people = featuredPeople.filter(\.isNamed).prefix(Self.maximumPeople).map { person in
      let ordered = person.events.enumerated().sorted {
        let a = $0.element.participantIDs.contains(person.personID)
        let b = $1.element.participantIDs.contains(person.personID)
        return a != b ? a : $0.offset < $1.offset
      }.map(\.element)
      return PersonLane(
        person: person, entries: Array(ordered.prefix(PersonLane.shown)),
        total: person.events.count)
    }
  }
}
