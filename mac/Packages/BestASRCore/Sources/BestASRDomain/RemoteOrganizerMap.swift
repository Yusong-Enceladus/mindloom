import Foundation

// v7 (MAP-CONTRACT §1–§2): each matter's map of strands and knots, its facets,
// the ropes that group matters, and the relations between matters. Every field
// is additive on the wire: an older service omits them, and a malformed field
// or entry is dropped rather than failing the pull.

/// One part of an item a map cites (a meeting's segment filed into this
/// matter): the item ID as the Mac spells it and the part's `seg_id`.
public struct RemoteOrganizerSegmentRef: Codable, Equatable, Hashable, Sendable {
  public let itemID: String
  public let segID: String

  public init(itemID: String, segID: String) {
    self.itemID = itemID
    self.segID = segID
  }

  enum CodingKeys: String, CodingKey {
    case itemID = "item_id"
    case segID = "seg_id"
  }
}

/// A matter's map (`events[].map`): the strands it splits into, the knots on
/// them (what moved, was decided, is asked, promised or due), and how it is
/// going. Knots whose strand is nil sit on the main thread, which is implicit:
/// every item no strand lists is on it.
public struct RemoteOrganizerMatterMap: Codable, Equatable, Sendable {
  public struct Strand: Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var summary: String
    public let itemIDs: [String]
    public let segmentRefs: [RemoteOrganizerSegmentRef]
    /// "fN" is the N-th entry of the same event's `status_facts`, valid only
    /// while the map's `factsCurrent` is true.
    public let factIDs: [String]
    /// `open` or `closed`.
    public let state: String

    public var isClosed: Bool { state == "closed" }

    public init(
      id: String, name: String, summary: String = "", itemIDs: [String] = [],
      segmentRefs: [RemoteOrganizerSegmentRef] = [], factIDs: [String] = [],
      state: String = "open"
    ) {
      self.id = id
      self.name = name
      self.summary = summary
      self.itemIDs = itemIDs
      self.segmentRefs = segmentRefs
      self.factIDs = factIDs
      self.state = state
    }

    enum CodingKeys: String, CodingKey {
      case id, name, summary, state
      case itemIDs = "item_ids"
      case segmentRefs = "segment_refs"
      case factIDs = "fact_ids"
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try RemoteOrganizerMatterMap.identifier(c.decode(String.self, forKey: .id))
      name = RemoteOrganizerMatterMap.line(
        try c.decode(String.self, forKey: .name), limit: RemoteOrganizerMatterMap.nameLimit)
      guard !name.isEmpty else { throw RemoteOrganizerMatterMap.Malformed() }
      summary = RemoteOrganizerMatterMap.line(
        (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? "",
        limit: RemoteOrganizerMatterMap.summaryLimit)
      itemIDs = RemoteOrganizerMatterMap.ids(c, .itemIDs)
      segmentRefs = RemoteOrganizerMatterMap.refs(c, .segmentRefs)
      factIDs = RemoteOrganizerMatterMap.ids(c, .factIDs)
      let raw = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil
      state = raw == "closed" ? "closed" : "open"
    }
  }

  public struct Knot: Codable, Equatable, Sendable {
    public let id: String
    /// The strand it sits on; nil for the main thread.
    public let strand: String?
    /// `progress`, `decision`, `question`, `commitment` or `deadline`.
    public let kind: String
    public var text: String
    /// `YYYY-MM-DD`, or nil when the evidence names no day.
    public let date: String?
    /// `done`, `doing`, `planned` or `open` (a question).
    public let state: String
    /// People named in the evidence (`我` is the Mac's user).
    public var who: [String]
    /// Client item IDs; a segment of a split item appears as its parent.
    public let evidence: [String]
    public let segmentRefs: [RemoteOrganizerSegmentRef]
    /// Verbatim (masked on the wire) from `quoteItemID`'s text.
    public var quote: String
    public let quoteItemID: String?
    public let quoteSegID: String?

    public init(
      id: String, strand: String? = nil, kind: String, text: String, date: String? = nil,
      state: String, who: [String] = [], evidence: [String] = [],
      segmentRefs: [RemoteOrganizerSegmentRef] = [], quote: String = "",
      quoteItemID: String? = nil, quoteSegID: String? = nil
    ) {
      self.id = id
      self.strand = strand
      self.kind = kind
      self.text = text
      self.date = date
      self.state = state
      self.who = who
      self.evidence = evidence
      self.segmentRefs = segmentRefs
      self.quote = quote
      self.quoteItemID = quoteItemID
      self.quoteSegID = quoteSegID
    }

    enum CodingKeys: String, CodingKey {
      case id, strand, kind, text, date, state, who, evidence, quote
      case segmentRefs = "segment_refs"
      case quoteItemID = "quote_item_id"
      case quoteSegID = "quote_seg_id"
    }

    public static let kinds: Set<String> = [
      "progress", "decision", "question", "commitment", "deadline",
    ]
    public static let states: Set<String> = ["done", "doing", "planned", "open"]

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try RemoteOrganizerMatterMap.identifier(c.decode(String.self, forKey: .id))
      let strandID = ((try? c.decodeIfPresent(String.self, forKey: .strand)) ?? nil)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      strand = strandID?.isEmpty == false ? strandID : nil
      let rawKind = try c.decode(String.self, forKey: .kind)
      kind = Self.kinds.contains(rawKind) ? rawKind : "progress"
      text = RemoteOrganizerMatterMap.line(
        try c.decode(String.self, forKey: .text), limit: RemoteOrganizerMatterMap.textLimit)
      guard !text.isEmpty else { throw RemoteOrganizerMatterMap.Malformed() }
      date = RemoteOrganizerMatterMap.isoDay(
        (try? c.decodeIfPresent(String.self, forKey: .date)) ?? nil)
      let rawState = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil
      // A question is open whatever the wire says; anything unknown is under way.
      if kind == "question" {
        state = "open"
      } else if let rawState, Self.states.contains(rawState), rawState != "open" {
        state = rawState
      } else {
        state = "doing"
      }
      who =
        ((try? c.decodeIfPresent([String].self, forKey: .who)) ?? nil)?
        .map { RemoteOrganizerMatterMap.line($0, limit: 32) }.filter { !$0.isEmpty } ?? []
      evidence = RemoteOrganizerMatterMap.ids(c, .evidence)
      segmentRefs = RemoteOrganizerMatterMap.refs(c, .segmentRefs)
      let rawQuote = ((try? c.decodeIfPresent(String.self, forKey: .quote)) ?? nil) ?? ""
      quote = String(rawQuote.prefix(RemoteOrganizerMatterMap.quoteLimit))
      quoteItemID = ((try? c.decodeIfPresent(String.self, forKey: .quoteItemID)) ?? nil)
        .flatMap { $0.isEmpty ? nil : $0 }
      quoteSegID = ((try? c.decodeIfPresent(String.self, forKey: .quoteSegID)) ?? nil)
        .flatMap { $0.isEmpty ? nil : $0 }
    }
  }

  public struct Health: Codable, Equatable, Sendable {
    /// `ok`, `risk` or `stuck`.
    public let level: String
    public var reason: String
    public let evidence: [String]
    public let segmentRefs: [RemoteOrganizerSegmentRef]

    public init(
      level: String, reason: String, evidence: [String] = [],
      segmentRefs: [RemoteOrganizerSegmentRef] = []
    ) {
      self.level = level
      self.reason = reason
      self.evidence = evidence
      self.segmentRefs = segmentRefs
    }

    enum CodingKeys: String, CodingKey {
      case level, reason, evidence
      case segmentRefs = "segment_refs"
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let raw = try c.decode(String.self, forKey: .level)
      guard ["ok", "risk", "stuck"].contains(raw) else {
        throw RemoteOrganizerMatterMap.Malformed()
      }
      level = raw
      reason = RemoteOrganizerMatterMap.line(
        (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? "",
        limit: RemoteOrganizerMatterMap.summaryLimit)
      evidence = RemoteOrganizerMatterMap.ids(c, .evidence)
      segmentRefs = RemoteOrganizerMatterMap.refs(c, .segmentRefs)
    }
  }

  public var strands: [Strand]
  public var knots: [Knot]
  public var health: Health?
  public let skillVersion: String?
  public let updatedAt: String?
  /// A delete pruned the map and it is queued to be drawn again.
  public let stale: Bool
  /// Whether `Strand.factIDs` still point at this event's facts.
  public let factsCurrent: Bool

  public init(
    strands: [Strand], knots: [Knot], health: Health? = nil, skillVersion: String? = nil,
    updatedAt: String? = nil, stale: Bool = false, factsCurrent: Bool = true
  ) {
    self.strands = strands
    self.knots = knots
    self.health = health
    self.skillVersion = skillVersion
    self.updatedAt = updatedAt
    self.stale = stale
    self.factsCurrent = factsCurrent
  }

  enum CodingKeys: String, CodingKey {
    case strands, knots, health, stale
    case skillVersion = "skill_version"
    case updatedAt = "updated_at"
    case factsCurrent = "facts_current"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    var strandIDs = Set<String>()
    let decodedStrands =
      ((try? c.decodeIfPresent([Lenient<Strand>].self, forKey: .strands)) ?? nil)?
      .compactMap(\.value) ?? []
    strands = decodedStrands.filter { strandIDs.insert($0.id).inserted }
      .prefix(Self.maximumStrands).map { $0 }
    let kept = Set(strands.map(\.id))
    var knotIDs = Set<String>()
    let decodedKnots =
      ((try? c.decodeIfPresent([Lenient<Knot>].self, forKey: .knots)) ?? nil)?
      .compactMap(\.value) ?? []
    knots = decodedKnots.filter { knotIDs.insert($0.id).inserted }.prefix(Self.maximumKnots)
      .map { knot in
        // A knot on a strand that did not come through sits on the main thread.
        guard let strand = knot.strand, !kept.contains(strand) else { return knot }
        return Knot(
          id: knot.id, strand: nil, kind: knot.kind, text: knot.text, date: knot.date,
          state: knot.state, who: knot.who, evidence: knot.evidence,
          segmentRefs: knot.segmentRefs, quote: knot.quote, quoteItemID: knot.quoteItemID,
          quoteSegID: knot.quoteSegID)
      }
    health = (try? c.decodeIfPresent(Health.self, forKey: .health)) ?? nil
    skillVersion = (try? c.decodeIfPresent(String.self, forKey: .skillVersion)) ?? nil
    updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil
    stale = ((try? c.decodeIfPresent(Bool.self, forKey: .stale)) ?? nil) ?? false
    factsCurrent = ((try? c.decodeIfPresent(Bool.self, forKey: .factsCurrent)) ?? nil) ?? true
  }

  /// A map with nothing to draw is no map.
  public var isEmpty: Bool { strands.isEmpty && knots.isEmpty }

  public static let maximumStrands = 8
  public static let maximumKnots = 40
  static let nameLimit = 24
  static let summaryLimit = 120
  static let textLimit = 80
  static let quoteLimit = 240

  struct Malformed: Error {}

  static func identifier(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 64 else { throw Malformed() }
    return value
  }

  /// One line, cut to `limit` characters.
  static func line(_ value: String, limit: Int) -> String {
    String(
      value.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .joined(separator: " ").prefix(limit))
  }

  static func ids<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String] {
    var seen = Set<String>()
    return (((try? c.decodeIfPresent([Lenient<String>].self, forKey: key)) ?? nil) ?? [])
      .compactMap(\.value).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0.count <= 128 && seen.insert($0.uppercased()).inserted }
  }

  static func refs<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K)
    -> [RemoteOrganizerSegmentRef]
  {
    (((try? c.decodeIfPresent([Lenient<RemoteOrganizerSegmentRef>].self, forKey: key)) ?? nil)
      ?? []).compactMap(\.value).filter { !$0.itemID.isEmpty && !$0.segID.isEmpty }
  }

  /// `YYYY-MM-DD` with a real month and day, else nil.
  static func isoDay(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), value.count == 10 else {
      return nil
    }
    let parts = value.split(separator: "-")
    guard parts.count == 3, parts[0].count == 4, let year = Int(parts[0]),
      let month = Int(parts[1]), let day = Int(parts[2]), year > 1900,
      (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    return value
  }
}

/// A matter's facets (`events[].facets`): what it is, which rope holds it,
/// its nearest planned day, and how it is going.
public struct RemoteOrganizerFacets: Codable, Equatable, Sendable {
  /// 论文 / 横向 / 求职 / 生活 …, proposed by the grouping pass.
  public let type: String?
  public var rope: String?
  /// `YYYY-MM-DD`: the nearest planned fact on or after the organizer's
  /// today, else the latest past one (`deadlineOverdue`).
  public let deadline: String?
  public let deadlineOverdue: Bool
  /// `ok`, `risk`, `stuck`, or nil.
  public let health: String?

  public init(
    type: String? = nil, rope: String? = nil, deadline: String? = nil,
    deadlineOverdue: Bool = false, health: String? = nil
  ) {
    self.type = type
    self.rope = rope
    self.deadline = deadline
    self.deadlineOverdue = deadlineOverdue
    self.health = health
  }

  enum CodingKeys: String, CodingKey {
    case type, rope, deadline, health
    case deadlineOverdue = "deadline_overdue"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func text(_ key: CodingKeys) -> String? {
      let value = ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    }
    type = text(.type).map { String($0.prefix(16)) }
    rope = text(.rope)
    deadline = RemoteOrganizerMatterMap.isoDay(text(.deadline))
    deadlineOverdue =
      ((try? c.decodeIfPresent(Bool.self, forKey: .deadlineOverdue)) ?? nil) ?? false
    health = text(.health).flatMap { ["ok", "risk", "stuck"].contains($0) ? $0 : nil }
  }
}

/// A rope (`/v1/state` → `ropes`): long-lived matters or a bigger project
/// that holds matters (`children`) and maybe other ropes (their `parent` is
/// this one). A tree: each matter has at most one rope.
public struct RemoteOrganizerRope: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  /// A short `R<n>` handle, stable per store.
  public let handle: String?
  public var title: String
  /// `area` (a part of life that never ends) or `project`.
  public let kind: String?
  public var parent: String?
  /// Event IDs of the matters on it, in the organizer's order.
  public var children: [String]
  /// Proposed by the grouping pass and not yet confirmed by the user.
  public var proposed: Bool
  public var titleUserEdited: Bool
  /// One line: why these matters belong together.
  public var reason: String
  public let evidence: [String]

  public var isArea: Bool { kind == "area" }

  public init(
    id: String, handle: String? = nil, title: String, kind: String? = nil,
    parent: String? = nil, children: [String] = [], proposed: Bool = true,
    titleUserEdited: Bool = false, reason: String = "", evidence: [String] = []
  ) {
    self.id = id
    self.handle = handle
    self.title = title
    self.kind = kind
    self.parent = parent
    self.children = children
    self.proposed = proposed
    self.titleUserEdited = titleUserEdited
    self.reason = reason
    self.evidence = evidence
  }

  enum CodingKeys: String, CodingKey {
    case id, handle, title, kind, parent, children, proposed, reason, evidence
    case titleUserEdited = "title_user_edited"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try RemoteOrganizerMatterMap.identifier(c.decode(String.self, forKey: .id))
    handle = (try? c.decodeIfPresent(String.self, forKey: .handle)) ?? nil
    title = RemoteOrganizerMatterMap.line(try c.decode(String.self, forKey: .title), limit: 40)
    guard !title.isEmpty else { throw RemoteOrganizerMatterMap.Malformed() }
    let rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
    kind = rawKind == "area" || rawKind == "project" ? rawKind : nil
    let rawParent = ((try? c.decodeIfPresent(String.self, forKey: .parent)) ?? nil)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    parent = rawParent?.isEmpty == false && rawParent != id ? rawParent : nil
    children = RemoteOrganizerMatterMap.ids(c, .children)
    proposed = ((try? c.decodeIfPresent(Bool.self, forKey: .proposed)) ?? nil) ?? true
    titleUserEdited =
      ((try? c.decodeIfPresent(Bool.self, forKey: .titleUserEdited)) ?? nil) ?? false
    reason = RemoteOrganizerMatterMap.line(
      (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? "", limit: 120)
    evidence = RemoteOrganizerMatterMap.ids(c, .evidence)
  }
}

/// A relation between two matters (`/v1/state` → `relations`).
/// - `cross`: computed, no model: the matters share `count` items (parts of
///   one meeting or message).
/// - `blocks`: from an explicit statement in the evidence: `a` blocks `b`,
///   so **b waits on a**. `quote` is verbatim in `itemID`.
public struct RemoteOrganizerRelation: Codable, Equatable, Sendable {
  public let kind: String
  public let a: String
  public let b: String
  public let count: Int?
  /// A crossing's shared items (at most ten).
  public let itemIDs: [String]
  public var quote: String?
  public let itemID: String?
  public let segID: String?
  public let proposed: Bool
  /// The matter whose map proposed a blocks edge.
  public let sourceEvent: String?

  public var isCross: Bool { kind == "cross" }
  public var isBlocks: Bool { kind == "blocks" }

  public init(
    kind: String, a: String, b: String, count: Int? = nil, itemIDs: [String] = [],
    quote: String? = nil, itemID: String? = nil, segID: String? = nil, proposed: Bool = false,
    sourceEvent: String? = nil
  ) {
    self.kind = kind
    self.a = a
    self.b = b
    self.count = count
    self.itemIDs = itemIDs
    self.quote = quote
    self.itemID = itemID
    self.segID = segID
    self.proposed = proposed
    self.sourceEvent = sourceEvent
  }

  enum CodingKeys: String, CodingKey {
    case kind, a, b, count, quote, proposed
    case itemIDs = "item_ids"
    case itemID = "item_id"
    case segID = "seg_id"
    case sourceEvent = "source_event"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decode(String.self, forKey: .kind)
    guard kind == "cross" || kind == "blocks" else { throw RemoteOrganizerMatterMap.Malformed() }
    a = try RemoteOrganizerMatterMap.identifier(c.decode(String.self, forKey: .a))
    b = try RemoteOrganizerMatterMap.identifier(c.decode(String.self, forKey: .b))
    guard a != b else { throw RemoteOrganizerMatterMap.Malformed() }
    count = ((try? c.decodeIfPresent(Int.self, forKey: .count)) ?? nil).map { max($0, 0) }
    itemIDs = RemoteOrganizerMatterMap.ids(c, .itemIDs)
    quote = ((try? c.decodeIfPresent(String.self, forKey: .quote)) ?? nil)
      .map { String($0.prefix(RemoteOrganizerMatterMap.quoteLimit)) }
    itemID = (try? c.decodeIfPresent(String.self, forKey: .itemID)) ?? nil
    segID = (try? c.decodeIfPresent(String.self, forKey: .segID)) ?? nil
    proposed = ((try? c.decodeIfPresent(Bool.self, forKey: .proposed)) ?? nil) ?? (kind == "blocks")
    sourceEvent = (try? c.decodeIfPresent(String.self, forKey: .sourceEvent)) ?? nil
  }

  /// Whether this relation joins the two matters, in either order.
  public func joins(_ x: String, _ y: String) -> Bool {
    (a == x && b == y) || (a == y && b == x)
  }
}

/// One entry that may fail to decode without failing the rest.
struct Lenient<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}

// MARK: - Putting originals back (privacy contract §3)

extension RemoteOrganizerMatterMap {
  /// Every text the organizing device wrote, through `text` (unmask).
  public func unmasked(_ text: (String) -> String) -> RemoteOrganizerMatterMap {
    var copy = self
    copy.strands = strands.map { strand in
      var strand = strand
      strand.name = text(strand.name)
      strand.summary = text(strand.summary)
      return strand
    }
    copy.knots = knots.map { knot in
      var knot = knot
      knot.text = text(knot.text)
      knot.who = knot.who.map(text)
      knot.quote = text(knot.quote)
      return knot
    }
    copy.health = health.map { health in
      var health = health
      health.reason = text(health.reason)
      return health
    }
    return copy
  }
}

extension RemoteOrganizerRope {
  public func unmasked(_ text: (String) -> String) -> RemoteOrganizerRope {
    var copy = self
    copy.title = text(title)
    copy.reason = text(reason)
    return copy
  }
}

extension RemoteOrganizerRelation {
  public func unmasked(_ text: (String) -> String) -> RemoteOrganizerRelation {
    var copy = self
    copy.quote = quote.map(text)
    return copy
  }
}
