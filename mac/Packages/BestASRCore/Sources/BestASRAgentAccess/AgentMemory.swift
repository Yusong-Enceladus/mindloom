import BestASRDomain
import BestASRMemory
import Foundation

/// A space an agent may be given: 我的, or a shared space (SPACES-CONTRACT).
public struct AgentSpace: Equatable, Hashable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  public static let personal = AgentSpace(id: AgentSpaceID.personal, name: "我的")
}

/// A rope (MAP-CONTRACT §2 成股): long-lived context holding matters, nested.
public struct AgentRope: Equatable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let parentID: String?
  public let matterIDs: [String]

  public init(id: String, title: String, parentID: String? = nil, matterIDs: [String]) {
    self.id = id
    self.title = title
    self.parentID = parentID
    self.matterIDs = matterIDs
  }
}

/// A strand of a matter's map (MAP-CONTRACT §1), when the map exists.
public struct AgentStrand: Equatable, Sendable {
  public let id: String
  public let name: String
  public let summary: String
  public let itemIDs: [String]
  public let isOpen: Bool

  public init(id: String, name: String, summary: String, itemIDs: [String], isOpen: Bool) {
    self.id = id
    self.name = name
    self.summary = summary
    self.itemIDs = itemIDs
    self.isOpen = isOpen
  }
}

/// A matter the owner can pick in the consent sheet or approve one by one.
public struct AgentMatterOption: Equatable, Hashable, Sendable, Identifiable {
  public let id: String
  public let title: String

  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// What 织机 holds right now, as the memory pages see it (the organizing
/// device's projection with the owner's decisions applied, or the local
/// organizer's events). Built per call; nothing is cached across grants.
public struct AgentMemorySnapshot: Sendable {
  public let projection: MemoryProjection
  public let spaces: [AgentSpace]
  public let ropes: [AgentRope]
  /// Matter ID (upper-case) → space ID; absent means the personal space.
  public let spaceOfMatter: [String: String]
  /// Matter ID (upper-case) → its strands, when a map exists.
  public let strands: [String: [AgentStrand]]
  public let timeZone: TimeZone

  public init(
    projection: MemoryProjection, spaces: [AgentSpace] = [.personal], ropes: [AgentRope] = [],
    spaceOfMatter: [String: String] = [:], strands: [String: [AgentStrand]] = [:],
    timeZone: TimeZone = .current
  ) {
    self.projection = projection
    self.spaces = spaces.isEmpty ? [.personal] : spaces
    self.ropes = ropes
    var spaceMap: [String: String] = [:]
    for (key, value) in spaceOfMatter { spaceMap[key.uppercased()] = value }
    self.spaceOfMatter = spaceMap
    var strandMap: [String: [AgentStrand]] = [:]
    for (key, value) in strands { strandMap[key.uppercased()] = value }
    self.strands = strandMap
    self.timeZone = timeZone
  }

  public var now: Date { projection.now }

  public func space(of matterID: String) -> String {
    spaceOfMatter[matterID.uppercased()] ?? AgentSpaceID.personal
  }

  public func spaceName(_ id: String) -> String {
    spaces.first { $0.id == id }?.name ?? (id == AgentSpaceID.personal ? "我的" : id)
  }

  /// The ropes holding a matter, innermost first, then the ropes around them.
  public func ropeChain(of matterID: String) -> [AgentRope] {
    let key = matterID.uppercased()
    guard var rope = ropes.first(where: { $0.matterIDs.contains { $0.uppercased() == key } })
    else { return [] }
    var chain = [rope]
    var seen: Set<String> = [rope.id]
    while let parentID = rope.parentID,
      let parent = ropes.first(where: { $0.id == parentID }),
      seen.insert(parent.id).inserted
    {
      chain.append(parent)
      rope = parent
    }
    return chain
  }

  public func strands(of matterID: String) -> [AgentStrand] {
    strands[matterID.uppercased()] ?? []
  }
}

/// A shared space as an agent may see it (SPACES-CONTRACT): the space and its
/// own read model (the space organizer's state with the members' items).
public struct AgentSpaceSource: Sendable {
  public let space: AgentSpace
  public let projection: MemoryProjection

  public init(space: AgentSpace, projection: MemoryProjection) {
    self.space = space
    self.projection = projection
  }
}

extension AgentMemorySnapshot {
  /// A shared space's matter as agents (and the 全部 view) name it.
  public static func spaceMatterID(space: String, event: String) -> String {
    "space:\(space):\(event)"
  }

  /// 我的 plus the shared spaces this Mac is a member of, with the matter
  /// map's ropes and strands (v7 integration of AGENT-, MAP- and
  /// SPACES-CONTRACT). A space's matters keep their own items and are
  /// labelled with their space — never folded into the member's own matter
  /// as 全部 shows them — so a grant for 我的 never reaches them, and a grant
  /// for a space reaches only that space. A space's ropes and relations are
  /// renamed into the same id space; ids of 我的 are unchanged.
  public init(
    personal: MemoryProjection, spaces: [AgentSpaceSource], timeZone: TimeZone = .current
  ) {
    var events = personal.events
    var records = Array(personal.records.values)
    var seenRecords = Set(records.map { $0.sessionID.rawValue })
    var persons = personal.persons
    var seenPersons = Set(persons.map(\.personID))
    var readings = personal.remoteReadings
    var summaries = personal.remoteReadingSummaries
    var facts = personal.remoteReadingFacts
    var ropes = personal.ropes
    var relations = personal.relations
    var spaceOfMatter: [String: String] = [:]
    var agentSpaces: [AgentSpace] = [.personal]
    for source in spaces where source.space.id != AgentSpaceID.personal {
      guard !agentSpaces.contains(where: { $0.id == source.space.id }) else { continue }
      agentSpaces.append(source.space)
      let spaceID = source.space.id
      func rename(_ id: String) -> String { Self.spaceMatterID(space: spaceID, event: id) }
      for event in source.projection.events {
        let id = rename(event.eventID)
        spaceOfMatter[id] = spaceID
        events.append(
          MemoryEventSource(
            eventID: id, origin: event.origin, title: event.title, statusLine: event.statusLine,
            pinned: false, startedAt: event.startedAt, updatedAt: event.updatedAt,
            itemIDs: event.itemIDs, personIDs: event.personIDs, statusFacts: event.statusFacts,
            handle: nil, segments: event.segments, map: event.map, facets: nil,
            listedFacts: event.listedFacts))
      }
      for record in source.projection.records.values
      where seenRecords.insert(record.sessionID.rawValue).inserted {
        records.append(record)
      }
      for person in source.projection.persons where seenPersons.insert(person.personID).inserted {
        persons.append(person)
      }
      readings.merge(source.projection.remoteReadings) { mine, _ in mine }
      summaries.merge(source.projection.remoteReadingSummaries) { mine, _ in mine }
      facts.merge(source.projection.remoteReadingFacts) { mine, _ in mine }
      for rope in source.projection.ropes {
        ropes.append(
          RemoteOrganizerRope(
            id: rename(rope.id), handle: nil, title: rope.title, kind: rope.kind,
            parent: rope.parent.map(rename), children: rope.children.map(rename),
            proposed: rope.proposed, titleUserEdited: rope.titleUserEdited, reason: rope.reason,
            evidence: rope.evidence))
      }
      for relation in source.projection.relations {
        relations.append(
          RemoteOrganizerRelation(
            kind: relation.kind, a: rename(relation.a), b: rename(relation.b),
            count: relation.count, itemIDs: relation.itemIDs, quote: relation.quote,
            itemID: relation.itemID, segID: relation.segID, proposed: relation.proposed,
            sourceEvent: relation.sourceEvent.map(rename)))
      }
    }
    let projection = MemoryProjection(
      events: events, records: records, persons: persons, questions: personal.questions,
      remoteReadings: readings, remoteReadingSummaries: summaries, remoteReadingFacts: facts,
      unfiled: personal.unfiled, localQuestions: personal.localQuestions, now: personal.now,
      ownerPersonIDs: personal.ownerPersonIDs, ropes: ropes, relations: relations)
    var strands: [String: [AgentStrand]] = [:]
    for event in projection.events {
      guard let map = event.map, !map.strands.isEmpty else { continue }
      strands[event.eventID] = map.strands.map {
        AgentStrand(
          id: $0.id, name: $0.name, summary: $0.summary, itemIDs: $0.itemIDs, isOpen: !$0.isClosed)
      }
    }
    self.init(
      projection: projection, spaces: agentSpaces,
      ropes: projection.ropes.map {
        AgentRope(id: $0.id, title: $0.title, parentID: $0.parent, matterIDs: $0.children)
      },
      spaceOfMatter: spaceOfMatter, strands: strands, timeZone: timeZone)
  }
}

/// The App (or a harness) hands the service what 织机 holds.
public protocol AgentMemoryProviding: Sendable {
  /// Nil while the library is not open.
  func agentSnapshot() async -> AgentMemorySnapshot?
}

// MARK: - Consent

/// What the consent sheet offers.
public struct AgentConsentOptions: Equatable, Sendable {
  public let spaces: [AgentSpace]
  public let ropes: [AgentRope]
  /// Recent matters first.
  public let matters: [AgentMatterOption]

  public init(spaces: [AgentSpace], ropes: [AgentRope], matters: [AgentMatterOption]) {
    self.spaces = spaces
    self.ropes = ropes
    self.matters = matters
  }
}

/// 「Claude Code 想读取织机」.
public struct AgentConsentRequest: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let client: AgentClientIdentity
  public let options: AgentConsentOptions
  public let requestedAt: Date

  public init(
    id: UUID = UUID(), client: AgentClientIdentity, options: AgentConsentOptions,
    requestedAt: Date
  ) {
    self.id = id
    self.client = client
    self.options = options
    self.requestedAt = requestedAt
  }
}

public enum AgentConsentAnswer: Equatable, Sendable {
  case allow(AgentGrantTerms)
  case deny
}

/// "读新的一件事时先问我": matters the grant has not been answered for yet.
public struct AgentMatterApprovalRequest: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let client: AgentClientIdentity
  public let matters: [AgentMatterOption]

  public init(id: UUID = UUID(), client: AgentClientIdentity, matters: [AgentMatterOption]) {
    self.id = id
    self.client = client
    self.matters = matters
  }
}

/// The owner's side: the App shows a notification and a sheet; tests and
/// the harness answer by script. Calls may take as long as the owner does;
/// the service stops waiting after its own timeout but applies an answer
/// that comes later.
public protocol AgentConsentPresenting: Sendable {
  /// Nil when the sheet was closed without an answer (treated as 不同意).
  func requestConsent(_ request: AgentConsentRequest) async -> AgentConsentAnswer?
  /// Matter ID → allowed, for the matters the owner answered.
  func approveMatters(_ request: AgentMatterApprovalRequest) async -> [String: Bool]
  func proposalArrived(_ proposal: AgentInboxProposal) async
  /// Grants, the audit or the inbox changed (for the Settings page).
  func accessChanged() async
  /// One call was audited (ids, counts and the outcome; never content). The
  /// App records reads of a shared space in that space's log as
  /// `agent.access` (SPACES-CONTRACT §1, the org audit log).
  func accessRecorded(_ record: AgentAuditRecord) async
}

extension AgentConsentPresenting {
  public func accessRecorded(_ record: AgentAuditRecord) async {}
}

/// What one audited agent call tells a shared space's log (`agent.access`,
/// SPACES-CONTRACT §1): who read, with which tool, how many of the space's
/// matters and items, and how many bytes — counts only, never ids or content.
public struct AgentSpaceAccess: Equatable, Sendable {
  public let spaceID: String
  public let client: String
  public let tool: String
  public let matters: Int
  public let items: Int
  public let bytes: Int
  public let allowed: Bool

  public init(
    spaceID: String, client: String, tool: String, matters: Int, items: Int, bytes: Int,
    allowed: Bool
  ) {
    self.spaceID = spaceID
    self.client = client
    self.tool = tool
    self.matters = matters
    self.items = items
    self.bytes = bytes
    self.allowed = allowed
  }

  /// The space a matter id names (`space:<space>:<event>`), or nil for 我的.
  public static func space(ofMatter id: String) -> String? {
    guard id.hasPrefix("space:") else { return nil }
    let rest = id.dropFirst("space:".count)
    guard let colon = rest.firstIndex(of: ":"), colon != rest.startIndex,
      rest.index(after: colon) != rest.endIndex
    else { return nil }
    return String(rest[..<colon])
  }

  /// One entry per shared space whose matters the call returned (allowed) or
  /// asked for (denied); calls about 我的 only, pending ones and failures
  /// tell no space anything. The audit keeps one byte count per call, so a
  /// call spanning several spaces gives each its share by matter count.
  public static func entries(
    for record: AgentAuditRecord, itemCount: (String) -> Int
  ) -> [AgentSpaceAccess] {
    guard record.outcome == .allowed || record.outcome == .denied else { return [] }
    var bySpace: [String: [String]] = [:]
    var order: [String] = []
    for id in Set(record.matterIDs).sorted() {
      guard let space = space(ofMatter: id) else { continue }
      if bySpace[space] == nil { order.append(space) }
      bySpace[space, default: []].append(id)
    }
    let total = Set(record.matterIDs).count
    return order.map { space in
      let ids = bySpace[space] ?? []
      return AgentSpaceAccess(
        spaceID: space, client: record.clientName, tool: record.tool, matters: ids.count,
        items: ids.reduce(0) { $0 + max(0, itemCount($1)) },
        bytes: total > 0 ? record.byteCount * ids.count / total : 0,
        allowed: record.outcome == .allowed)
    }
  }
}
