import BestASRDomain
import Foundation

// v11 (Mindloom) derivations, MAC-SPEC §13: what Home, the matter page, 按截止
// and 按人 show, derived once per projection from data the Mac already has
// (organizer events, maps, status facts, items, persons) plus the user's own
// step overrides. Pure and deterministic: the same projection, user state,
// "now", calendar and owner names give the same digest. No model, no
// inference, nothing inferred between matters (only the same capture filed
// into several matters: `MatterEvidence.alsoIn`).

/// A step's mark on a lane (`glyph_state`).
public enum MatterStepGlyph: String, Equatable, Hashable, Sendable {
  /// Happened (●): done, or a decision, or a past deadline.
  case done
  /// A past promise or step that may not have happened: folded, never a mark
  /// of its own.
  case minor
  /// An open question: 待定, never on the axis.
  case open
  /// Coming (○).
  case next
}

/// Another matter, by ID and title.
public struct MatterRef: Equatable, Hashable, Identifiable, Sendable {
  public let eventID: String
  public let title: String
  public var id: String { eventID }

  public init(eventID: String, title: String) {
    self.eventID = eventID
    self.title = title
  }
}

/// Where a step was said (§13.3.1).
public struct MatterEvidence: Equatable, Sendable {
  /// Upper-case item ID.
  public let itemID: String
  /// The 原文 row that shows it (`MemoryEventItem.id`: the item, or
  /// `item#seg` for one part of it).
  public let rowID: String
  public let time: Date
  public let source: MemorySourceWords
  /// The line holding the quote and the one after it.
  public let lines: [MemoryQuoteLine]
  /// The span to highlight (verbatim; may be empty).
  public let quote: String
  /// Other live matters the organizer filed the same item into (at most
  /// two), for 「同一场会还讲到 A · B」. Never inferred, never a count.
  public let alsoIn: [MatterRef]
}

/// A dated thing on a matter's time view: a map knot, or a step written in
/// the status line (`st1`…).
public struct MatterStep: Equatable, Identifiable, Sendable {
  public let id: String
  /// The part (strand) ID it is on; nil when the organizer gave none.
  public let partID: String?
  /// progress · decision · question · commitment · deadline · step (status line)
  public let kind: String
  /// done · doing · planned · open (after the user's override)
  public let state: String
  public let glyph: MatterStepGlyph
  /// Its day (midnight). Steps without any date are not kept.
  public let date: Date
  /// The date came from its evidence, not the organizer: never a deadline.
  public let inferred: Bool
  /// Display-guarded words (not autospaced).
  public let text: String
  /// People other than the owner, by name (the owner is never listed).
  public let who: [String]
  /// A real deadline or the user's own promise (or the status step), not
  /// done, due today or tomorrow.
  public let due: Bool
  /// A status-line deadline that passed in the last seven days, not done.
  public let over: Bool
  public let fromStatus: Bool
  public let evidence: MatterEvidence?
  /// 标为完成 / 已经定了 by the user (it wins over the organizer).
  public let override: UserStepOverride.State?

  public var isDone: Bool { state == "done" || glyph == .done }
  public var isOpenQuestion: Bool { glyph == .open }
  /// A decision, or the user's own promise.
  public var isDecisionOrPromise: Bool { kind == "decision" || kind == "commitment" }
}

/// A part of a matter (an organizer strand): its own name is the lane label.
public struct MatterPart: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let summary: String
  public let closed: Bool
  /// Days with items on this part (midnight), ascending.
  public let days: [Date]
  public let itemIDs: [String]
}

/// A status fact as the small page shows it.
public struct MatterFact: Equatable, Sendable {
  public let text: String
  public let state: MemoryStatusFact.State
  public let date: Date?
}

/// One matter, digested.
public struct MatterDigest: Equatable, Identifiable, Sendable {
  public let eventID: String
  public let handle: String?
  public let origin: MemoryEventSource.Origin
  /// The organizer's Home rank (0 first); the importance tie-break.
  public let rank: Int
  public let title: String
  public let status: String
  /// One plain sentence when the organizer says the matter is at risk.
  public let risk: String?
  /// First and last capture day (midnight); nil with no item on this Mac.
  public let firstDay: Date?
  public let lastDay: Date?
  /// Days with captures, ascending.
  public let days: [Date]
  /// Upper-case item IDs on this Mac.
  public let itemIDs: [String]
  /// People of the matter, the owner left out, as the event shows them.
  public let people: [MemoryPersonRef]
  /// Parts, open ones first, each by its first day.
  public let parts: [MatterPart]
  /// Dated steps, by date then ID.
  public let steps: [MatterStep]
  public let facts: [MatterFact]

  public var id: String { eventID }

  /// 待定: open questions, by when they were asked.
  public var openQuestions: [MatterStep] { steps.filter(\.isOpenQuestion) }

  /// The overdue step (the earliest), if any.
  public var overdue: MatterStep? {
    steps.filter { $0.over && !$0.isDone }.min { $0.date < $1.date }
  }

  /// The one dated thing due today or tomorrow (`dueOf`).
  public func due(today: Date, calendar: Calendar) -> MatterStep? {
    steps.filter { step in
      guard step.due, !step.isDone else { return false }
      let away = MemoryDigest.days(from: today, to: step.date, calendar: calendar)
      return away >= 0 && away <= 1
    }.min { $0.date < $1.date }
  }

  /// The nearest undone date within the next 14 days (urgency).
  public func nextDate(today: Date, calendar: Calendar) -> Date? {
    steps.filter { step in
      guard !step.isDone, step.glyph != .open else { return false }
      let away = MemoryDigest.days(from: today, to: step.date, calendar: calendar)
      return away >= 0 && away <= 14
    }.map(\.date).min()
  }

  /// The latest finished step on or before today.
  public func lastDone(today: Date) -> MatterStep? {
    steps.filter { $0.isDone && $0.date <= today }.max {
      ($0.date, $0.kind == "decision" ? 1 : 0) < ($1.date, $1.kind == "decision" ? 1 : 0)
    }
  }

  public func step(_ id: String) -> MatterStep? { steps.first { $0.id == id } }
}

/// 按截止's row (§13.4): a real deadline, the user's own promise, or the
/// status line's dated step, with the other matters folded into it.
public struct MatterDeadlineRow: Equatable, Identifiable, Sendable {
  public let date: Date
  /// deadline · step · commitment
  public let kind: String
  public let text: String
  public let eventID: String
  /// The step it opens (nil for a status fact with no step).
  public let stepID: String?
  /// Other live matters folded into the same deadline.
  public let alsoEventIDs: [String]

  public var id: String { "\(eventID)|\(stepID ?? text)|\(date.timeIntervalSince1970)" }
}

/// Every live matter of the projection, digested, with 按截止's rows.
public struct MemoryDigest: Equatable, Sendable {
  /// In Home order (the organizer's rank).
  public let matters: [MatterDigest]
  public let deadlines: [MatterDeadlineRow]
  /// Midnight of "now".
  public let today: Date
  public let now: Date
  /// The owner's names the display guards used (「我」 in quotes and 原文).
  public let ownerNames: [String]

  private let index: [String: Int]

  public func matter(_ eventID: String) -> MatterDigest? {
    index[eventID].map { matters[$0] }
  }

  /// 「一起定下的」: decisions and promises naming this person, newest first.
  public func decided(withPersonNamed name: String) -> [(matter: MatterRef, step: MatterStep)] {
    matters.flatMap { matter in
      matter.steps.filter { $0.isDecisionOrPromise && $0.who.contains(name) }.map {
        (MatterRef(eventID: matter.eventID, title: matter.title), $0)
      }
    }.sorted { $0.step.date > $1.step.date }
  }

  static let horizonDays = 70
  static let pastDeadlineDays = 7

  public init(
    projection: MemoryProjection, user: UserOrganizingSnapshot = .empty, now: Date,
    calendar: Calendar, ownerNames: [String] = []
  ) {
    self.now = now
    let today = calendar.startOfDay(for: now)
    self.today = today
    let owners = Self.ownerNames(projection: projection, extra: ownerNames)
    self.ownerNames = owners
    let home = projection.home()
    let titles = Dictionary(
      projection.events.map { ($0.eventID, MemoryDisplayText.name($0.title, ownerNames: owners)) },
      uniquingKeysWith: { a, _ in a })
    // Item → the live matters holding it (Home order), for 「同一场会还讲到」.
    var holders: [String: [String]] = [:]
    for event in projection.events {
      var seen = Set<String>()
      for id in event.itemIDs where seen.insert(id.uppercased()).inserted {
        holders[id.uppercased(), default: []].append(event.eventID)
      }
    }
    let rank = Dictionary(
      home.enumerated().map { ($1.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    let entries = Dictionary(home.map { ($0.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    var digests: [MatterDigest] = []
    for event in projection.events {
      let builder = MatterBuilder(
        event: event, projection: projection, user: user, today: today, calendar: calendar,
        owners: owners, titles: titles, holders: holders)
      digests.append(
        builder.digest(
          rank: rank[event.eventID] ?? Int.max, people: entries[event.eventID]?.shownPeople ?? []))
    }
    digests.sort { ($0.rank, $0.eventID) < ($1.rank, $1.eventID) }
    matters = digests
    index = Dictionary(digests.enumerated().map { ($1.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    deadlines = Self.deadlineRows(
      digests, events: projection.events, today: today, calendar: calendar, owners: owners)
  }

  public static func == (lhs: MemoryDigest, rhs: MemoryDigest) -> Bool {
    lhs.matters == rhs.matters && lhs.deadlines == rhs.deadlines && lhs.now == rhs.now
  }

  /// Whole days from `from` to `to` (both taken at midnight).
  public static func days(from: Date, to: Date, calendar: Calendar) -> Int {
    calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)
    ).day ?? 0
  }

  /// The owner's names: the projection's owner persons and their aliases, plus
  /// `extra`.
  static func ownerNames(projection: MemoryProjection, extra: [String]) -> [String] {
    var names = extra
    for person in projection.persons
    where projection.ownerPersonIDs.contains(person.personID.uppercased()) {
      if let name = person.displayName { names.append(name) }
      names.append(contentsOf: person.aliases)
    }
    var seen = Set<String>()
    // Longest first, so 林知远 is rewritten before 知远.
    return names.map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
      .sorted { $0.count > $1.count }
  }

  // MARK: - 按截止

  static func deadlineRows(
    _ matters: [MatterDigest], events: [MemoryEventSource], today: Date, calendar: Calendar,
    owners: [String]
  ) -> [MatterDeadlineRow] {
    struct Row {
      var date: Date
      var kind: String
      var text: String
      var matter: MatterDigest
      var stepID: String?
      var also: [String] = []
    }
    let byID = Dictionary(events.map { ($0.eventID, $0) }, uniquingKeysWith: { a, _ in a })
    var rows: [Row] = []
    for matter in matters {
      var own: [Row] = []
      let hasMap = byID[matter.eventID]?.map != nil
      if hasMap {
        for step in matter.steps where !step.fromStatus && !step.inferred && !step.isDone {
          if step.kind == "deadline" || (step.kind == "commitment" && step.who.isEmpty) {
            own.append(
              Row(date: step.date, kind: step.kind, text: step.text, matter: matter, stepID: step.id))
          }
        }
      } else {
        for fact in matter.facts where fact.state == .planned && fact.text.contains("截止") {
          guard let date = fact.date else { continue }
          own.append(Row(date: date, kind: "deadline", text: fact.text, matter: matter, stepID: nil))
        }
      }
      for step in matter.steps where step.fromStatus && !step.isDone {
        guard !own.contains(where: { $0.date == step.date }) else { continue }
        own.append(Row(date: step.date, kind: "step", text: step.text, matter: matter, stepID: step.id))
      }
      rows += own
    }
    rows = rows.filter { row in
      let away = days(from: today, to: row.date, calendar: calendar)
      return away <= horizonDays
        && (away >= 0 || (row.kind == "deadline" && -away <= pastDeadlineDays))
    }
    let order = ["deadline": 0, "step": 1, "commitment": 2]
    rows.sort { ($0.date, order[$0.kind] ?? 3) < ($1.date, order[$1.kind] ?? 3) }
    var kept: [Row] = []
    for row in rows {
      if let index = kept.firstIndex(where: { q in
        q.date == row.date
          && (q.matter.eventID == row.matter.eventID
            || (!MemoryDisplayText.bigrams(q.text).isDisjoint(with: MemoryDisplayText.bigrams(row.text))
              && related(q.matter, row.matter)))
      }) {
        if kept[index].matter.eventID != row.matter.eventID,
          !kept[index].also.contains(row.matter.eventID)
        {
          kept[index].also.append(row.matter.eventID)
        }
        continue
      }
      kept.append(row)
    }
    // Each matter's overdue step, when it is not a row already.
    for matter in matters {
      // (Also not when the matter already has a row that day: a matter with
      // no map lists its 截止 fact, and its overdue step is that same fact;
      // live-mac saw 「推免系统截止」 twice on 按截止.)
      guard let over = matter.overdue,
        !kept.contains(where: {
          $0.matter.eventID == matter.eventID && ($0.stepID == over.id || $0.date == over.date)
        })
      else { continue }
      kept.append(Row(date: over.date, kind: "step", text: over.text, matter: matter, stepID: over.id))
    }
    kept.sort { ($0.date, order[$0.kind] ?? 3) < ($1.date, order[$1.kind] ?? 3) }
    return kept.map {
      MatterDeadlineRow(
        date: $0.date, kind: $0.kind, text: $0.text, eventID: $0.matter.eventID, stepID: $0.stepID,
        alsoEventIDs: $0.also)
    }
  }

  /// Two matters can hold the same dated thing only if their names share a
  /// term (Latin words of 3+ letters, or a CJK bigram) in the title or parts.
  static func related(_ a: MatterDigest, _ b: MatterDigest) -> Bool {
    !terms(a).isDisjoint(with: terms(b))
  }

  static func terms(_ matter: MatterDigest) -> Set<String> {
    let names = ([matter.title] + matter.parts.map(\.name)).joined(separator: " ")
    let latin = Set(
      MemoryDisplayText.matches(#"[A-Za-z][A-Za-z0-9\-]{2,}"#, in: names).map { $0.lowercased() })
    let cjk = MemoryDisplayText.replace(#"[A-Za-z0-9\-]+"#, in: names) { _ in " " }
    return latin.union(MemoryDisplayText.bigrams(cjk))
  }
}

/// Builds one matter's digest.
private struct MatterBuilder {
  let event: MemoryEventSource
  let projection: MemoryProjection
  let user: UserOrganizingSnapshot
  let today: Date
  let calendar: Calendar
  let owners: [String]
  let titles: [String: String]
  let holders: [String: [String]]

  private var ownerSet: Set<String> {
    Set(owners).union(MemoryProjection.ownerNames)
  }

  /// One person, one name: an alias the organizer knows ("Ann Gu") shows as
  /// the person's name (顾安).
  private var aliasNames: [String: String] {
    var names: [String: String] = [:]
    for person in projection.persons where person.mergedInto == nil {
      guard let name = person.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty
      else { continue }
      for alias in person.aliases where alias != name { names[alias] = name }
    }
    return names
  }

  func digest(rank: Int, people: [MemoryPersonRef]) -> MatterDigest {
    // The items on this Mac, each once, with the spelling its rows use.
    var spelled: [String: String] = [:]
    var records: [String: MemoryItemRecord] = [:]
    for id in event.itemIDs {
      let key = id.uppercased()
      guard spelled[key] == nil else { continue }
      spelled[key] = id
      if let record = projection.records[key], !record.isKeyframe { records[key] = record }
    }
    let days = Array(Set(records.values.map { calendar.startOfDay(for: $0.startedAt) })).sorted()
    let status = MemoryDisplayText.status(event.statusLine, ownerNames: owners)
    let map = event.map
    let parts = (map?.strands ?? []).map { strand -> MatterPart in
      let partDays = Set(
        strand.itemIDs.compactMap { records[$0.uppercased()] }.map {
          calendar.startOfDay(for: $0.startedAt)
        })
      return MatterPart(
        id: strand.id, name: MemoryDisplayText.name(strand.name, ownerNames: owners),
        summary: MemoryDisplayText.normalizedDates(
          MemoryDisplayText.withoutOwner(strand.summary, ownerNames: owners)),
        closed: strand.isClosed, days: partDays.sorted(),
        itemIDs: strand.itemIDs.map { $0.uppercased() })
    }.sorted { a, b in
      if a.closed != b.closed { return !a.closed }
      return (a.days.first ?? .distantFuture, a.id) < (b.days.first ?? .distantFuture, b.id)
    }

    let segments = Dictionary(grouping: event.segments, by: { $0.itemID.uppercased() })
    func rowID(_ key: String, segID: String?) -> String {
      let base = spelled[key] ?? key
      let held = segments[key] ?? []
      guard let part = held.first(where: { $0.segID == segID }) ?? held.first else { return base }
      return base + "#" + part.segID
    }
    func evidence(itemID: String?, quote: String, segID: String?) -> MatterEvidence? {
      guard let itemID, let record = records[itemID.uppercased()] ?? projection.records[itemID.uppercased()]
      else { return nil }
      let key = itemID.uppercased()
      let words = MemoryItemSource.words(record)
      let text = record.text ?? record.localReading ?? ""
      let lines = MemoryQuoteLines.around(
        quote, in: text, dictation: words.word == "口述" || words.word == "键盘", ownerNames: ownerSet)
      let also = (holders[key] ?? []).filter { $0 != event.eventID }.prefix(2).compactMap { id in
        titles[id].map { MatterRef(eventID: id, title: $0) }
      }
      return MatterEvidence(
        itemID: key, rowID: rowID(key, segID: segID), time: record.startedAt, source: words,
        lines: lines, quote: quote, alsoIn: Array(also))
    }

    // Knots.
    let aliases = aliasNames
    var steps: [MatterStep] = []
    for knot in map?.knots ?? [] {
      let explicit = isoDay(knot.date)
      let quoteRecord = knot.quoteItemID.flatMap { records[$0.uppercased()] }
      let evidenceDays = knot.evidence.compactMap { records[$0.uppercased()]?.startedAt }
      let inferredDate = (quoteRecord?.startedAt ?? evidenceDays.min()).map(calendar.startOfDay(for:))
      guard let date = explicit ?? inferredDate else { continue }
      let inferred = explicit == nil
      guard let glyph = glyph(kind: knot.kind, state: knot.state, date: date, inferred: inferred)
      else { continue }
      let components = calendar.dateComponents([.year, .month, .day], from: date)
      let text = MemoryDisplayText.stepLabel(
        knot.text, kind: knot.kind, state: knot.state, date: explicit == nil ? nil : components,
        inferred: inferred, ownerNames: owners)
      // People other than the owner (the owner is never listed: a promise
      // with no one else is the user's own).
      let who = knot.who.map { aliases[$0] ?? $0 }.filter {
        !ownerSet.contains($0) && !ownerSet.contains($0.lowercased())
      }
      let away = MemoryDigest.days(from: today, to: date, calendar: calendar)
      let mine = knot.kind == "commitment" && who.isEmpty
      let due =
        !inferred && knot.state != "done" && (knot.kind == "deadline" || mine) && away >= 0
        && away <= 1
      let ev =
        evidence(itemID: knot.quoteItemID, quote: knot.quote, segID: knot.quoteSegID)
        ?? evidence(itemID: knot.evidence.first, quote: "", segID: nil)
      steps.append(
        MatterStep(
          id: knot.id, partID: knot.strand, kind: knot.kind, state: knot.state, glyph: glyph,
          date: date, inferred: inferred, text: text, who: who, due: due, over: false,
          fromStatus: false, evidence: ev, override: nil))
    }

    // The status line's dated steps on a date no knot already has.
    let have = Set(steps.filter { !$0.inferred }.map(\.date))
    let todayComponents = calendar.dateComponents([.year, .month, .day], from: today)
    let statusSteps = MemoryDisplayText.statusSteps(
      status, today: todayComponents, calendar: calendar)
    // Each (day, words) once: a status line that says the same dated thing
    // twice gave live-mac 「9月28日 已过期 交回复信」 twice on a small page.
    var seenStatus = Set<String>()
    for (offset, found) in statusSteps.enumerated() {
      guard let date = calendar.date(from: found.date).map(calendar.startOfDay(for:)),
        seenStatus.insert("\(date.timeIntervalSince1970)|\(found.verb)").inserted
      else {
        continue
      }
      let away = MemoryDigest.days(from: today, to: date, calendar: calendar)
      // A deadline verb (交, 截止 …) or a limit (「9月28日前确认」) that passed
      // within the week is overdue (fix-mac: text-only limits were not).
      let over =
        away < 0 && -away <= 7 && (MemoryDisplayText.isDeadlineVerb(found.verb) || found.byDate)
      guard !have.contains(date), away >= 0 || over else { continue }
      let words = MemoryDisplayText.bigrams(found.verb)
      let part = parts.map { ($0.id, MemoryDisplayText.bigrams($0.name).intersection(words).count) }
        .filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
      steps.append(
        MatterStep(
          id: "st\(offset + 1)", partID: part, kind: "step", state: "planned", glyph: .next,
          date: date, inferred: false, text: found.verb, who: [], due: away >= 0 && away <= 1,
          over: over, fromStatus: true,
          evidence: statusSource(date: date, verb: found.verb, records: records, evidence: evidence),
          override: nil))
    }

    // The user's own 标为完成 / 已经定了 win.
    steps = steps.map { step in
      guard let mark = user.override(eventID: event.eventID, stepID: step.id) else { return step }
      let markDay = calendar.startOfDay(for: mark.createdAt)
      let date = step.date > markDay ? markDay : step.date
      return MatterStep(
        id: step.id, partID: step.partID, kind: step.kind, state: "done", glyph: .done, date: date,
        inferred: step.inferred, text: step.text, who: step.who, due: false, over: false,
        fromStatus: step.fromStatus, evidence: step.evidence, override: mark.state)
    }
    steps.sort { ($0.date, $0.id.count, $0.id) < ($1.date, $1.id.count, $1.id) }

    let facts = event.listedFacts.map { fact -> MatterFact in
      let date = fact.day.flatMap { calendar.date(from: $0) }.map(calendar.startOfDay(for:))
      return MatterFact(
        text: MemoryDisplayText.clean(
          fact.text, date: fact.day, inferred: fact.day == nil, ownerNames: owners),
        state: fact.state, date: date)
    }
    let risk: String? =
      map?.health.flatMap { health in
        health.level == "risk"
          ? MemoryDisplayText.risk(reason: health.reason, status: event.statusLine, ownerNames: owners)
          : nil
      }

    return MatterDigest(
      eventID: event.eventID, handle: event.handle, origin: event.origin, rank: rank,
      title: titles[event.eventID] ?? event.title, status: status, risk: risk,
      firstDay: days.first, lastDay: days.last ?? event.updatedAt.map(calendar.startOfDay(for:)),
      days: days, itemIDs: records.keys.sorted(), people: people, parts: parts, steps: steps,
      facts: facts)
  }

  /// `glyph_state`; nil drops the step (a past deadline whose date was only
  /// inferred).
  func glyph(kind: String, state: String, date: Date, inferred: Bool) -> MatterStepGlyph? {
    if kind == "question", state == "open" { return .open }
    if date > today { return state == "done" ? .done : .next }
    if date == today, state == "planned" { return .next }
    if state == "done" || kind == "decision" { return .done }
    if kind == "deadline" { return inferred ? nil : .done }
    return .minor
  }

  func isoDay(_ value: String?) -> Date? {
    guard let value, let components = MemoryStatusFact.day(from: value),
      let date = calendar.date(from: components)
    else { return nil }
    return calendar.startOfDay(for: date)
  }

  /// Where a date in the status line was said (`status_source`): the item,
  /// newest first, whose words near that date share the most with the step
  /// (score ≥ 3; stop at ≥ 4); the quote is the clause holding the date. Nil
  /// when no item says it: the card says so instead of inventing a source.
  func statusSource(
    date: Date, verb: String, records: [String: MemoryItemRecord],
    evidence: (String?, String, String?) -> MatterEvidence?
  ) -> MatterEvidence? {
    let parts = calendar.dateComponents([.month, .day], from: date)
    guard let month = parts.month, let day = parts.day else { return nil }
    let patterns = [
      "\(month)月\(day)[日号]?", "(?<![\\d.])\(month)/\(day)(?!\\d)", "(?<![\\d/.月-])\(day)[号日](?!\\d)",
    ]
    let verbWords = MemoryDisplayText.bigrams(verb)
    let titleWords = MemoryDisplayText.bigrams(titles[event.eventID] ?? event.title)
    var best: (score: Int, item: String, quote: String)?
    for (key, record) in records.sorted(by: { $0.value.startedAt > $1.value.startedAt }) {
      let text = record.text ?? ""
      let ns = text as NSString
      for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
          let lo = max(0, match.range.location - 30)
          let hi = min(ns.length, match.range.location + match.range.length + 30)
          let window = ns.substring(with: NSRange(location: lo, length: hi - lo))
          let words = MemoryDisplayText.bigrams(window)
          let score =
            2 * words.intersection(verbWords).count + words.intersection(titleWords).count
          guard score >= 3, best == nil || score > best!.score else { continue }
          // The clause holding the date (UTF-16 offsets, as NSString counts).
          let before = ns.substring(to: match.range.location)
          let start =
            before.rangeOfCharacter(
              from: CharacterSet(charactersIn: "，。；！？\n,"), options: .backwards
            ).map { before.utf16.distance(from: before.startIndex, to: $0.upperBound) } ?? 0
          let afterStart = match.range.location + match.range.length
          let after = ns.substring(from: afterStart)
          let end =
            after.rangeOfCharacter(from: CharacterSet(charactersIn: "，。；！？\n")).map {
              afterStart + after.utf16.distance(from: after.startIndex, to: $0.lowerBound)
            } ?? ns.length
          let quote = ns.substring(with: NSRange(location: start, length: max(0, end - start)))
            .trimmingCharacters(in: .whitespaces)
          best = (score, key, quote)
        }
      }
      if let best, best.score >= 4 { break }
    }
    guard let best else { return nil }
    let quote = MemoryDisplayText.replace(#"[*#`>]+"#, in: best.quote) { _ in "" }
      .trimmingCharacters(in: .whitespaces)
    guard let found = evidence(best.item, quote, nil) else { return nil }
    // The status step names no other matter: the moment line stays empty.
    return MatterEvidence(
      itemID: found.itemID, rowID: found.rowID, time: found.time, source: found.source,
      lines: found.lines, quote: found.quote, alsoIn: [])
  }
}
