import BestASRDomain
import Foundation

/// One event as the memory pages use it, whichever organizer produced it:
/// the user's Spark (through the local projection with the user's decisions
/// applied) or the on-device fallback organizer.
public struct MemoryEventSource: Equatable, Sendable {
  public enum Origin: String, Equatable, Sendable {
    case spark
    case local
  }

  public let eventID: String
  public let origin: Origin
  public let title: String
  public let statusLine: String
  public let pinned: Bool
  /// When the event started, as its organizer reports it (the Spark's
  /// `started_at`); the span shown is taken from the items when present.
  public let startedAt: Date?
  public let updatedAt: Date?
  public let itemIDs: [String]
  public let personIDs: [String]
  /// The Spark's "where it stands" facts; empty for the local organizer.
  public let statusFacts: [MemoryStatusFact]
  /// The Spark's short `E<n>` ID, if any.
  public let handle: String?
  /// The parts of items this event holds when an item covers several
  /// matters; an item with none here is held whole.
  public let segments: [MemoryItemSegment]

  public init(
    eventID: String, origin: Origin, title: String, statusLine: String, pinned: Bool,
    startedAt: Date? = nil, updatedAt: Date?, itemIDs: [String], personIDs: [String],
    statusFacts: [MemoryStatusFact] = [], handle: String? = nil,
    segments: [MemoryItemSegment] = []
  ) {
    self.eventID = eventID
    self.origin = origin
    self.title = title
    self.statusLine = statusLine
    self.pinned = pinned
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.itemIDs = itemIDs
    self.personIDs = personIDs
    self.statusFacts = statusFacts
    self.handle = handle
    self.segments = segments
  }
}

/// One part of an item that covers several matters (a meeting transcript,
/// a long note), as one event holds it: Unicode-scalar offsets in the
/// item's text and the organizer's short description of the part.
public struct MemoryItemSegment: Equatable, Hashable, Sendable {
  public let itemID: String
  public let segID: String
  public let start: Int
  public let end: Int
  /// Written by the organizer; not source text.
  public let gist: String

  public init(itemID: String, segID: String, start: Int, end: Int, gist: String) {
    self.itemID = itemID
    self.segID = segID
    self.start = start
    self.end = end
    self.gist = gist
  }
}

/// Another event that holds a part of the same item.
public struct MemorySegmentSibling: Equatable, Sendable {
  public let eventID: String
  public let title: String
  /// That event's part, in the organizer's words; empty when it holds the
  /// item whole.
  public let gist: String

  public init(eventID: String, title: String, gist: String) {
    self.eventID = eventID
    self.title = title
    self.gist = gist
  }
}

/// When an event happened: from its earliest to its latest item held on this
/// Mac, else the organizer's start time. Nil when nothing is known.
public struct MemoryEventSpan: Equatable, Sendable {
  public let start: Date
  public let end: Date

  public init(start: Date, end: Date) {
    self.start = min(start, end)
    self.end = max(start, end)
  }
}

public struct MemoryPersonRef: Equatable, Hashable, Sendable {
  public let personID: String
  /// The person's name, or "?" while nobody named them.
  public let name: String
  public let isNamed: Bool

  /// One of six voice colours. The projection assigns it so that the people
  /// on Home never share one (see `MemoryProjection.personColors`); a
  /// person it has not seen keeps the colour of their ID.
  public var colorIndex: Int

  public init(personID: String, name: String, isNamed: Bool = true, colorIndex: Int? = nil) {
    self.personID = personID
    self.name = name
    self.isNamed = isNamed
    self.colorIndex = colorIndex ?? MemoryPersonColor.index(for: personID)
  }
}

/// A few lines of an event's newest text, for a card with no screenshot: a
/// pasted chat, a document or a note, else a transcript.
public struct MemoryCoverText: Equatable, Sendable {
  /// The document's name, or the App it came from.
  public let heading: String
  /// Its first non-empty lines, each on one line.
  public let lines: [String]

  public init(heading: String, lines: [String]) {
    self.heading = heading
    self.lines = lines
  }
}

/// A Home card.
public struct MemoryHomeEntry: Equatable, Identifiable, Sendable {
  public let eventID: String
  public let origin: MemoryEventSource.Origin
  public let title: String
  public let statusLine: String
  public var people: [MemoryPersonRef]
  public let itemCount: Int
  /// The date or date range the card shows.
  public let span: MemoryEventSpan?
  public let lastUpdate: Date?
  public let pinned: Bool
  /// The first image item with a thumbnail, else the first item held locally.
  public let cover: MemoryItemRecord?
  /// True when no organizer wrote a status line and `statusLine` is the
  /// newest item's first line instead (shown in secondary).
  public let statusIsFallback: Bool
  /// The card's text cover when it has no screenshot to show.
  public var coverText: MemoryCoverText?
  /// What was said and taken in: the items' text and screenshot readings,
  /// for search. Never shown.
  public var searchText = ""
  /// People of `people` the avatars leave out (see
  /// `MemoryProjection.isShownPerson`); they stay in `people` for search,
  /// transcripts and their own pages.
  public var hiddenPersonIDs: Set<String> = []

  public var id: String { eventID }

  /// The people the card and the loom lane draw.
  public var shownPeople: [MemoryPersonRef] {
    hiddenPersonIDs.isEmpty ? people : people.filter { !hiddenPersonIDs.contains($0.personID) }
  }

  /// Search on Home: title, status line, people's names, and what was said
  /// or taken in (the items' text and readings).
  public func matches(_ query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    return ([title, statusLine, searchText] + people.map(\.name)).contains {
      $0.localizedCaseInsensitiveContains(needle)
    }
  }
}

/// One row of an event's item list.
public struct MemoryEventItem: Equatable, Identifiable, Sendable {
  public let itemID: String
  /// Nil when the item is not on this Mac any more (deleted) or never was.
  public let record: MemoryItemRecord?
  /// The Spark's reading of a screenshot, when it provides one.
  public let remoteReading: String?
  /// The summary the Spark sent apart from `remoteReading` (`""` for none);
  /// nil from an older Spark, whose summary is the reading's first line.
  public var remoteReadingSummary: String?
  /// A file reading's type, key fields, counts, inner files and error.
  public var remoteReadingFacts: RemoteOrganizerReadingFacts?
  /// Speaker names resolved the same way as the event's people (merged
  /// persons followed, the Spark's name preferred), keyed by the upper-case
  /// person ID, so a transcript and the 人物 line agree.
  public let speakerNames: [String: String]
  /// Upper-case person IDs in `speakerNames` that are the Mac's user: their
  /// turns are drawn without a person colour.
  public var ownerSpeakers: Set<String> = []
  /// The part of the item this event holds; nil when it holds all of it.
  public var segment: MemoryItemSegment?
  /// Other events holding parts of the same item, in Home order.
  public var siblings: [MemorySegmentSibling] = []

  public init(
    itemID: String, record: MemoryItemRecord?, remoteReading: String?,
    speakerNames: [String: String] = [:]
  ) {
    self.itemID = itemID
    self.record = record
    self.remoteReading = remoteReading
    self.speakerNames = speakerNames
  }

  /// Unique in one event: an item held in parts has one row per part.
  public var id: String { segment.map { "\(itemID)#\($0.segID)" } ?? itemID }
  public var sourceLabel: String { record?.sourceLabel ?? "未知来源" }

  /// The item's own text as this event shows it: the part it holds, else
  /// all of it. Nil while nothing is committed.
  public var shownText: String? {
    guard let text = record?.text else { return nil }
    guard let segment else { return text }
    return MemoryTranscriptText.slice(text, start: segment.start, end: segment.end)
  }
  public var startedAt: Date? { record?.startedAt }
  public var playbackAvailable: Bool { record?.playbackAvailable ?? false }
  public var thumbnailAssetPath: String? { record?.thumbnailAssetPath }

  /// A file item's reading by the organizing device, else nil.
  public var fileReading: MemoryFileReading? {
    guard record?.itemKind == .file || remoteReadingFacts != nil else { return nil }
    let text = remoteReading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var summary = remoteReadingSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
    var body = text
    // An older device put its summary on the reading's first line.
    if summary == nil, let first = MemoryProjection.firstLine(text) {
      summary = first
      body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let reading = MemoryFileReading(
      summary: summary.flatMap { $0.isEmpty ? nil : $0 }, text: body, facts: remoteReadingFacts)
    return reading.isEmpty ? nil : reading
  }

  /// A screenshot's reading: the organizing device's, else the one made on
  /// this Mac. Nil when there is none.
  public var reading: MemoryScreenshotReading? {
    let remote = remoteReading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let remoteSummary = remoteReadingSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
    if !remote.isEmpty || !(remoteSummary ?? "").isEmpty {
      return MemoryScreenshotReading(organizer: remote, summary: remoteSummary)
    }
    if let local = record?.localReading?.trimmingCharacters(in: .whitespacesAndNewlines),
      !local.isEmpty
    {
      return MemoryScreenshotReading(local: local)
    }
    return nil
  }
}

public struct MemoryEventDetail: Equatable, Sendable {
  public let eventID: String
  public let origin: MemoryEventSource.Origin
  public let title: String
  public let statusLine: String
  public let people: [MemoryPersonRef]
  /// The date or date range of the event, for the export and the page header.
  public let span: MemoryEventSpan?
  /// Time order; items with no local record come last, in the organizer's order.
  public let items: [MemoryEventItem]
  public let pendingQuestions: [RemoteOrganizerQuestion]
  /// Classified, unexpired questions about this event or its items.
  public var questions: [MemoryQuestion] = []
  public var statusFacts: [MemoryStatusFact] = []
  public var statusIsFallback = false
  /// As `MemoryHomeEntry.hiddenPersonIDs`.
  public var hiddenPersonIDs: Set<String> = []

  /// The people chips (`people` still colours and names the transcript).
  public var shownPeople: [MemoryPersonRef] {
    hiddenPersonIDs.isEmpty ? people : people.filter { !hiddenPersonIDs.contains($0.personID) }
  }

  /// Items grouped by the day they were captured, in time order. Items not
  /// held on this Mac come last in one group with no day.
  public func dayGroups(calendar: Calendar) -> [MemoryDayGroup] {
    var groups: [MemoryDayGroup] = []
    for item in items {
      let day = item.startedAt.map { calendar.startOfDay(for: $0) }
      if let last = groups.last, last.day == day {
        groups[groups.count - 1].items.append(item)
      } else {
        groups.append(MemoryDayGroup(day: day, items: [item]))
      }
    }
    return groups
  }
}

public struct MemoryDayGroup: Equatable, Identifiable, Sendable {
  public let day: Date?
  public var items: [MemoryEventItem]

  public init(day: Date?, items: [MemoryEventItem]) {
    self.day = day
    self.items = items
  }

  public var id: String { day.map { String($0.timeIntervalSince1970) } ?? "undated" }
}

public struct MemoryPersonEntry: Equatable, Identifiable, Sendable {
  public let personID: String
  /// The name, or "?" while nobody named them.
  public let name: String
  /// In Home order.
  public let events: [MemoryHomeEntry]
  public let pendingQuestions: [RemoteOrganizerQuestion]
  public var isNamed = true
  /// When they last appeared in any event.
  public var lastSeen: Date?

  public var id: String { personID }
  /// As `MemoryPersonRef.colorIndex`.
  public var colorIndex: Int

  public init(
    personID: String, name: String, events: [MemoryHomeEntry],
    pendingQuestions: [RemoteOrganizerQuestion], colorIndex: Int? = nil
  ) {
    self.personID = personID
    self.name = name
    self.events = events
    self.pendingQuestions = pendingQuestions
    self.colorIndex = colorIndex ?? MemoryPersonColor.index(for: personID)
  }
}

/// An item in no event: the Spark's Unfiled set, or on the local fallback
/// recent captures and items no event holds.
public struct MemoryUnfiledItem: Equatable, Identifiable, Sendable {
  public let item: MemoryEventItem
  /// `none`, `removed_by_user`, `user`, or `local`.
  public let reason: String

  public var id: String { item.itemID }
}

/// Builds the Home, Event, and People read models. Pure and deterministic:
/// the same inputs give the same output, and nothing here writes anything.
public struct MemoryProjection: Sendable {
  public let events: [MemoryEventSource]
  public let records: [String: MemoryItemRecord]
  public let persons: [RemoteOrganizerPerson]
  public let questions: [RemoteOrganizerQuestion]
  public let remoteReadings: [String: String]
  /// Summaries the Spark sent apart from `remoteReadings` (same keys); a
  /// reading missing here is from an older Spark (summary on its first line).
  public let remoteReadingSummaries: [String: String]
  /// File readings' type, fields, counts, inner files and error (same keys).
  public let remoteReadingFacts: [String: RemoteOrganizerReadingFacts]
  /// Items in no event (`itemID`, `reason`), in no particular order.
  public let unfiled: [RemoteOrganizerUnfiledItem]
  /// Questions made on this Mac (the local fallback organizer's candidates).
  public let localQuestions: [MemoryQuestion]
  /// The moment "now" for question expiry; injected for determinism.
  public let now: Date
  /// The Mac's user (upper-case person IDs). Never shown as one of the
  /// people of an event, as the organizer never counts the owner as shared;
  /// a person named 我 / 自己 / 本人 is the owner too.
  public let ownerPersonIDs: Set<String>
  /// Each named person's voice colour, by canonical person ID. The first
  /// `MemoryPersonColor.count` named people of the Home row never share one:
  /// taken in order of first appearance, each keeps the colour of their ID
  /// unless someone who appeared earlier has it, and then takes the next
  /// free one. Everyone else keeps the colour of their ID. Deterministic.
  public private(set) var personColors: [String: Int] = [:]

  /// How long an unanswered question stays (the organizer's rule).
  public static let questionLifetime: TimeInterval = 72 * 3_600

  /// `events` must already be in Home order (the Spark's home rank as the
  /// local projection returns it, or `localEvents` order).
  /// Derived once in `init` (the pages read them many times).
  private var personsByID: [String: RemoteOrganizerPerson] = [:]
  /// First local name of each local person ID (upper-case), in record order.
  private var localNames: [String: String] = [:]
  /// Upper-case item ID → the events holding parts of it, in Home order.
  private var segmentHolders: [String: [(eventID: String, title: String, gist: String)]] = [:]
  private var homeEntries: [MemoryHomeEntry] = []
  /// People heard in a recording on this Mac (canonical IDs, upper-case).
  private var heardPersonIDs: Set<String> = []
  /// People the pages draw as avatars and chips (see `isShownPerson`).
  private var shownPersonIDs: Set<String> = []

  public init(
    events: [MemoryEventSource], records: [MemoryItemRecord],
    persons: [RemoteOrganizerPerson] = [], questions: [RemoteOrganizerQuestion] = [],
    remoteReadings: [String: String] = [:], remoteReadingSummaries: [String: String] = [:],
    remoteReadingFacts: [String: RemoteOrganizerReadingFacts] = [:],
    unfiled: [RemoteOrganizerUnfiledItem] = [],
    localQuestions: [MemoryQuestion] = [], now: Date = Date(),
    ownerPersonIDs: Set<String> = []
  ) {
    self.events = events
    var byID: [String: MemoryItemRecord] = [:]
    for record in records { byID[Self.key(record.sessionID)] = record }
    self.records = byID
    self.persons = persons
    self.questions = questions
    var readings: [String: String] = [:]
    for (key, text) in remoteReadings { readings[key.uppercased()] = text }
    self.remoteReadings = readings
    var summaries: [String: String] = [:]
    for (key, text) in remoteReadingSummaries { summaries[key.uppercased()] = text }
    self.remoteReadingSummaries = summaries
    var facts: [String: RemoteOrganizerReadingFacts] = [:]
    for (key, value) in remoteReadingFacts { facts[key.uppercased()] = value }
    self.remoteReadingFacts = facts
    self.unfiled = unfiled
    self.localQuestions = localQuestions
    self.now = now
    self.ownerPersonIDs = Set(ownerPersonIDs.map { $0.uppercased() })
    personsByID = Dictionary(persons.map { ($0.personID, $0) }, uniquingKeysWith: { a, _ in a })
    for record in records.sorted(by: { Self.key($0.sessionID) < Self.key($1.sessionID) }) {
      for person in record.people {
        let key = person.id.rawValue.uuidString.uppercased()
        if localNames[key] == nil { localNames[key] = person.name }
      }
    }
    for event in events {
      var held = Set<String>()
      for part in event.segments where held.insert(part.itemID.uppercased()).inserted {
        segmentHolders[part.itemID.uppercased(), default: []].append(
          (event.eventID, event.title, part.gist))
      }
    }
    for record in records where record.inputMode != .userItem {
      let ids = record.people.map(\.id) + record.segments.compactMap(\.personID)
      for id in ids { heardPersonIDs.insert(canonicalID(id.rawValue.uuidString).uppercased()) }
    }
    // Colours come from the Home people row, which comes from Home; the
    // cards then take the assigned colours.
    let uncolored = events.map(homeEntry)
    let everyone = people(home: uncolored)
    shownPersonIDs = Set(everyone.filter(isShownPerson).map(\.personID))
    personColors = assignedColors(people: everyone)
    homeEntries = uncolored.map { entry in
      var entry = entry
      entry.people = entry.people.map(colored)
      entry.hiddenPersonIDs = hidden(entry.people)
      return entry
    }
  }

  /// From the Spark projection (already ordered by pin, importance, recency).
  /// Screenshot readings come from the projection (already matched to the
  /// delivered revision) unless `remoteReadings` is given (with its
  /// `remoteReadingSummaries`).
  public init(
    remote: RemoteOrganizerProjection, records: [MemoryItemRecord],
    remoteReadings: [String: String]? = nil, remoteReadingSummaries: [String: String]? = nil,
    now: Date = Date(),
    ownerPersonIDs: Set<String> = []
  ) {
    self.init(
      events: remote.events.filter { !$0.deleted }.map(Self.source),
      records: records, persons: remote.persons, questions: remote.questions,
      remoteReadings: remoteReadings ?? remote.readings,
      remoteReadingSummaries: remoteReadingSummaries
        ?? (remoteReadings == nil ? remote.readingSummaries : [:]),
      remoteReadingFacts: remoteReadings == nil ? remote.readingFacts : [:],
      unfiled: remote.unfiled, now: now,
      ownerPersonIDs: ownerPersonIDs
    )
  }

  /// All item IDs the events reference, for loading their local records.
  public static func referencedSessionIDs(_ events: [MemoryEventSource]) -> [SessionID] {
    sessionIDs(events.flatMap(\.itemIDs))
  }

  /// The same for any item IDs (for example the Unfiled set), each once.
  public static func sessionIDs(_ itemIDs: [String]) -> [SessionID] {
    var seen = Set<String>()
    var result: [SessionID] = []
    for id in itemIDs where seen.insert(id.uppercased()).inserted {
      if let uuid = UUID(uuidString: id) { result.append(SessionID(uuid)) }
    }
    return result
  }

  public static func source(_ event: RemoteOrganizerEvent) -> MemoryEventSource {
    MemoryEventSource(
      eventID: event.eventID, origin: .spark, title: event.title,
      statusLine: event.statusLine, pinned: event.pinned,
      startedAt: event.startedAt.flatMap(parseDate),
      updatedAt: event.updatedAt.flatMap(parseDate), itemIDs: event.itemIDs,
      personIDs: event.personIDs,
      statusFacts: MemoryStatusFact.ordered(event.statusFacts.map(MemoryStatusFact.init(remote:))),
      handle: event.handle,
      segments: event.segments.map {
        MemoryItemSegment(
          itemID: $0.itemID, segID: $0.segID, start: $0.start, end: $0.end, gist: $0.gist)
      }
    )
  }

  /// A local fallback event. The local organizer writes no status line; the
  /// first non-empty line of the user's notes stands in for it (one line,
  /// never the whole note). Its date span comes from its items like any
  /// event's. Ordered by the caller (recency).
  public static func localSource(
    eventID: EventID, title: String, notes: String, updatedAt: Date,
    sessionIDs: [SessionID], personIDs: [PersonID]
  ) -> MemoryEventSource {
    let firstLine =
      notes.split(whereSeparator: \.isNewline)
      .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    return MemoryEventSource(
      eventID: eventID.rawValue.uuidString, origin: .local, title: title,
      statusLine: firstLine, pinned: false,
      updatedAt: updatedAt, itemIDs: sessionIDs.map { $0.rawValue.uuidString },
      personIDs: personIDs.map { $0.rawValue.uuidString }
    )
  }

  /// The detail "复制这件事" and "导出为文本…" format for one local fallback
  /// event, from its local records (screenshot readings made on this Mac
  /// come with the records).
  public static func localEventDetail(
    _ source: MemoryEventSource, records: [MemoryItemRecord]
  ) -> MemoryEventDetail? {
    MemoryProjection(events: [source], records: records).event(id: source.eventID)
  }

  /// The same for one Spark event, with the user's decisions already applied
  /// by the local projection.
  public static func sparkEventDetail(
    _ eventID: String, projection: RemoteOrganizerProjection, records: [MemoryItemRecord]
  ) -> MemoryEventDetail? {
    MemoryProjection(remote: projection, records: records).event(id: eventID)
  }

  // MARK: - Home

  public func home() -> [MemoryHomeEntry] {
    homeEntries
  }

  private func homeEntry(_ event: MemoryEventSource) -> MemoryHomeEntry {
    let shown = shownRecords(event)
    let items = shown.map(\.record)
    let image = items.first(where: { $0.itemKind == .image && $0.thumbnailAssetPath != nil })
    let cover = image ?? items.first
    let lastLocal = items.map(\.updatedAt).max()
    let status = statusLine(of: event, shown: shown)
    var entry = MemoryHomeEntry(
      eventID: event.eventID, origin: event.origin, title: event.title,
      statusLine: status.text, people: people(of: event), itemCount: event.itemIDs.count,
      span: span(of: event, records: items),
      lastUpdate: event.updatedAt ?? lastLocal, pinned: event.pinned, cover: cover,
      statusIsFallback: status.isFallback
    )
    if image == nil { entry.coverText = coverText(shown) }
    // Only the parts this event holds: a meeting's other matters do not
    // make this card match.
    entry.searchText = shown.flatMap { record, text -> [String] in
      let key = Self.key(record.sessionID)
      return [
        text, record.localReading, remoteReadingSummaries[key], remoteReadings[key],
        record.itemKind == .file ? record.sourceIdentifier : nil,
      ].compactMap { $0 }
    }.joined(separator: "\n")
    return entry
  }

  /// The event's local records in time order, each with its text as the
  /// event shows it (the parts it holds, else all of it).
  private func shownRecords(_ event: MemoryEventSource) -> [(
    record: MemoryItemRecord, text: String?
  )] {
    orderedRecords(event).map { record in
      let key = Self.key(record.sessionID)
      let parts = event.segments.filter { $0.itemID.uppercased() == key }
        .sorted { $0.start < $1.start }
      guard let text = record.text, !parts.isEmpty else { return (record, record.text) }
      return (
        record,
        parts.map { MemoryTranscriptText.slice(text, start: $0.start, end: $0.end) }
          .joined(separator: "\n")
      )
    }
  }

  /// The organizer's line, else the newest item's first line (one line).
  private func statusLine(
    of event: MemoryEventSource, shown: [(record: MemoryItemRecord, text: String?)]
  ) -> (text: String, isFallback: Bool) {
    let written = event.statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
    if !written.isEmpty { return (written, false) }
    for (record, text) in shown.reversed() {
      if let line = Self.firstLine(text ?? record.localReading ?? "") { return (line, true) }
    }
    return ("", false)
  }

  /// The newest pasted text or document with words, else the newest item
  /// with any (a transcript, a reading): its source and first lines.
  private func coverText(_ shown: [(record: MemoryItemRecord, text: String?)]) -> MemoryCoverText? {
    let texts = Dictionary(
      shown.map { (Self.key($0.record.sessionID), $0.text) }, uniquingKeysWith: { a, _ in a })
    let records = shown.map(\.record)
    func words(_ record: MemoryItemRecord) -> [String] {
      var text =
        (texts[Self.key(record.sessionID)] ?? record.text)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let key = Self.key(record.sessionID)
      if record.itemKind == .file, let remote = remoteReadings[key] {
        // What the organizing device read of the file (its summary first).
        let summary = remoteReadingSummaries[key] ?? ""
        text = [summary, remote].filter { !$0.isEmpty }.joined(separator: "\n")
      }
      if text.isEmpty || text == UserItemLimits.noTextLayerPlaceholder {
        let remote = remoteReadings[key].map {
          MemoryScreenshotReading(organizer: $0, summary: remoteReadingSummaries[key]).body
        }
        text = remote ?? record.localReading ?? ""
      }
      return text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .prefix(Self.coverLines).map { String($0.prefix(Self.coverLineLength)) }
    }
    let newestFirst = Array(records.reversed())
    let written = newestFirst.first {
      $0.inputMode == .userItem
        && ($0.itemKind == .text || $0.itemKind == .document || $0.itemKind == .file)
        && !words($0).isEmpty
    }
    guard let record = written ?? newestFirst.first(where: { !words($0).isEmpty }) else {
      return nil
    }
    let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let heading =
      (record.itemKind == .document || record.itemKind == .file) && !title.isEmpty
      ? title : record.sourceLabel
    return MemoryCoverText(heading: heading, lines: words(record))
  }

  /// A video's keyframes are shown under their recording; as rows of their
  /// own only when the recording is not in the same list.
  public static func withoutShownKeyframes(_ items: [MemoryEventItem]) -> [MemoryEventItem] {
    let recordings = Set(
      items.compactMap { item -> String? in
        guard let record = item.record, !record.keyframes.isEmpty else { return nil }
        return key(record.sessionID)
      })
    guard !recordings.isEmpty else { return items }
    return items.filter { item in
      guard let parent = item.record?.parentSessionID else { return true }
      return !recordings.contains(key(parent))
    }
  }

  /// Lines a text cover keeps, and how long each may be before the page
  /// cuts it anyway.
  static let coverLines = 4
  static let coverLineLength = 60

  static func firstLine(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline)
      .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
  }

  // MARK: - Event

  public func event(id: String) -> MemoryEventDetail? {
    guard let event = events.first(where: { $0.eventID == id }) else { return nil }
    var seen = Set<String>()
    // An item held in parts gives one row per part.
    let items = event.itemIDs.filter { seen.insert($0.uppercased()).inserted }.flatMap {
      itemID -> [MemoryEventItem] in
      let parts = event.segments.filter {
        $0.itemID.caseInsensitiveCompare(itemID) == .orderedSame
      }.sorted { $0.start < $1.start }
      guard !parts.isEmpty else { return [item(itemID)] }
      let siblings = self.siblings(of: itemID, excluding: event.eventID)
      return parts.map { part in
        var row = item(itemID)
        row.segment = part
        row.siblings = siblings
        return row
      }
    }
    let present = Self.withoutShownKeyframes(
      items.filter { $0.record != nil }.sorted(by: Self.timeOrder))
    let missing = items.filter { $0.record == nil }
    let status = statusLine(of: event, shown: shownRecords(event))
    var detail = MemoryEventDetail(
      eventID: event.eventID, origin: event.origin, title: event.title,
      statusLine: status.text, people: people(of: event),
      span: span(of: event, records: orderedRecords(event)), items: present + missing,
      pendingQuestions: questions.filter {
        $0.kind == "same_event" && ($0.a == event.eventID || $0.b == event.eventID)
      }
    )
    detail.statusFacts = event.statusFacts
    detail.statusIsFallback = status.isFallback
    detail.hiddenPersonIDs = hidden(detail.people)
    detail.questions = memoryQuestions().filter {
      $0.kind != .samePerson && ($0.a == event.eventID || $0.b == event.eventID)
    }
    return detail
  }

  /// The other events holding parts of an item, in Home order.
  public func siblings(of itemID: String, excluding eventID: String) -> [MemorySegmentSibling] {
    (segmentHolders[itemID.uppercased()] ?? []).filter { $0.eventID != eventID }.map {
      MemorySegmentSibling(eventID: $0.eventID, title: $0.title, gist: $0.gist)
    }
  }

  /// A question's item, when it asks about one, as the event page shows it
  /// (the item may not be in this event yet).
  public func item(_ itemID: String) -> MemoryEventItem {
    let record = records[itemID.uppercased()]
    let names = speakerNames(record)
    var item = MemoryEventItem(
      itemID: itemID, record: record, remoteReading: remoteReadings[itemID.uppercased()],
      speakerNames: names)
    item.remoteReadingSummary = remoteReadingSummaries[itemID.uppercased()]
    item.remoteReadingFacts = remoteReadingFacts[itemID.uppercased()]
    item.ownerSpeakers = Set(names.filter { isOwner($0.key, name: $0.value) }.keys)
    return item
  }

  /// The first stretch of a recording on this Mac where the person speaks,
  /// earliest recording first, for "听一段声音".
  public func firstVoiceSegment(of personID: String)
    -> (itemID: String, start: UInt64, end: UInt64)?
  {
    let wanted = canonicalID(personID).uppercased()
    let recordings = records.values.filter(\.playbackAvailable).sorted {
      ($0.startedAt, Self.key($0.sessionID)) < ($1.startedAt, Self.key($1.sessionID))
    }
    for record in recordings {
      for segment in record.segments {
        guard let id = segment.personID?.rawValue.uuidString,
          canonicalID(id).uppercased() == wanted,
          let start = segment.monotonicStartNanoseconds,
          let end = segment.monotonicEndNanoseconds, end > start
        else { continue }
        return (record.sessionID.rawValue.uuidString, start, end)
      }
    }
    return nil
  }

  // MARK: - Questions

  /// Open questions, classified by shape, without the expired ones (72 h
  /// after they were asked, also while no pull happens), then the local ones.
  public func memoryQuestions() -> [MemoryQuestion] {
    let eventIDs = Set(events.map(\.eventID))
    var result: [MemoryQuestion] = []
    for question in questions {
      let asked = Self.parseDate(question.createdAt)
      if let asked, now.timeIntervalSince(asked) >= Self.questionLifetime { continue }
      let kind: MemoryQuestion.Kind
      switch question.kind {
      case "same_person":
        kind = .samePerson
      case "same_event":
        if eventIDs.contains(question.a) {
          kind = .mergeEvents
        } else if let target = events.first(where: { $0.eventID == question.b }),
          target.itemIDs.contains(where: {
            $0.caseInsensitiveCompare(question.a) == .orderedSame
          })
        {
          kind = .itemStaysInEvent
        } else {
          kind = .itemIntoEvent
        }
      default:
        continue
      }
      result.append(
        MemoryQuestion(
          questionID: question.questionID, kind: kind, prompt: question.promptZH,
          a: question.a, b: question.b, createdAt: asked, origin: .spark))
    }
    return result + localQuestions
  }

  /// The one question Home shows: event and item questions first (they
  /// change what Home shows), then people.
  public func bannerQuestion() -> MemoryQuestion? {
    let open = memoryQuestions()
    return open.first { $0.kind != .samePerson } ?? open.first
  }

  // MARK: - Related and Unfiled

  /// Other events with at least one of this event's people, most shared first,
  /// then in Home order.
  public func related(
    to eventID: String, limit: Int = 4, home precomputed: [MemoryHomeEntry]? = nil
  ) -> [MemoryHomeEntry] {
    let home = precomputed ?? home()
    guard let own = home.first(where: { $0.eventID == eventID }) else { return [] }
    let people = Set(own.people.map(\.personID))
    guard !people.isEmpty else { return [] }
    let scored = home.enumerated().compactMap { index, entry -> (Int, Int, MemoryHomeEntry)? in
      guard entry.eventID != eventID else { return nil }
      let shared = entry.people.filter { people.contains($0.personID) }.count
      return shared > 0 ? (shared, index, entry) : nil
    }
    return scored.sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }.prefix(limit).map(\.2)
  }

  /// Items in no event, newest first. Items no longer on this Mac are left out.
  public func unfiledItems() -> [MemoryUnfiledItem] {
    var seen = Set<String>()
    return unfiled.compactMap { entry -> MemoryUnfiledItem? in
      guard seen.insert(entry.itemID.uppercased()).inserted,
        records[entry.itemID.uppercased()] != nil
      else { return nil }
      return MemoryUnfiledItem(item: item(entry.itemID), reason: entry.reason)
    }.sorted {
      let left = $0.item.startedAt ?? .distantPast
      let right = $1.item.startedAt ?? .distantPast
      return left != right ? left > right : $0.item.itemID < $1.item.itemID
    }
  }

  // MARK: - People

  public func people() -> [MemoryPersonEntry] {
    people(home: homeEntries)
  }

  private func people(home: [MemoryHomeEntry]) -> [MemoryPersonEntry] {
    // Each person's events, by one pass over Home.
    var eventsByPerson: [String: [MemoryHomeEntry]] = [:]
    for entry in home {
      var listedHere = Set<String>()
      for ref in entry.people where listedHere.insert(ref.personID).inserted {
        eventsByPerson[ref.personID, default: []].append(entry)
      }
    }
    var entries: [MemoryPersonEntry] = []
    var listed = Set<String>()
    for person in persons where person.mergedInto == nil {
      guard !isOwner(person.personID, name: person.displayName),
        listed.insert(person.personID).inserted
      else { continue }
      let personEvents = eventsByPerson[person.personID] ?? []
      var entry = MemoryPersonEntry(
        personID: person.personID, name: name(of: person.personID),
        events: personEvents,
        pendingQuestions: questions.filter {
          $0.kind == "same_person" && ($0.a == person.personID || $0.b == person.personID)
        },
        colorIndex: personColors[person.personID]
      )
      entry.isNamed = entry.name != Self.unnamed
      entry.lastSeen = Self.lastSeen(personEvents)
      entries.append(entry)
    }
    // People known only from local recordings (the fallback organizer, or a
    // Spark that has not reported them yet).
    for entry in home {
      for ref in entry.people where listed.insert(ref.personID).inserted {
        let personEvents = eventsByPerson[ref.personID] ?? []
        var person = MemoryPersonEntry(
          personID: ref.personID, name: ref.name, events: personEvents, pendingQuestions: [],
          colorIndex: ref.colorIndex
        )
        person.isNamed = ref.isNamed
        person.lastSeen = Self.lastSeen(personEvents)
        entries.append(person)
      }
    }
    return entries
  }

  /// People in the Home row: most recently seen first; people seen in no
  /// event are left out.
  public func recentPeople() -> [MemoryPersonEntry] {
    recentPeople(from: people())
  }

  func recentPeople(from people: [MemoryPersonEntry]) -> [MemoryPersonEntry] {
    people.filter { !$0.events.isEmpty }.enumerated().sorted {
      let left = $0.element.lastSeen ?? .distantPast
      let right = $1.element.lastSeen ?? .distantPast
      return left != right ? left > right : $0.offset < $1.offset
    }.map(\.element)
  }

  private static func lastSeen(_ events: [MemoryHomeEntry]) -> Date? {
    events.compactMap { $0.span?.end ?? $0.lastUpdate }.max()
  }

  /// The Home people row: the people who matter, in the most matters first
  /// (then most recently seen). A person is in it when the pages draw them
  /// at all (`isShownPerson`); everyone stays in `people()` and on their
  /// own page.
  public func featuredPeople() -> [MemoryPersonEntry] {
    featuredPeople(from: people())
  }

  public func featuredPeople(from people: [MemoryPersonEntry]) -> [MemoryPersonEntry] {
    people.enumerated().filter { shownPersonIDs.contains($0.element.personID) }.sorted {
      let (a, b) = ($0.element, $1.element)
      if a.events.count != b.events.count { return a.events.count > b.events.count }
      let left = a.lastSeen ?? .distantPast
      let right = b.lastSeen ?? .distantPast
      return left != right ? left > right : $0.offset < $1.offset
    }.map(\.element)
  }

  /// Whether the pages draw this person as an avatar or a chip: someone
  /// heard in a recording on this Mac, or someone who turns up in at least
  /// two matters under something that reads as a person's name. A speaker
  /// label parsed from one pasted text ("全文：", "Archive:") is neither.
  /// A display rule only: the person, their page and their items stay.
  public func isShownPerson(_ person: MemoryPersonEntry) -> Bool {
    if heardPersonIDs.contains(person.personID.uppercased()) { return true }
    guard person.isNamed, Self.looksLikePersonName(person.name) else { return false }
    return person.events.count >= Self.mattersToShowPerson
  }

  /// How many matters a person heard in no recording must turn up in.
  public static let mattersToShowPerson = 2

  /// Whether a name reads as a person's name rather than a label: two or
  /// three Han characters (four only after a compound surname or before a
  /// title), or two or three capitalized Latin words ("Ann Gu"). A single
  /// Latin word ("Archive", "Mobile"), a lower-case word, a phrase, a
  /// number, or a name with a qualifier attached ("GaoYuan-郑组") is not.
  public static func looksLikePersonName(_ raw: String) -> Bool {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return false }
    let scalars = Array(name.unicodeScalars)
    if scalars.allSatisfy(isHan) {
      switch scalars.count {
      case 2, 3: return true
      case 4:
        return compoundSurnames.contains(String(name.prefix(2)))
          || personTitles.contains { name.hasSuffix($0) && name.count - $0.count >= 1 }
      default: return false
      }
    }
    let words = name.split(separator: " ", omittingEmptySubsequences: true)
    guard (2...3).contains(words.count) else { return false }
    return words.allSatisfy { word in
      let letters = Array(word.unicodeScalars)
      guard let first = letters.first, letters.count >= 2,
        CharacterSet.uppercaseLetters.contains(first), first.isASCII
      else { return false }
      return letters.dropFirst().allSatisfy {
        $0.isASCII && CharacterSet.lowercaseLetters.contains($0)
      }
    }
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF: return true
    default: return false
    }
  }

  /// Two-character surnames, for four-character names.
  static let compoundSurnames: Set<String> = [
    "欧阳", "司马", "诸葛", "上官", "东方", "皇甫", "尉迟", "公孙", "慕容", "令狐",
    "长孙", "宇文", "司徒", "夏侯", "轩辕", "端木", "独孤", "南宫", "西门", "澹台",
  ]

  /// Titles a surname takes ("温治疗师", "欧阳老师").
  static let personTitles: [String] = [
    "治疗师", "老师", "医生", "大夫", "教授", "\u{5E08}\u{5144}", "师姐", "师弟", "师妹", "学长", "学姐",
    "经理", "总监", "主任", "同学", "阿姨", "律师", "会计",
  ]

  private func hidden(_ people: [MemoryPersonRef]) -> Set<String> {
    Set(people.lazy.map(\.personID).filter { !shownPersonIDs.contains($0) })
  }

  /// See `personColors`. Computed once, from the projection before colours
  /// are applied (every person then has the colour of their ID).
  private func assignedColors(people: [MemoryPersonEntry]) -> [String: Int] {
    let row = featuredPeople(from: people).filter(\.isNamed)
      .prefix(MemoryPersonColor.count)
    func firstSeen(_ person: MemoryPersonEntry) -> Date {
      person.events.compactMap { $0.span?.start ?? $0.lastUpdate }.min() ?? .distantFuture
    }
    let ordered = row.sorted {
      let (left, right) = (firstSeen($0), firstSeen($1))
      return left != right ? left < right : $0.personID < $1.personID
    }
    var colors: [String: Int] = [:]
    var used = Set<Int>()
    for person in ordered {
      let own = MemoryPersonColor.index(for: person.personID)
      let color =
        (0..<MemoryPersonColor.count).lazy.map { (own + $0) % MemoryPersonColor.count }
        .first { !used.contains($0) } ?? own
      used.insert(color)
      colors[person.personID] = color
    }
    return colors
  }

  private func colored(_ ref: MemoryPersonRef) -> MemoryPersonRef {
    guard let color = personColors[ref.personID], color != ref.colorIndex else { return ref }
    var ref = ref
    ref.colorIndex = color
    return ref
  }

  /// The name shown for a person nobody named.
  public static let unnamed = "?"

  // MARK: - Helpers

  private func orderedRecords(_ event: MemoryEventSource) -> [MemoryItemRecord] {
    event.itemIDs.compactMap { records[$0.uppercased()] }
      .sorted { ($0.startedAt, Self.key($0.sessionID)) < ($1.startedAt, Self.key($1.sessionID)) }
  }

  /// Event people first (canonical, merged ones followed), then people who
  /// speak in its local recordings; each once, in first-seen order.
  private func people(of event: MemoryEventSource) -> [MemoryPersonRef] {
    var result: [MemoryPersonRef] = []
    var seen = Set<String>()
    for id in event.personIDs {
      let canonical = canonicalID(id)
      if seen.insert(canonical).inserted {
        let name = name(of: canonical)
        guard !isOwner(canonical, name: name) else { continue }
        result.append(
          colored(
            MemoryPersonRef(personID: canonical, name: name, isNamed: name != Self.unnamed)))
      }
    }
    for record in orderedRecords(event) {
      for person in record.people {
        let ref = resolved(localID: person.id.rawValue.uuidString, fallbackName: person.name)
        guard seen.insert(ref.personID).inserted, !isOwner(ref.personID, name: ref.name)
        else { continue }
        result.append(colored(ref))
      }
    }
    return result
  }

  /// Names the organizer also reads as the Mac's user.
  public static let ownerNames: Set<String> = ["我", "自己", "本人", "我自己", "me", "self"]

  /// The Mac's user, by ID or by a name only the user goes by.
  func isOwner(_ personID: String, name: String?) -> Bool {
    if ownerPersonIDs.contains(personID.uppercased()) { return true }
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return Self.ownerNames.contains(trimmed)
  }

  private func span(of event: MemoryEventSource, records: [MemoryItemRecord]) -> MemoryEventSpan? {
    let dates = records.map(\.startedAt)
    if let first = dates.min(), let last = dates.max() {
      return MemoryEventSpan(start: first, end: last)
    }
    return event.startedAt.map { MemoryEventSpan(start: $0, end: $0) }
  }

  /// Canonical names for every person a record's segments mention.
  private func speakerNames(_ record: MemoryItemRecord?) -> [String: String] {
    guard let record else { return [:] }
    var result: [String: String] = [:]
    for segment in record.segments {
      guard let personID = segment.personID else { continue }
      let key = personID.rawValue.uuidString.uppercased()
      guard result[key] == nil else { continue }
      let local =
        record.people.first { $0.id == personID }?.name ?? segment.personName
      result[key] = resolved(localID: personID.rawValue.uuidString, fallbackName: local).name
    }
    return result
  }

  /// One local person as the event shows them: the canonical person after
  /// merges, named by the Spark when it has a name, else by the merged-into
  /// local person, else by the local name.
  private func resolved(localID: String, fallbackName: String?) -> MemoryPersonRef {
    let canonical = canonicalID(localID)
    if let remote = nonEmpty(personsByID[canonical]?.displayName) {
      return MemoryPersonRef(personID: canonical, name: remote)
    }
    if canonical != localID, let merged = localName(of: canonical) {
      return MemoryPersonRef(personID: canonical, name: merged)
    }
    guard let local = nonEmpty(fallbackName) else {
      return MemoryPersonRef(personID: canonical, name: Self.unnamed, isNamed: false)
    }
    return MemoryPersonRef(personID: canonical, name: local)
  }

  /// The person a local or merged ID is now (merges followed).
  public func canonicalPersonID(_ id: String) -> String { canonicalID(id) }

  private func canonicalID(_ id: String) -> String {
    var current = id
    var visited = Set<String>()
    while visited.insert(current).inserted,
      let next = personsByID[current]?.mergedInto
    {
      current = next
    }
    return current
  }

  private func name(of personID: String) -> String {
    if let name = nonEmpty(personsByID[personID]?.displayName) {
      return name
    }
    return nonEmpty(localName(of: personID)) ?? Self.unnamed
  }

  private func localName(of personID: String) -> String? {
    localNames[personID.uppercased()]
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  private static func timeOrder(_ a: MemoryEventItem, _ b: MemoryEventItem) -> Bool {
    let left = a.record?.startedAt ?? .distantFuture
    let right = b.record?.startedAt ?? .distantFuture
    if left != right { return left < right }
    if a.itemID.uppercased() != b.itemID.uppercased() {
      return a.itemID.uppercased() < b.itemID.uppercased()
    }
    return (a.segment?.start ?? 0) < (b.segment?.start ?? 0)
  }

  static func key(_ id: SessionID) -> String { id.rawValue.uuidString.uppercased() }

  static func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: value) { return date }
    // Python writes microseconds; drop the fraction rather than fail.
    let withoutFraction = value.replacingOccurrences(
      of: #"\.\d+"#, with: "", options: .regularExpression
    )
    return plain.date(from: withoutFraction)
  }
}

/// Everything the memory pages derive from one projection, computed once
/// (off the main thread in the App: with thousands of items this is not free).
public struct MemoryReadModel: Sendable {
  public let projection: MemoryProjection
  public let home: [MemoryHomeEntry]
  public let people: [MemoryPersonEntry]
  public let recentPeople: [MemoryPersonEntry]
  /// The Home people row (`MemoryProjection.featuredPeople`).
  public let featuredPeople: [MemoryPersonEntry]
  public let unfiled: [MemoryUnfiledItem]
  public let bannerQuestion: MemoryQuestion?
  /// Open questions (Home's 「N 个问题等你确认」).
  public let questionCount: Int
  /// Home's 「最近在动的事」, for each span the page offers.
  public let looms: [MemoryLoom.Span: MemoryLoom]

  public init(_ projection: MemoryProjection, calendar: Calendar = .current) {
    self.projection = projection
    let home = projection.home()
    self.home = home
    looms = Dictionary(
      uniqueKeysWithValues: MemoryLoom.Span.allCases.map {
        ($0, MemoryLoom(projection: projection, home: home, span: $0, calendar: calendar))
      })
    let people = projection.people()
    self.people = people
    recentPeople = projection.recentPeople(from: people)
    featuredPeople = projection.featuredPeople(from: people)
    unfiled = projection.unfiledItems()
    let questions = projection.memoryQuestions()
    questionCount = questions.count
    bannerQuestion = questions.first { $0.kind != .samePerson } ?? questions.first
  }
}
