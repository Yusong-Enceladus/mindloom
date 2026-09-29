import BestASRDomain
import BestASRMemory
import Foundation

/// The run's JSON summary. It names items by their fixture label and matter
/// and never carries item text, image bytes, titles or status lines.
struct SparkEndToEndSummary: Encodable {
  struct StatusChange: Encodable {
    let atSeconds: Double
    let status: String
  }

  struct Item: Encodable {
    let label: String
    let matter: String
    let kind: String
    let sourceApp: String
    let capturedAt: String
    /// `event:<Home rank>`, `unfiled:<reason>`, or `missing`.
    let placement: String
    let jobState: String?
    let jobErrorCategory: String?
    let retryCount: Int?
    /// From the local commit to the Spark's receipt.
    let deliveredLatencySeconds: Double?
    /// From the local commit until the item was first seen organized (polled
    /// every 2 s).
    let organizedLatencySeconds: Double?
  }

  struct Event: Encodable {
    let homeRank: Int
    let itemCount: Int
    let itemLabels: [String]
    /// Items per fixture matter; a matter split over events or an event
    /// mixing matters shows here.
    let matters: [String: Int]
    let personCount: Int
    let hasStatusLine: Bool
    let statusFactCount: Int
    let importance: Double
    let pinned: Bool
  }

  struct Question: Encodable {
    let kind: String
    /// Item labels, `event:<rank>`, or `person` for the two sides.
    let a: String
    let b: String
  }

  struct Unfiled: Encodable {
    let label: String
    let reason: String
  }

  struct MatterGrouping: Encodable {
    let matter: String
    let items: Int
    /// Home ranks of the events holding this matter's items.
    let events: [Int]
    let unfiled: Int
    let missing: Int
    /// All of this matter's items share one event that holds no other matter
    /// (for `noise`: the item is in Unfiled).
    let clean: Bool
  }

  struct Revocation: Encodable {
    let linkEnabledAfter: Bool
    let pendingItemJobs: Int
    let pendingDecisionJobs: Int
    let activeTunnels: Int
    let tunnelRecords: Int
    let intentCleared: Bool
  }

  let host: String
  var itemsIngested: Int
  var itemsSent: Int
  let timeZone: String
  var storeID: String?
  var serviceClock: String?
  var settled = false
  var timedOut = false
  var elapsedSeconds: Double = 0
  var items: [Item] = []
  var events: [Event] = []
  var grouping: [MatterGrouping] = []
  var questions: [Question] = []
  var unfiled: [Unfiled] = []
  var personCount = 0
  var namedPersonCount = 0
  var statusChanges: [StatusChange] = []
  var revocation: Revocation?
  var snapshots: [String] = []
  var exports: [String] = []
  var errors: [String] = []

  mutating func describe(
    remote: RemoteOrganizerProjection, home: [MemoryHomeEntry],
    tracked: [SparkEndToEndTests.Tracked], jobs: [String: SparkEndToEndTests.JobRow],
    personCount: Int, namedPersonCount: Int
  ) {
    let labelByID = Dictionary(uniqueKeysWithValues: tracked.map { ($0.id, $0.item.label) })
    let matterByID = Dictionary(
      uniqueKeysWithValues: tracked.map { ($0.id, $0.item.matter.rawValue) })
    // Home order is what the user sees; ranks refer to it.
    let rankByEvent = Dictionary(
      uniqueKeysWithValues: home.enumerated().map { ($1.eventID, $0 + 1) })
    let events = remote.events.filter { !$0.deleted }
    var placement: [String: String] = [:]
    for event in events {
      let rank = rankByEvent[event.eventID] ?? 0
      for id in event.itemIDs { placement[id.uppercased()] = "event:\(rank)" }
    }
    for item in remote.unfiled where placement[item.itemID.uppercased()] == nil {
      placement[item.itemID.uppercased()] = "unfiled:\(item.reason)"
    }
    let iso = ISO8601DateFormatter()
    iso.timeZone = SyntheticWeek.zone
    items = tracked.map { entry in
      let job = jobs[entry.id]
      return Item(
        label: entry.item.label, matter: entry.item.matter.rawValue,
        kind: entry.item.content.kind, sourceApp: entry.item.app.name,
        capturedAt: iso.string(from: entry.item.capturedAt),
        placement: placement[entry.id] ?? "missing", jobState: job?.state,
        jobErrorCategory: job?.errorCategory, retryCount: job?.retryCount,
        deliveredLatencySeconds: job?.deliveredAt.map {
          Self.rounded($0 - entry.ingestedAt.timeIntervalSince1970)
        },
        organizedLatencySeconds: entry.organizedAt.map {
          Self.rounded($0.timeIntervalSince(entry.ingestedAt))
        })
    }
    self.events = events.map { event in
      var matters: [String: Int] = [:]
      for id in event.itemIDs {
        matters[matterByID[id.uppercased()] ?? "unknown", default: 0] += 1
      }
      return Event(
        homeRank: rankByEvent[event.eventID] ?? 0, itemCount: event.itemIDs.count,
        itemLabels: event.itemIDs.map { labelByID[$0.uppercased()] ?? "unknown" },
        matters: matters, personCount: event.personIDs.count,
        hasStatusLine: !event.statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty,
        statusFactCount: event.statusFacts.count, importance: event.importance,
        pinned: event.pinned)
    }.sorted { $0.homeRank < $1.homeRank }
    grouping = SyntheticWeek.Matter.allCases.map { matter in
      let ids = tracked.filter { $0.item.matter == matter }.map(\.id)
      let spots = ids.map { placement[$0] ?? "missing" }
      let ranks = Set(
        spots.compactMap { $0.hasPrefix("event:") ? Int($0.dropFirst(6)) : nil }
      ).sorted()
      // The unrelated item belongs in Unfiled; every matter in one event of
      // its own.
      let clean =
        matter == .noise
        ? spots.allSatisfy { $0.hasPrefix("unfiled:") }
        : ranks.count == 1 && !spots.contains { !$0.hasPrefix("event:") }
          && self.events.first { $0.homeRank == ranks[0] }?.matters.count == 1
      return MatterGrouping(
        matter: matter.rawValue, items: ids.count, events: ranks,
        unfiled: spots.filter { $0.hasPrefix("unfiled:") }.count,
        missing: spots.filter { $0 == "missing" }.count, clean: clean)
    }
    func side(_ value: String) -> String {
      if let label = labelByID[value.uppercased()] { return label }
      if let rank = rankByEvent[value] { return "event:\(rank)" }
      if remote.persons.contains(where: { $0.personID == value }) { return "person" }
      return "other"
    }
    questions = remote.questions.map { Question(kind: $0.kind, a: side($0.a), b: side($0.b)) }
    unfiled = remote.unfiled.map {
      Unfiled(label: labelByID[$0.itemID.uppercased()] ?? "unknown", reason: $0.reason)
    }
    self.personCount = personCount
    self.namedPersonCount = namedPersonCount
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
