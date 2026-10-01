import BestASRDomain
import BestASRMemory
import Foundation
import MindloomSpaces

/// One space as the memory pages read it: the space organizer's matters with
/// every placeholder put back (members see the numbers), and a record per
/// shared item built from its member-visible fields. Items hidden by this
/// member and items that left the space are not shown.
public struct SpaceView: Sendable {
  public let spaceID: String
  public let projection: RemoteOrganizerProjection
  public let records: [MemoryItemRecord]
  /// Upper-case item id → the contributor's name.
  public let contributors: [String: String]
  /// Upper-case ids of the items this member shared.
  public let mine: Set<String>
  /// Organizing still running on the Spark (or not leased yet).
  public let organizing: Bool

  /// "林知远 2 条 + 韩策 3 条" for one matter.
  public func contributionLine(eventID: String) -> String? {
    guard let event = projection.events.first(where: { $0.eventID == eventID }) else { return nil }
    var counts: [String: Int] = [:]
    var order: [String] = []
    for id in event.itemIDs {
      guard let name = contributors[id.uppercased()] else { continue }
      if counts[name] == nil { order.append(name) }
      counts[name, default: 0] += 1
    }
    guard !order.isEmpty else { return nil }
    return order.map { "\($0) \(counts[$0]!) 条" }.joined(separator: " + ")
  }
}

public enum SpaceProjectionBuilder {
  public static func build(
    _ state: SpaceLocalState, maskKey: Data?, timeZone: TimeZone = .current
  ) -> SpaceView {
    let visible = state.activeItems.filter { !state.hidden.contains($0.itemID) }
    var contributors: [String: String] = [:]
    var mine = Set<String>()
    var records: [MemoryItemRecord] = []
    for item in visible {
      let key = item.itemID.uppercased()
      let name = state.name(of: item.contributor)
      contributors[key] = name
      if item.contributor == state.memberID { mine.insert(key) }
      if let record = record(item, contributor: name) { records.append(record) }
    }
    let visibleIDs = Set(visible.map { $0.itemID.uppercased() })
    // Placeholder → original, from every text members can read, with the
    // space's mask key (any member can put the numbers back).
    var originals: [String: String] = [:]
    var offsets: [String: [PrivacyMaskOffset]] = [:]
    if let maskKey, let masker = try? PrivacyMasker(maskKey: maskKey) {
      for item in visible {
        guard let fields = item.fields else { continue }
        for text in fields.texts {
          for span in masker.maskWithSpans(text).spans {
            originals[span.placeholder] = span.original
          }
        }
        let organizerText = SpaceOrganizerPayloads.organizerText(fields)
        let spans = masker.maskWithSpans(organizerText).spans
        if !spans.isEmpty {
          offsets[item.itemID.uppercased()] = PrivacyMaskOffset.offsets(
            original: organizerText, spans: spans)
        }
      }
    }
    let unmask: (String) -> String = { text in
      PrivacyUnmask.unmask(text) { originals[$0] }
    }
    var events: [RemoteOrganizerEvent] = []
    var persons: [RemoteOrganizerPerson] = []
    var questions: [RemoteOrganizerQuestion] = []
    var unfiled: [RemoteOrganizerUnfiledItem] = []
    if let raw = state.organizer?.state,
      let pulled = try? JSONDecoder().decode(RemoteOrganizerState.self, from: raw)
    {
      for event in pulled.events where !event.deleted {
        let kept = event.itemIDs.filter { visibleIDs.contains($0.uppercased()) }
        guard !kept.isEmpty else { continue }
        let shown = event.unmasked(unmask, offsets: { offsets[$0.uppercased()] })
        events.append(shown.keeping(itemIDs: kept))
      }
      persons = pulled.persons.map { $0.unmasked(unmask) }
      questions = pulled.questions.map { $0.unmasked(unmask) }
      unfiled = (pulled.unfiled ?? []).filter { visibleIDs.contains($0.itemID.uppercased()) }
    }
    let filed = Set(events.flatMap(\.itemIDs).map { $0.uppercased() })
    if events.isEmpty {
      // Not organized yet: each shared matter as its sharer titled it.
      for package in state.packages.values.filter(\.active).sorted(by: {
        $0.packageID < $1.packageID
      }) {
        let ids = package.itemIDs.filter { visibleIDs.contains($0.uppercased()) }
        guard !ids.isEmpty else { continue }
        events.append(
          RemoteOrganizerEvent(
            eventID: "package-\(package.packageID)", title: package.title ?? "共享的事",
            titleUserEdited: false, statusLine: "\(ids.count) 条素材 · 正在整理…",
            statusFacts: [], importance: 0.5, startedAt: nil, updatedAt: nil,
            itemIDs: ids.map { $0.uppercased() }, personIDs: [], pinned: false, deleted: false,
            provenance: [:]))
      }
    }
    let filedNow = filed.union(events.flatMap(\.itemIDs).map { $0.uppercased() })
    for id in visibleIDs.sorted()
    where !filedNow.contains(id)
      && !unfiled.contains(where: {
        $0.itemID.uppercased() == id
      })
    {
      unfiled.append(RemoteOrganizerUnfiledItem(itemID: id, reason: "none"))
    }
    let organizing =
      state.organizer == nil || (state.organizer?.busyQueue ?? 0) > 0
      || (state.organizer?.busyBriefs ?? 0) > 0
    return SpaceView(
      spaceID: state.spaceID,
      projection: RemoteOrganizerProjection(
        cursor: 0, events: events, questions: questions, persons: persons, unfiled: unfiled),
      records: records, contributors: contributors, mine: mine, organizing: organizing)
  }

  /// A memory record from a shared item's fields; the source names the contributor.
  static func record(_ item: SpaceSharedItem, contributor: String) -> MemoryItemRecord? {
    guard let uuid = UUID(uuidString: item.itemID), let fields = item.fields else { return nil }
    let started = SpaceTime.date(fields.startedAt) ?? item.firstSharedAt
    let mode: SessionInputMode
    var userKind: UserItemKind?
    switch item.kind {
    case "dictation": mode = .dictation
    case "meeting_offline": mode = .roomMicrophone
    case "meeting_online": mode = .systemAudio
    case "imported_media": mode = .importedMedia
    case "audio_segment":
      switch fields.parentKind {
      case "meeting_online": mode = .systemAudio
      case "imported_media": mode = .importedMedia
      default: mode = .roomMicrophone
      }
    default:
      mode = .userItem
      userKind =
        switch item.kind {
        case "image": .image
        case "document": .document
        case "file": .file
        default: .text
        }
    }
    let source = [fields.sourceName, contributor].compactMap { $0 }.filter { !$0.isEmpty }
      .joined(separator: " · ")
    let segments = (fields.segments ?? []).map {
      MemoryItemRecord.Segment(
        startMilliseconds: $0.startMS, endMilliseconds: $0.endMS, personID: nil,
        personName: $0.speaker, text: $0.text)
    }
    var record = MemoryItemRecord(
      sessionID: SessionID(uuid), inputMode: mode, itemKind: userKind,
      title: fields.title ?? "共享的素材", startedAt: started, updatedAt: item.updatedAt,
      sourceBundleID: fields.sourceBundleID, sourceDisplayName: source.isEmpty ? nil : source,
      sourceIdentifier: nil, text: SpaceOrganizerPayloads.organizerText(fields),
      segments: segments, localReading: fields.reading)
    record.mediaType = fields.mediaType
    record.fileSizeBytes = fields.sizeBytes
    return record
  }
}

extension RemoteOrganizerEvent {
  /// The same event holding only `itemIDs` (and their parts).
  func keeping(itemIDs: [String]) -> RemoteOrganizerEvent {
    let kept = Set(itemIDs.map { $0.uppercased() })
    var copy = self
    copy.itemIDs = itemIDs
    copy.segments = segments.filter { kept.contains($0.itemID.uppercased()) }
    return copy
  }
}

/// "同一件事" between this member's personal matters and the spaces'
/// matters (SPACES-CONTRACT §4): the badge 「共享版更完整 · +N 条，来自 …」 in
/// 我的, and the overlay of 全部 where shared threads are two-tone.
public enum SpaceOverlay {
  public struct Badge: Equatable, Sendable {
    public let spaceID: String
    public let spaceName: String
    public let spaceEventID: String
    /// Items of the shared matter that are not in the personal one.
    public let extraItemIDs: [String]
    public let contributors: [String]

    public var text: String {
      "共享版更完整 · +\(extraItemIDs.count) 条，来自 " + contributors.joined(separator: "、")
    }
  }

  /// Personal matter id → its badge (the space matter with the most extra items).
  public static func badges(
    personal: [(eventID: String, itemIDs: [String])],
    spaces: [(state: SpaceLocalState, view: SpaceView)]
  ) -> [String: Badge] {
    var out: [String: Badge] = [:]
    let personalItems = Dictionary(
      personal.map { ($0.eventID, Set($0.itemIDs.map { $0.uppercased() })) }
    ) { first, _ in first }
    for (state, view) in spaces {
      for link in state.organizer?.sameAs ?? [] where link.memberID == state.memberID {
        guard let mine = personalItems[link.matterID],
          let event = view.projection.events.first(where: { $0.eventID == link.eventID })
        else { continue }
        let extra = event.itemIDs.filter { id in
          !mine.contains(id.uppercased()) && !view.mine.contains(id.uppercased())
        }
        guard !extra.isEmpty else { continue }
        var names: [String] = []
        for id in extra {
          if let name = view.contributors[id.uppercased()], !names.contains(name) {
            names.append(name)
          }
        }
        let badge = Badge(
          spaceID: state.spaceID, spaceName: state.name, spaceEventID: link.eventID,
          extraItemIDs: extra, contributors: names)
        if let current = out[link.matterID], current.extraItemIDs.count >= extra.count { continue }
        out[link.matterID] = badge
      }
    }
    return out
  }

  /// The overlay of 全部: my matters carrying the shared versions' other
  /// items, then the spaces' matters none of mine is linked to (ids
  /// `space:<space>:<event>`, read-only there). `othersItemIDs` (upper-case)
  /// are drawn in the second tone, so those threads are two-tone.
  public struct Merged: Sendable {
    public let events: [MemoryEventSource]
    public let records: [MemoryItemRecord]
    public let persons: [RemoteOrganizerPerson]
    public let othersItemIDs: Set<String>
    /// Merged event id → the space it came from.
    public let spaceEvents: [String: String]
  }

  public static func merged(
    personal: [MemoryEventSource], personalRecords: [MemoryItemRecord],
    personalPersons: [RemoteOrganizerPerson],
    spaces: [(state: SpaceLocalState, view: SpaceView)]
  ) -> Merged {
    let badges = badges(personal: personal.map { ($0.eventID, $0.itemIDs) }, spaces: spaces)
    var records = personalRecords
    var seen = Set(personalRecords.map { $0.sessionID.rawValue.uuidString.uppercased() })
    var others = Set<String>()
    var spaceEvents: [String: String] = [:]
    let views = Dictionary(spaces.map { ($0.state.spaceID, $0.view) }) { first, _ in first }
    func addRecords(_ ids: [String], from view: SpaceView) {
      for id in ids where !seen.contains(id.uppercased()) {
        if let record = view.records.first(where: {
          $0.sessionID.rawValue.uuidString.uppercased() == id.uppercased()
        }) {
          records.append(record)
          seen.insert(id.uppercased())
        }
      }
    }
    var events: [MemoryEventSource] = personal.map { source in
      guard let badge = badges[source.eventID], let view = views[badge.spaceID] else {
        return source
      }
      addRecords(badge.extraItemIDs, from: view)
      others.formUnion(badge.extraItemIDs.map { $0.uppercased() })
      return MemoryEventSource(
        eventID: source.eventID, origin: source.origin, title: source.title,
        statusLine: source.statusLine, pinned: source.pinned, startedAt: source.startedAt,
        updatedAt: source.updatedAt, itemIDs: source.itemIDs + badge.extraItemIDs,
        personIDs: source.personIDs, statusFacts: source.statusFacts, handle: source.handle,
        segments: source.segments, map: source.map, facets: source.facets,
        listedFacts: source.listedFacts)
    }
    let mineLinked = Set(
      spaces.flatMap { space in
        (space.state.organizer?.sameAs ?? []).filter { $0.memberID == space.state.memberID }
          .map { "\(space.state.spaceID)|\($0.eventID)" }
      })
    var persons = personalPersons
    for (state, view) in spaces {
      for event in view.projection.events
      where !mineLinked.contains("\(state.spaceID)|\(event.eventID)") {
        let id = "space:\(state.spaceID):\(event.eventID)"
        spaceEvents[id] = state.spaceID
        addRecords(event.itemIDs, from: view)
        others.formUnion(event.itemIDs.map { $0.uppercased() }.filter { !view.mine.contains($0) })
        let source = MemoryProjection.source(event)
        events.append(
          MemoryEventSource(
            eventID: id, origin: .spark, title: source.title, statusLine: source.statusLine,
            pinned: false, startedAt: source.startedAt, updatedAt: source.updatedAt,
            itemIDs: source.itemIDs, personIDs: source.personIDs,
            statusFacts: source.statusFacts, handle: nil, segments: source.segments,
            // The space's own map (its strands cite the space's items); the
            // facets name the space's ropes, which 全部 does not show.
            map: source.map, listedFacts: source.listedFacts))
      }
      for person in view.projection.persons
      where !persons.contains(where: { $0.personID == person.personID }) {
        persons.append(person)
      }
    }
    return Merged(
      events: events, records: records, persons: persons, othersItemIDs: others,
      spaceEvents: spaceEvents)
  }
}

/// "整根绳" (SPACES-CONTRACT §2, rope rule: everything in rope X goes to
/// space Y), on the matter map's ropes (MAP-CONTRACT §2).
public enum SpaceRopeRule {
  /// The matters on a rope and on every rope nested inside it, in rope order,
  /// each once; loops in the parent links are ignored.
  public static func matters(of ropeID: String, in ropes: [RemoteOrganizerRope]) -> [String] {
    var out: [String] = []
    var seenMatters = Set<String>()
    var seenRopes = Set<String>()
    var queue = [ropeID]
    while !queue.isEmpty {
      let id = queue.removeFirst()
      guard seenRopes.insert(id).inserted, let rope = ropes.first(where: { $0.id == id }) else {
        continue
      }
      for matter in rope.children where seenMatters.insert(matter).inserted {
        out.append(matter)
      }
      queue += ropes.filter { $0.parent == id }.map(\.id)
    }
    return out
  }

  /// A rule set to 自动 sends new items by itself only while the rope is one
  /// the owner confirmed: the grouping pass's proposals (which matters a
  /// proposed rope holds) never decide on their own what leaves for a space;
  /// until then the rule only asks.
  public static func sendsByItself(_ rope: RemoteOrganizerRope) -> Bool { !rope.proposed }
}
