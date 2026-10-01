import BestASRDomain
import Foundation

/// A knot's glyph on the 线索 map: ● done, ◐ under way, ⚑ planned or due,
/// ◆ decided, ? still open.
public enum MemoryKnotGlyph: String, Equatable, Sendable {
  case done
  case doing
  case planned
  case decision
  case question

  public init(kind: String, state: String) {
    switch (kind, state) {
    case ("decision", _): self = .decision
    case ("question", _), (_, "open"): self = .question
    case (_, "planned"): self = .planned
    case (_, "doing"): self = .doing
    default: self = .done
    }
  }

  /// The glyph of an organizer fact drawn on the thread (no map yet).
  public init?(fact state: MemoryStatusFact.State) {
    switch state {
    case .done: self = .done
    case .inProgress: self = .doing
    case .planned: self = .planned
    case .cancelled, .info: return nil
    }
  }
}

/// One matter as the 线索 lens draws it (MAP-CONTRACT §3): a time axis, the
/// main thread, the strands that split off it and rejoin when closed, knots
/// with their evidence, and where "now" is. Built from the organizer's map
/// when there is one; before that, the organizer's facts on one thread
/// (`isDrafting`, shown with 「正在整理线索…」).
///
/// Pure and deterministic: the same projection, event, "now" and calendar
/// give the same model.
public struct MemoryStrandModel: Equatable, Sendable {
  /// One item a knot rests on.
  public struct Evidence: Equatable, Identifiable, Sendable {
    /// Upper-case item ID.
    public let itemID: String
    /// The event page row that shows it (`MemoryEventItem.id`).
    public let rowID: String
    public let time: Date?
    public let sourceLabel: String
    public let source: MemoryLoom.KnotKind
    /// The knot's quote when this item holds it, else the item's first words.
    public let snippet: String
    public let holdsQuote: Bool

    public var id: String { rowID }
  }

  public struct Knot: Equatable, Identifiable, Sendable {
    /// The map's knot ID, or `fact-N` for an organizer fact drawn before the
    /// map exists.
    public let id: String
    /// The strand it sits on; nil for the main thread.
    public let strand: Int?
    public let kind: String
    public let state: String
    public let glyph: MemoryKnotGlyph
    public let text: String
    /// The day it happened or is due (midnight), from the organizer, else
    /// the day of its evidence (`dateIsInferred`).
    public let date: Date?
    public let dateIsInferred: Bool
    /// Axis day index (0 is the axis's first day).
    public let day: Int
    /// People the evidence names (the Mac's user left out).
    public let who: [MemoryPersonRef]
    public let quote: String
    public let evidence: [Evidence]
  }

  public struct Strand: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let closed: Bool
    /// Items per axis day.
    public let itemDays: [Int: Int]
    public let itemCount: Int
    public let knots: [Knot]
    /// First and last axis day of its items and past knots.
    public let firstDay: Int
    public let lastDay: Int
  }

  public struct Health: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
      case ok
      case risk
      case stuck
    }

    public let level: Level
    public let reason: String
    public let evidence: [Evidence]
  }

  public let eventID: String
  public let title: String
  /// False until the organizer drew a map: the facts are drawn on one thread.
  public let hasMap: Bool
  /// A delete pruned the map and it is being drawn again.
  public let stale: Bool
  /// Midnight of the axis's first day.
  public let start: Date
  /// The library's "now" (its newest item) and its axis day.
  public let now: Date
  public let today: Int
  /// Days on the axis, including a few after today and after the last
  /// planned knot.
  public let totalDays: Int
  /// Items no strand lists, per axis day.
  public let mainItemDays: [Int: Int]
  public let mainItemCount: Int
  public let mainKnots: [Knot]
  public let strands: [Strand]
  public let health: Health?
  /// Items held on this Mac.
  public let itemCount: Int

  /// Every knot, main thread first, then strand by strand; each in day order.
  public var allKnots: [Knot] { mainKnots + strands.flatMap(\.knots) }

  public func knot(_ id: String) -> Knot? { allKnots.first { $0.id == id } }

  /// Days a map with little history still shows before its first item.
  static let leadDays = 3
  /// Days after today the axis always shows.
  static let trailDays = 4

  public init?(
    projection: MemoryProjection, eventID: String, now: Date, calendar: Calendar
  ) {
    guard let event = projection.events.first(where: { $0.eventID == eventID }) else {
      return nil
    }
    self.eventID = eventID
    title = event.title
    let todayDate = calendar.startOfDay(for: now)
    self.now = now

    // The event's items on this Mac (no keyframes), each once, with the
    // spelling of its ID the event page rows use.
    var rowSpelling: [String: String] = [:]
    var records: [String: MemoryItemRecord] = [:]
    for id in event.itemIDs {
      let key = id.uppercased()
      guard rowSpelling[key] == nil else { continue }
      rowSpelling[key] = id
      if let record = projection.records[key], !record.isKeyframe { records[key] = record }
    }
    itemCount = records.count
    let parts = Dictionary(grouping: event.segments, by: { $0.itemID.uppercased() })
      .mapValues { $0.sorted { $0.start < $1.start } }
    let map = event.map
    hasMap = map != nil
    stale = map?.stale ?? false

    // Dates first, to size the axis.
    func day(of date: Date) -> Date { calendar.startOfDay(for: date) }
    func isoDay(_ value: String?) -> Date? {
      guard let value, let components = MemoryStatusFact.day(from: value) else { return nil }
      return calendar.date(from: components).map(day(of:))
    }
    var dates = records.values.map { day(of: $0.startedAt) }
    dates.append(todayDate)
    let knotDates = (map?.knots ?? []).compactMap { isoDay($0.date) }
    let factDates = event.listedFacts.compactMap { fact in
      fact.day.flatMap { calendar.date(from: $0) }.map(day(of:))
    }
    let known = dates + knotDates + (map == nil ? factDates : [])
    let first = known.min() ?? todayDate
    let last = max(known.max() ?? todayDate, todayDate)
    let start = calendar.date(byAdding: .day, value: -Self.leadDays, to: first) ?? first
    self.start = start
    func index(_ date: Date) -> Int {
      calendar.dateComponents([.day], from: start, to: day(of: date)).day ?? 0
    }
    let todayIndex = index(todayDate)
    today = todayIndex
    totalDays = index(last) + Self.trailDays + 1

    // People the evidence names, as the event shows them.
    let eventPeople = projection.event(id: eventID)?.people ?? []
    func people(_ names: [String]) -> [MemoryPersonRef] {
      var seen = Set<String>()
      return names.compactMap { raw -> MemoryPersonRef? in
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !MemoryProjection.ownerNames.contains(name.lowercased()),
          seen.insert(name).inserted
        else { return nil }
        if let known = eventPeople.first(where: { $0.name == name }) { return known }
        return MemoryPersonRef(personID: "name:" + name, name: name)
      }
    }

    // An item a knot cites, with the row that shows it.
    func evidence(
      _ ids: [String], refs: [RemoteOrganizerSegmentRef], quote: String, quoteItem: String?
    ) -> [Evidence] {
      var seen = Set<String>()
      let quoteKey = quoteItem?.uppercased()
      var ordered = ids
      if let quoteItem,
        !ids.contains(where: { $0.caseInsensitiveCompare(quoteItem) == .orderedSame })
      {
        ordered.insert(quoteItem, at: 0)
      }
      return ordered.compactMap { id -> Evidence? in
        let key = id.uppercased()
        guard seen.insert(key).inserted, let spelled = rowSpelling[key] else { return nil }
        let record = records[key] ?? projection.records[key]
        let held = parts[key] ?? []
        let cited = refs.first { $0.itemID.uppercased() == key }?.segID
        let part = held.first { $0.segID == cited } ?? held.first
        let rowID = part.map { "\(spelled)#\($0.segID)" } ?? spelled
        let holdsQuote = key == quoteKey && !quote.isEmpty
        let snippet =
          holdsQuote
          ? quote : record.map { MemoryLoom.snippet($0, gist: part?.gist) } ?? ""
        return Evidence(
          itemID: key, rowID: rowID, time: record?.startedAt,
          sourceLabel: record?.sourceLabel ?? "", source: record.map(MemoryLoom.kind) ?? .chat,
          snippet: snippet, holdsQuote: holdsQuote)
      }.sorted {
        if $0.holdsQuote != $1.holdsQuote { return $0.holdsQuote }
        return ($0.time ?? .distantFuture, $0.rowID) < ($1.time ?? .distantFuture, $1.rowID)
      }
    }

    // Strands, and which strand each item is on.
    var strandOf: [String: Int] = [:]
    let mapStrands = map?.strands ?? []
    for (index, strand) in mapStrands.enumerated() {
      for id in strand.itemIDs where strandOf[id.uppercased()] == nil {
        strandOf[id.uppercased()] = index
      }
    }
    let strandIndex = Dictionary(
      mapStrands.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

    func knot(_ raw: RemoteOrganizerMatterMap.Knot) -> Knot {
      let found = evidence(
        raw.evidence, refs: raw.segmentRefs, quote: raw.quote, quoteItem: raw.quoteItemID)
      let explicit = isoDay(raw.date)
      let inferred =
        found.first(where: \.holdsQuote)?.time ?? found.compactMap(\.time).min()
      let date = explicit ?? inferred.map(day(of:))
      return Knot(
        id: raw.id, strand: raw.strand.flatMap { strandIndex[$0] }, kind: raw.kind,
        state: raw.state, glyph: MemoryKnotGlyph(kind: raw.kind, state: raw.state),
        text: raw.text, date: date, dateIsInferred: explicit == nil && date != nil,
        day: date.map(index) ?? todayIndex, who: people(raw.who), quote: raw.quote,
        evidence: found)
    }
    let knots = (map?.knots ?? []).map(knot).sorted {
      ($0.day, $0.id.count, $0.id) < ($1.day, $1.id.count, $1.id)
    }

    var dayCounts = Array(repeating: [Int: Int](), count: mapStrands.count + 1)
    var counts = Array(repeating: 0, count: mapStrands.count + 1)
    for (key, record) in records {
      let slot = strandOf[key].map { $0 + 1 } ?? 0
      dayCounts[slot][index(record.startedAt), default: 0] += 1
      counts[slot] += 1
    }
    mainItemDays = dayCounts[0]
    mainItemCount = counts[0]
    strands = mapStrands.enumerated().map { index, strand in
      let own = knots.filter { $0.strand == index }
      let days = Array(dayCounts[index + 1].keys) + own.map(\.day).filter { $0 <= todayIndex }
      let firstDay = days.min() ?? own.map(\.day).min() ?? todayIndex
      let lastDay = days.max() ?? firstDay
      return Strand(
        id: strand.id, name: strand.name, summary: strand.summary, closed: strand.isClosed,
        itemDays: dayCounts[index + 1], itemCount: counts[index + 1], knots: own,
        firstDay: firstDay, lastDay: max(lastDay, firstDay))
    }

    if map != nil {
      mainKnots = knots.filter { $0.strand == nil }
    } else {
      // No map yet: the organizer's facts on the one thread, each on its
      // day, else on the day of its newest item, else today.
      mainKnots = event.listedFacts.enumerated().compactMap { offset, fact -> Knot? in
        guard let glyph = MemoryKnotGlyph(fact: fact.state) else { return nil }
        let explicit = fact.day.flatMap { calendar.date(from: $0) }.map(day(of:))
        let found = evidence(fact.itemIDs, refs: [], quote: fact.quote ?? "", quoteItem: nil)
        let inferred = found.compactMap(\.time).max().map(day(of:))
        let date = explicit ?? inferred
        return Knot(
          id: "fact-\(offset + 1)", strand: nil,
          kind: fact.state == .planned ? "deadline" : "progress",
          state: glyph == .done ? "done" : (glyph == .doing ? "doing" : "planned"),
          glyph: glyph, text: fact.text, date: date,
          dateIsInferred: explicit == nil && date != nil, day: date.map(index) ?? todayIndex,
          who: [], quote: fact.quote ?? "", evidence: found)
      }.sorted { ($0.day, $0.id) < ($1.day, $1.id) }
    }

    if let raw = map?.health, let level = Health.Level(rawValue: raw.level) {
      health = Health(
        level: level, reason: raw.reason,
        evidence: evidence(raw.evidence, refs: raw.segmentRefs, quote: "", quoteItem: nil))
    } else if let raw = event.facets?.health, let level = Health.Level(rawValue: raw) {
      health = Health(level: level, reason: "", evidence: [])
    } else {
      health = nil
    }
  }

  /// The axis day of a date.
  public func day(of date: Date, calendar: Calendar) -> Int {
    calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
  }

  /// The date of an axis day.
  public func date(ofDay day: Int, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: day, to: start) ?? start
  }
}

/// What the 线索 status bar says: where it stands, how it is going, the
/// nearest flag and its countdown, promises still open, and what it waits
/// on / what waits on it.
public struct MemoryMatterStatus: Equatable, Sendable {
  public struct Flag: Equatable, Sendable {
    public let text: String
    public let date: Date
    /// Whole days from today: 0 today, 1 tomorrow, negative when past.
    public let daysAway: Int
    /// The knot it comes from, when it is one.
    public let knotID: String?
  }

  public struct Commitment: Equatable, Sendable {
    public let knotID: String
    public let text: String
    public let who: [MemoryPersonRef]
    public let date: Date?
  }

  /// Another matter this one waits on (`waitsOn`) or that waits on it.
  public struct Link: Equatable, Sendable {
    public let eventID: String
    public let title: String
    /// The statement it rests on (verbatim), when it is a blocks edge.
    public let quote: String?
    /// The relation as the organizer sent it (`a` blocks `b`).
    public let a: String
    public let b: String
  }

  public let statusLine: String
  public let health: MemoryStrandModel.Health?
  public let flag: Flag?
  public let commitments: [Commitment]
  public let questions: [MemoryStrandModel.Knot]
  public let waitsOn: [Link]
  public let waitedBy: [Link]

  /// How far back a planned day that passed still counts as the flag.
  static let overdueWindow = 14

  public init(
    model: MemoryStrandModel, statusLine: String, facts: [MemoryStatusFact],
    projection: MemoryProjection, calendar: Calendar
  ) {
    self.statusLine = statusLine
    health = model.health
    let today = calendar.startOfDay(for: model.now)
    func away(_ date: Date) -> Int {
      calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
    }
    var candidates: [Flag] = model.allKnots.compactMap { knot in
      guard knot.glyph == .planned, let date = knot.date, !knot.dateIsInferred else { return nil }
      return Flag(text: knot.text, date: date, daysAway: away(date), knotID: knot.id)
    }
    for fact in facts where fact.state == .planned || fact.state == .inProgress {
      guard let day = fact.day, let date = calendar.date(from: day) else { continue }
      let start = calendar.startOfDay(for: date)
      guard !candidates.contains(where: { $0.date == start }) else { continue }
      candidates.append(Flag(text: fact.text, date: start, daysAway: away(start), knotID: nil))
    }
    let ahead = candidates.filter { $0.daysAway >= 0 }.sorted {
      ($0.daysAway, $0.text) < ($1.daysAway, $1.text)
    }
    let passed = candidates.filter { $0.daysAway < 0 && $0.daysAway >= -Self.overdueWindow }
      .sorted { ($0.daysAway, $0.text) > ($1.daysAway, $1.text) }
    flag = ahead.first ?? passed.first
    commitments = model.allKnots.filter { $0.kind == "commitment" && $0.state != "done" }
      .map { Commitment(knotID: $0.id, text: $0.text, who: $0.who, date: $0.date) }
    questions = model.allKnots.filter { $0.glyph == .question }
    let titles = Dictionary(
      projection.events.map { ($0.eventID, $0.title) }, uniquingKeysWith: { a, _ in a })
    let blocks = projection.relations.filter(\.isBlocks)
    // `a` blocks `b`: b waits on a.
    waitsOn = blocks.filter { $0.b == model.eventID }.compactMap { relation in
      titles[relation.a].map {
        Link(eventID: relation.a, title: $0, quote: relation.quote, a: relation.a, b: relation.b)
      }
    }
    waitedBy = blocks.filter { $0.a == model.eventID }.compactMap { relation in
      titles[relation.b].map {
        Link(eventID: relation.b, title: $0, quote: relation.quote, a: relation.a, b: relation.b)
      }
    }
  }
}

/// The 网 lens: a matter's local graph, one or two hops out. Nodes are
/// matters and ropes; edges are crossings (shared items), blocks edges
/// (waiting) and ply (a matter on its rope). Placed on two rings around the
/// matter, deterministically.
public struct MemoryMatterNet: Equatable, Sendable {
  public enum NodeKind: Equatable, Sendable {
    case center
    case matter
    case rope
  }

  public struct Node: Equatable, Identifiable, Sendable {
    /// An event ID, or `rope:<id>`.
    public let id: String
    public let kind: NodeKind
    public let title: String
    /// 0 the matter itself, 1 or 2 hops out.
    public let hop: Int
    /// Unit position: the matter at (0, 0), hop one on the circle of radius
    /// `innerRadius`, hop two on `outerRadius`.
    public let x: Double
    public let y: Double
    /// Its rope is still a proposal (rope nodes only).
    public let proposed: Bool
  }

  public enum EdgeKind: Equatable, Sendable {
    /// Shared items (`count`).
    case cross(count: Int)
    /// `from` blocks `to`: `to` waits on `from`.
    case blocks(quote: String?)
    /// A matter on its rope.
    case ply
  }

  public struct Edge: Equatable, Identifiable, Sendable {
    public let from: String
    public let to: String
    public let kind: EdgeKind
    public var id: String { "\(from)>\(to)>\(Self.tag(kind))" }

    static func tag(_ kind: EdgeKind) -> String {
      switch kind {
      case .cross: "cross"
      case .blocks: "blocks"
      case .ply: "ply"
      }
    }
  }

  public let nodes: [Node]
  public let edges: [Edge]

  public static let innerRadius = 1.0
  public static let outerRadius = 1.75
  public static let maximumFirstHop = 8
  public static let maximumSecondHop = 6

  public var isEmpty: Bool { nodes.count <= 1 }

  public init(projection: MemoryProjection, eventID: String) {
    let titles = Dictionary(
      projection.events.map { ($0.eventID, $0.title) }, uniquingKeysWith: { a, _ in a })
    let home = Dictionary(
      projection.events.enumerated().map { ($1.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    let ropeOf = Self.ropeIndex(projection.ropes)

    // Neighbours of a matter: crossings by strength, blocks edges, its rope.
    func neighbours(_ id: String) -> [(String, EdgeKind, Bool)] {
      var result: [(String, EdgeKind, Bool, Int)] = []
      for relation in projection.relations where relation.a == id || relation.b == id {
        let other = relation.a == id ? relation.b : relation.a
        if relation.isBlocks {
          // Kept as `a` blocks `b`; the flag says whether `id` is `a`.
          result.append((other, .blocks(quote: relation.quote), relation.a == id, 1_000))
        } else {
          result.append((other, .cross(count: relation.count ?? 0), true, relation.count ?? 0))
        }
      }
      return result.sorted {
        ($1.3, home[$0.0] ?? .max, $0.0) < ($0.3, home[$1.0] ?? .max, $1.0)
      }.map { ($0.0, $0.1, $0.2) }
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var placed = Set<String>([eventID])
    nodes.append(
      Node(
        id: eventID, kind: .center, title: titles[eventID] ?? "", hop: 0, x: 0, y: 0,
        proposed: false))

    // Hop one: the rope first, then blocks edges and crossings.
    var first: [(id: String, kind: NodeKind, title: String, proposed: Bool)] = []
    if let rope = ropeOf[eventID] {
      first.append(("rope:" + rope.id, .rope, rope.title, rope.proposed))
      edges.append(Edge(from: eventID, to: "rope:" + rope.id, kind: .ply))
    }
    var seenEdges = Set<String>()
    for (other, kind, outgoing) in neighbours(eventID) {
      guard let title = titles[other] else { continue }
      let edge =
        outgoing
        ? Edge(from: eventID, to: other, kind: kind) : Edge(from: other, to: eventID, kind: kind)
      guard seenEdges.insert(edge.id).inserted else { continue }
      if !placed.contains(other) {
        guard first.count < Self.maximumFirstHop else { continue }
        placed.insert(other)
        first.append((other, .matter, title, false))
      }
      edges.append(edge)
    }
    for (index, node) in first.enumerated() {
      let angle = Self.angle(index, of: first.count)
      nodes.append(
        Node(
          id: node.id, kind: node.kind, title: node.title, hop: 1,
          x: cos(angle) * Self.innerRadius, y: sin(angle) * Self.innerRadius,
          proposed: node.proposed))
    }
    placed.formUnion(first.map(\.id))

    // Hop two: the rope's other matters, then each neighbour's strongest
    // link that is not shown yet.
    var second: [(id: String, parentAngle: Double, title: String)] = []
    for (index, node) in first.enumerated() where second.count < Self.maximumSecondHop {
      let angle = Self.angle(index, of: first.count)
      if node.kind == .rope,
        let rope = projection.ropes.first(where: { "rope:" + $0.id == node.id })
      {
        for child in rope.children where child != eventID {
          if !placed.contains(child), second.count < Self.maximumSecondHop,
            let title = titles[child]
          {
            placed.insert(child)
            second.append((child, angle, title))
          }
          if placed.contains(child) {
            edges.append(Edge(from: child, to: node.id, kind: .ply))
          }
        }
        continue
      }
      for (other, kind, outgoing) in neighbours(node.id).prefix(2) {
        guard let title = titles[other] else { continue }
        let edge =
          outgoing
          ? Edge(from: node.id, to: other, kind: kind) : Edge(from: other, to: node.id, kind: kind)
        // Only the way out to a new matter: two neighbours' own links would
        // cross the whole picture.
        guard !placed.contains(other), second.count < Self.maximumSecondHop else { continue }
        placed.insert(other)
        second.append((other, angle, title))
        if seenEdges.insert(edge.id).inserted { edges.append(edge) }
      }
    }
    // Spread each group of second-hop nodes around its parent's angle.
    let groups = Dictionary(grouping: second.indices, by: { second[$0].parentAngle })
    for index in second.indices {
      let entry = second[index]
      let siblings = groups[entry.parentAngle] ?? [index]
      let position = Double(siblings.firstIndex(of: index) ?? 0)
      let spread = 0.32
      let angle = entry.parentAngle + (position - Double(siblings.count - 1) / 2) * spread
      nodes.append(
        Node(
          id: entry.id, kind: .matter, title: entry.title, hop: 2,
          x: cos(angle) * Self.outerRadius, y: sin(angle) * Self.outerRadius, proposed: false))
    }
    let shown = Set(nodes.map(\.id))
    self.nodes = nodes
    self.edges = edges.filter { shown.contains($0.from) && shown.contains($0.to) }
  }

  /// Evenly around the circle, the first at the top-right.
  static func angle(_ index: Int, of count: Int) -> Double {
    -Double.pi / 2 + 0.35 + Double(index) * 2 * Double.pi / Double(max(count, 1))
  }

  /// Each matter's rope (the first that lists it).
  public static func ropeIndex(_ ropes: [RemoteOrganizerRope]) -> [String: RemoteOrganizerRope] {
    var result: [String: RemoteOrganizerRope] = [:]
    for rope in ropes {
      for child in rope.children where result[child] == nil { result[child] = rope }
    }
    return result
  }
}

/// A quote inside its item's text, with a little of what surrounds it.
public enum MemoryQuoteExcerpt {
  public struct Excerpt: Equatable, Sendable {
    public let before: String
    public let quote: String
    public let after: String
  }

  /// Nil when the quote is not in the text (whitespace runs count as one).
  public static func excerpt(of quote: String, in text: String, context: Int = 36) -> Excerpt? {
    let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return nil }
    let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let wanted = needle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard let range = flat.range(of: wanted) else { return nil }
    let before = flat[..<range.lowerBound].suffix(context)
    let after = flat[range.upperBound...].prefix(context)
    return Excerpt(
      before: (before.count == context ? "…" : "") + String(before),
      quote: String(flat[range]),
      after: String(after) + (after.count == context ? "…" : ""))
  }
}
