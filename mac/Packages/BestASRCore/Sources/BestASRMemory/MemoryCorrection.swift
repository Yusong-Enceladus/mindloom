import BestASRDomain
import Foundation

/// One correction the user makes on the pages (MAC-SPEC §5.7, §7.4.1). Those
/// that leave the Mac (`isHeld`) are held for the undo window before they are
/// sent; the rest are local and applied at once. Each has an inverse, sent
/// when the user undoes it after it was committed (⌘Z), except 删除: the DGX
/// Spark has no way back for a deleted matter, so it is undoable only while
/// held.
public enum MemoryCorrection: Equatable, Hashable, Sendable, Codable {
  /// 移到别的事… (a step moves with the item it rests on).
  case moveItem(itemID: String, segID: String?, from: String, to: String)
  /// 不属于这件事 / 不属于任何事: the item leaves the matter and waits under
  /// Home 「刚收进来」.
  case takeOut(itemID: String, segID: String?, from: String)
  /// + 新建一件事: a new matter titled `title` takes the item.
  /// `provisionalID` names it until the organizer gives it an ID.
  case newMatter(itemID: String, segID: String?, from: String, title: String, provisionalID: String)
  /// 标为完成 (`.done`) or 已经定了 (`.settled`); nil takes it back.
  case markStep(eventID: String, stepID: String, state: UserStepOverride.State?, previous: UserStepOverride.State?)
  /// 重命名.
  case rename(eventID: String, from: String, to: String)
  /// 删除… (the matter's progress goes; its items stay).
  case delete(eventID: String, title: String)
  /// 移到分组 / 添加到 / 不放在分组里 (route IDs; nil = in no group).
  case group(eventID: String, from: String?, to: String?)
  /// 置顶 / 取消置顶 (not undoable, but routed the same way).
  case pin(eventID: String, pinned: Bool)
  /// A person's name (the title on their page): `from` is "" while nobody
  /// had named them (v12, 理3-1).
  case namePerson(personID: String, from: String, to: String)
  /// 合并到…: `personID` is the same person as `into` (who keeps their
  /// name; the other name becomes one of theirs).
  case mergePerson(personID: String, into: String)
  /// 不是他: the sentences of a recording that start at `starts`
  /// (monotonic nanoseconds) are not `personID`'s; they go to a new unnamed
  /// person, `newPersonID` (an upper-case UUID chosen now, so the page shows
  /// the same 「没起名 N」 before and after the change is written).
  case notPerson(itemID: String, personID: String, starts: [UInt64], newPersonID: String)

  /// Sent off the Mac (an organizer decision, or the local organizer's
  /// write): held for the undo window first.
  public var isHeld: Bool {
    switch self {
    case .moveItem, .takeOut, .newMatter, .rename, .delete, .namePerson, .mergePerson, .notPerson:
      true
    case .markStep, .group, .pin: false
    }
  }

  /// In the undo slot (§5.7: 置顶 is not undoable).
  public var isUndoable: Bool {
    if case .pin = self { return false }
    return true
  }

  /// 编辑 › 「撤销{label}」.
  public var undoLabel: String {
    switch self {
    case .moveItem, .takeOut, .newMatter: "移动"
    case .markStep: "标记为完成"
    case .rename: "重新命名"
    case .delete: "删除"
    case .group: "移到分组"
    case .pin(_, let pinned): pinned ? "置顶" : "取消置顶"
    case .namePerson: "命名"
    case .mergePerson: "合并"
    case .notPerson: "拆分"
    }
  }

  /// What undoing it after it was committed sends (nil: no way back once
  /// sent).
  public var inverse: MemoryCorrection? {
    switch self {
    case .moveItem(let item, let seg, let from, let to):
      return .moveItem(itemID: item, segID: seg, from: to, to: from)
    case .takeOut(let item, let seg, let from):
      // Back from 刚收进来 into the matter it left.
      return .moveItem(itemID: item, segID: seg, from: "", to: from)
    case .newMatter(let item, let seg, let from, _, let provisional):
      // The organizer drops the emptied matter.
      return .moveItem(itemID: item, segID: seg, from: provisional, to: from)
    case .markStep(let event, let step, let state, let previous):
      return .markStep(eventID: event, stepID: step, state: previous, previous: state)
    case .rename(let event, let from, let to):
      return .rename(eventID: event, from: to, to: from)
    case .delete:
      return nil
    case .group(let event, let from, let to):
      return .group(eventID: event, from: to, to: from)
    case .pin(let event, let pinned):
      return .pin(eventID: event, pinned: !pinned)
    case .namePerson(let person, let from, let to):
      // A name can be changed back, not taken away: undoing the first name
      // works only inside the undo window.
      return from.isEmpty ? nil : .namePerson(personID: person, from: to, to: from)
    case .mergePerson, .notPerson:
      // Undoable while held (8 s); the organizer has no way back once sent.
      return nil
    }
  }

  /// The matter it is about (the one the page shows).
  public var eventID: String {
    switch self {
    case .moveItem(_, _, let from, let to): from.isEmpty ? to : from
    case .takeOut(_, _, let from), .newMatter(_, _, let from, _, _): from
    case .markStep(let event, _, _, _), .rename(let event, _, _), .delete(let event, _),
      .group(let event, _, _), .pin(let event, _):
      event
    case .namePerson, .mergePerson, .notPerson: ""
    }
  }

  /// The person it is about (person corrections only).
  public var personID: String? {
    switch self {
    case .namePerson(let person, _, _), .mergePerson(let person, _),
      .notPerson(_, let person, _, _):
      person
    default: nil
    }
  }
}

extension MemoryProjection {
  /// The projection with corrections that are held (not sent yet) applied,
  /// so the pages show them at once: items move, leave or found a new
  /// matter, titles change, deleted matters go. Step marks, groups and pins
  /// are user state (`UserOrganizingSnapshot.applying`).
  public func applying(_ corrections: [MemoryCorrection]) -> MemoryProjection {
    guard !corrections.isEmpty else { return self }
    var events = self.events
    var unfiled = self.unfiled
    var people = PeopleOverlay(self)
    func index(_ id: String) -> Int? { events.firstIndex { $0.eventID == id } }
    func rebuilt(
      _ event: MemoryEventSource, eventID: String? = nil, title: String? = nil,
      statusLine: String? = nil, itemIDs: [String]? = nil, segments: [MemoryItemSegment]? = nil
    ) -> MemoryEventSource {
      MemoryEventSource(
        eventID: eventID ?? event.eventID, origin: event.origin, title: title ?? event.title,
        statusLine: statusLine ?? event.statusLine, pinned: event.pinned, startedAt: event.startedAt,
        updatedAt: event.updatedAt, itemIDs: itemIDs ?? event.itemIDs, personIDs: event.personIDs,
        statusFacts: event.statusFacts, handle: event.handle, segments: segments ?? event.segments,
        map: event.map, facets: event.facets, listedFacts: event.listedFacts)
    }
    /// Takes the item (or one part of it) out of `from`; returns what left.
    func take(_ item: String, seg: String?, from: String) -> (ids: [String], parts: [MemoryItemSegment])? {
      guard let i = index(from) else { return nil }
      let event = events[i]
      let key = item.uppercased()
      let parts = event.segments.filter {
        $0.itemID.uppercased() == key && (seg == nil || $0.segID == seg)
      }
      let keepsOtherParts = event.segments.contains {
        $0.itemID.uppercased() == key && seg != nil && $0.segID != seg
      }
      let ids = keepsOtherParts ? [] : event.itemIDs.filter { $0.uppercased() == key }
      events[i] = rebuilt(
        event, itemIDs: keepsOtherParts ? event.itemIDs : event.itemIDs.filter { $0.uppercased() != key },
        segments: event.segments.filter { !parts.contains($0) })
      return (ids.isEmpty ? [item] : ids, parts)
    }
    func put(_ moved: (ids: [String], parts: [MemoryItemSegment]), into to: String) {
      guard let i = index(to) else { return }
      let event = events[i]
      let have = Set(event.itemIDs.map { $0.uppercased() })
      let ids = event.itemIDs + moved.ids.filter { !have.contains($0.uppercased()) }
      events[i] = rebuilt(event, itemIDs: ids, segments: event.segments + moved.parts)
    }
    for correction in corrections {
      switch correction {
      case .moveItem(let item, let seg, let from, let to):
        if from.isEmpty {
          unfiled.removeAll { $0.itemID.caseInsensitiveCompare(item) == .orderedSame }
          put(([item], []), into: to)
        } else if let moved = take(item, seg: seg, from: from) {
          put(moved, into: to)
        }
      case .takeOut(let item, let seg, let from):
        if take(item, seg: seg, from: from) != nil {
          unfiled.append(RemoteOrganizerUnfiledItem(itemID: item, reason: "user", since: nil))
        }
      case .newMatter(let item, let seg, let from, let title, let provisional):
        guard let source = index(from).map({ events[$0] }), let moved = take(item, seg: seg, from: from)
        else { continue }
        let created = MemoryEventSource(
          eventID: provisional, origin: source.origin, title: title,
          statusLine: "从“\(source.title)”拆分出来", pinned: false, startedAt: nil,
          updatedAt: projectionNow, itemIDs: moved.ids, personIDs: [], segments: moved.parts)
        events.insert(created, at: 0)
      case .rename(let event, _, let to):
        if let i = index(event) { events[i] = rebuilt(events[i], title: to) }
      case .delete(let event, _):
        events.removeAll { $0.eventID == event }
      case .markStep, .group, .pin:
        continue
      case .namePerson(let person, _, let to):
        people.name(person, to)
      case .mergePerson(let person, let into):
        people.merge(person, into: into)
      case .notPerson(let item, let person, let starts, let newID):
        people.split(item: item, person: person, starts: starts, newID: newID, at: now)
      }
    }
    return MemoryProjection(
      events: events, records: people.records, persons: people.persons, questions: questions,
      remoteReadings: remoteReadings, remoteReadingSummaries: remoteReadingSummaries,
      remoteReadingFacts: remoteReadingFacts, unfiled: unfiled, localQuestions: localQuestions,
      now: now, ownerPersonIDs: ownerPersonIDs, ropes: ropes, relations: relations,
      localPeople: people.local, localMerges: people.merges)
  }

  private var projectionNow: Date { now }
}

extension UserOrganizingSnapshot {
  /// The snapshot with local corrections applied (step marks, groups, pins),
  /// so the pages show them before the store has written them.
  public func applying(_ corrections: [MemoryCorrection], at date: Date) -> UserOrganizingSnapshot {
    var result = self
    for correction in corrections {
      switch correction {
      case .markStep(let event, let step, let state, _):
        result.stepOverrides.removeAll { $0.eventID == event && $0.stepID == step }
        if let state {
          result.stepOverrides.append(
            UserStepOverride(eventID: event, stepID: step, state: state, createdAt: date))
        }
      case .group(let event, _, let to):
        result.groups = result.groups.map { group in
          var ids = group.eventIDs.filter { $0 != event }
          if group.id.uuidString.lowercased() == to?.lowercased() { ids.append(event) }
          return UserGroup(
            id: group.id, name: group.name, sortOrder: group.sortOrder, createdAt: group.createdAt,
            updatedAt: group.updatedAt, revision: group.revision, eventIDs: ids)
        }
      case .pin(let event, let pinned):
        result.pins.removeAll { $0.eventID == event }
        if pinned { result.pins.append(UserPin(eventID: event, pinnedAt: date)) }
      case .moveItem, .takeOut, .newMatter, .rename, .delete, .namePerson, .mergePerson,
        .notPerson:
        continue
      }
    }
    return result
  }
}

/// Person corrections laid over the inputs (held ones show at once): a
/// name on the organizer's person, this Mac's person and the records'
/// speakers; a merge as the organizer's `merged_into` or, for a person only
/// this Mac knows, a local merge; 不是他 moves the chosen sentences to the
/// new unnamed person.
private struct PeopleOverlay {
  var persons: [RemoteOrganizerPerson]
  var local: [MemoryLocalPerson]
  var merges: [String: String]
  var byKey: [String: MemoryItemRecord]
  var order: [String]

  init(_ projection: MemoryProjection) {
    persons = projection.persons
    local = projection.localPeople
    merges = projection.localMerges
    byKey = projection.records
    order = projection.records.keys.sorted()
  }

  var records: [MemoryItemRecord] { order.compactMap { byKey[$0] } }

  private static func same(_ a: String, _ b: String) -> Bool {
    a.caseInsensitiveCompare(b) == .orderedSame
  }

  mutating func name(_ person: String, _ name: String) {
    for index in persons.indices where Self.same(persons[index].personID, person) {
      persons[index].displayName = name
    }
    for index in local.indices where Self.same(local[index].personID, person) {
      local[index] = local[index].renamed(name)
    }
    for key in order {
      guard let record = byKey[key] else { continue }
      let touches =
        record.people.contains { Self.same($0.id.rawValue.uuidString, person) }
        || record.segments.contains {
          $0.personID.map { Self.same($0.rawValue.uuidString, person) } ?? false
        }
      guard touches else { continue }
      byKey[key] = record.replacing(
        people: record.people.map {
          Self.same($0.id.rawValue.uuidString, person) ? .init(id: $0.id, name: name) : $0
        },
        segments: record.segments.map { segment in
          guard let id = segment.personID, Self.same(id.rawValue.uuidString, person) else {
            return segment
          }
          return segment.with(personID: id, name: name)
        })
    }
  }

  /// As the organizer will apply it (`MemoryPersonMerge`): when a voice
  /// stays over a person read from texts, it takes that person's name.
  mutating func merge(_ person: String, into: String) {
    guard !Self.same(person, into) else { return }
    let outcome = MemoryPersonMerge.outcome(person: person, into: into, persons: persons)
    if Self.same(outcome.stays, person),
      let name = persons.first(where: { Self.same($0.personID, into) })?.displayName,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      self.name(person, name)
    }
    if let index = persons.firstIndex(where: { Self.same($0.personID, outcome.joins) }) {
      persons[index].mergedInto = outcome.stays
    } else {
      merges[outcome.joins.uppercased()] = outcome.stays
    }
  }

  mutating func split(item: String, person: String, starts: [UInt64], newID: String, at now: Date) {
    let key = item.uppercased()
    guard let record = byKey[key], let uuid = UUID(uuidString: newID) else { return }
    let wanted = Set(starts)
    let newPerson = PersonID(uuid)
    var moved = false
    let segments = record.segments.map { segment -> MemoryItemRecord.Segment in
      guard let id = segment.personID, Self.same(id.rawValue.uuidString, person),
        let start = segment.monotonicStartNanoseconds, wanted.contains(start)
      else { return segment }
      moved = true
      return segment.with(personID: newPerson, name: nil)
    }
    guard moved else { return }
    let stillSpeaks = segments.contains {
      $0.personID.map { Self.same($0.rawValue.uuidString, person) } ?? false
    }
    var people = record.people.filter {
      stillSpeaks || !Self.same($0.id.rawValue.uuidString, person)
    }
    if !people.contains(where: { $0.id == newPerson }) {
      people.append(.init(id: newPerson, name: ""))
    }
    byKey[key] = record.replacing(people: people, segments: segments)
    if !local.contains(where: { Self.same($0.personID, newID) }) {
      local.append(
        MemoryLocalPerson(
          personID: newID, name: nil, createdAt: now, recordCount: 1,
          lastHeardAt: record.startedAt, hasVoice: true))
    }
  }
}

extension MemoryItemRecord.Segment {
  /// The same sentence said by someone else.
  fileprivate func with(personID: PersonID?, name: String?) -> MemoryItemRecord.Segment {
    MemoryItemRecord.Segment(
      startMilliseconds: startMilliseconds, endMilliseconds: endMilliseconds, personID: personID,
      personName: name, text: text, monotonicStartNanoseconds: monotonicStartNanoseconds,
      monotonicEndNanoseconds: monotonicEndNanoseconds)
  }
}

extension MemoryItemRecord {
  /// The same record with other speakers (a held person correction).
  fileprivate func replacing(people: [Person], segments: [Segment]) -> MemoryItemRecord {
    var copy = MemoryItemRecord(
      sessionID: sessionID, inputMode: inputMode, itemKind: itemKind, title: title,
      startedAt: startedAt, updatedAt: updatedAt, sourceBundleID: sourceBundleID,
      sourceDisplayName: sourceDisplayName, sourceIdentifier: sourceIdentifier, text: text,
      segments: segments, people: people, durationNanoseconds: durationNanoseconds,
      playbackAvailable: playbackAvailable, thumbnailAssetPath: thumbnailAssetPath,
      originalAssetPath: originalAssetPath, pageCount: pageCount, localReading: localReading,
      titleIsUserEdited: titleIsUserEdited)
    copy.uniformType = uniformType
    copy.mediaType = mediaType
    copy.fileSizeBytes = fileSizeBytes
    copy.parentSessionID = parentSessionID
    copy.frameMilliseconds = frameMilliseconds
    copy.keptOnMac = keptOnMac
    copy.keyframes = keyframes
    copy.deliveredText = deliveredText
    return copy
  }
}
