import BestASRDomain
import BestASRMemory
import Foundation
import MindloomAgentProtocol

/// One tool's answer: text for the agent to read, the same content as
/// `structuredContent`, and (for the audit) the matter IDs it returned.
struct AgentToolOutput: Sendable {
  var text: String
  var structured: JSONValue
  var matterIDs: [String]
  var isError = false
  var outcome: AgentAuditOutcome = .allowed

  var result: JSONValue {
    [
      "content": [["type": "text", "text": .string(text)]],
      "structuredContent": structured,
      "isError": .bool(isError),
    ]
  }

  static func failure(_ message: String, code: String, outcome: AgentAuditOutcome)
    -> AgentToolOutput
  {
    AgentToolOutput(
      text: message, structured: ["error": .string(code), "message": .string(message)],
      matterIDs: [], isError: true, outcome: outcome)
  }
}

/// Numbers out as placeholders unless the grant says 原样 (AGENT-CONTRACT §1).
struct AgentTextMask: Sendable {
  let masker: PrivacyMasker?

  func callAsFunction(_ text: String) -> String { masker?.mask(text) ?? text }
  var isMasking: Bool { masker != nil }

  /// True when the masking rules would hide something in `text`.
  func hides(_ text: String) -> Bool {
    guard isMasking else { return false }
    return !PrivacyMasker.detectionOnly.maskWithSpans(text).spans.isEmpty
  }
}

/// Reads the snapshot for the tools, within one grant's scope. Everything a
/// matter says (titles, status, facts, names, quotes, item text) passes
/// through `mask`; IDs, dates and fixed labels do not.
struct AgentReader {
  let snapshot: AgentMemorySnapshot
  /// True when the grant covers the matter (space and range).
  let inScope: (String) -> Bool
  let mask: AgentTextMask
  /// Which other matters a split recording's note may name (V7-A1): those in
  /// scope, and none at all when each new matter waits for the owner.
  var showSibling: (String) -> Bool = { _ in false }

  /// Characters of one item's body the text lens prints.
  static let excerptCharacters = 2_000
  /// Characters of all item bodies together.
  static let totalExcerptCharacters = 60_000
  static let quoteCharacters = 160
  static let maximumQuotes = 8
  static let overdueDays = 7

  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = snapshot.timeZone
    return calendar
  }

  /// In-scope matters in Home order (pins, importance, recency).
  var matters: [MemoryHomeEntry] {
    snapshot.projection.home().filter { inScope($0.eventID) }
  }

  /// In-scope matters, most recently moved first (matters with no date last).
  var byRecency: [MemoryHomeEntry] {
    matters.enumerated().sorted {
      let left = $0.element.lastUpdate ?? $0.element.span?.end ?? .distantPast
      let right = $1.element.lastUpdate ?? $1.element.span?.end ?? .distantPast
      return left != right ? left > right : $0.offset < $1.offset
    }.map(\.element)
  }

  func entry(_ matterID: String) -> MemoryHomeEntry? {
    matters.first { $0.eventID.caseInsensitiveCompare(matterID) == .orderedSame }
  }

  // MARK: Pieces

  func facts(_ matterID: String) -> [MemoryStatusFact] {
    snapshot.projection.events.first {
      $0.eventID.caseInsensitiveCompare(matterID) == .orderedSame
    }?.statusFacts ?? []
  }

  func dayNumber(_ day: DateComponents) -> Int? {
    guard let year = day.year, let month = day.month, let date = day.day else { return nil }
    return year * 10_000 + month * 100 + date
  }

  var today: Int {
    let parts = calendar.dateComponents([.year, .month, .day], from: snapshot.now)
    return dayNumber(parts) ?? 0
  }

  func isoDay(_ day: DateComponents) -> String {
    String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
  }

  func dayNumber(daysFromToday offset: Int) -> Int {
    let date = calendar.date(byAdding: .day, value: offset, to: snapshot.now) ?? snapshot.now
    return dayNumber(calendar.dateComponents([.year, .month, .day], from: date)) ?? 0
  }

  /// The nearest planned fact on or after today.
  func nearestDeadline(_ matterID: String) -> MemoryStatusFact? {
    facts(matterID).filter { fact in
      fact.state == .planned && (fact.day.flatMap(dayNumber) ?? 0) >= today
    }.min { (dayNumber($0.day!) ?? 0) < (dayNumber($1.day!) ?? 0) }
  }

  func rope(_ matterID: String) -> AgentRope? { snapshot.ropeChain(of: matterID).first }

  func stateLabel(_ state: MemoryStatusFact.State) -> String {
    switch state {
    case .planned: "计划"
    case .inProgress: "进行中"
    case .done: "已完成"
    case .cancelled: "已取消"
    case .info: "信息"
    }
  }

  func iso(_ date: Date?) -> JSONValue {
    guard let date else { return .null }
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = snapshot.timeZone
    formatter.formatOptions = [.withInternetDateTime]
    return .string(formatter.string(from: date))
  }

  func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  func clipped(_ text: String, _ limit: Int) -> (String, Bool) {
    guard text.count > limit else { return (text, false) }
    return (String(text.prefix(limit)) + "…", true)
  }

  func factJSON(_ fact: MemoryStatusFact) -> JSONValue {
    [
      "text": .string(mask(fact.text)), "state": .string(fact.state.rawValue),
      "date": fact.day.map { .string(isoDay($0)) } ?? .null,
      "quote": fact.quote.map { .string(mask($0)) } ?? .null,
      "item_ids": .strings(fact.itemIDs),
    ]
  }

  func summaryJSON(_ entry: MemoryHomeEntry) -> JSONValue {
    let deadline = nearestDeadline(entry.eventID)
    let rope = rope(entry.eventID)
    return [
      "id": .string(entry.eventID),
      "title": .string(mask(entry.title)),
      "status": .string(entry.statusIsFallback ? "" : mask(oneLine(entry.statusLine))),
      "nearest_deadline": deadline.map {
        ["date": .string(isoDay($0.day!)), "text": .string(mask($0.text))]
      } ?? .null,
      "rope": rope.map { ["id": .string($0.id), "title": .string(mask($0.title))] } ?? .null,
      "space": .string(snapshot.space(of: entry.eventID)),
      "updated_at": iso(entry.lastUpdate),
      "item_count": .int(Int64(entry.itemCount)),
    ]
  }

  func summaryLines(_ entry: MemoryHomeEntry) -> [String] {
    var lines = ["· \(mask(oneLine(entry.title)))（id：\(entry.eventID)）"]
    if !entry.statusIsFallback, !oneLine(entry.statusLine).isEmpty {
      lines.append("  现在：\(mask(oneLine(entry.statusLine)))")
    }
    if let deadline = nearestDeadline(entry.eventID) {
      lines.append("  最近的截止：\(isoDay(deadline.day!)) \(mask(oneLine(deadline.text)))")
    }
    if let rope = rope(entry.eventID) { lines.append("  绳：\(mask(oneLine(rope.title)))") }
    return lines
  }

  var maskNote: String? {
    mask.isMasking ? "号码已遮住：〔手机号·……〕这类占位符是被遮住的号码，原样保留，不要猜。" : nil
  }

  // MARK: search_matters

  /// Matters whose words contain `query`. With numbers masked, the words
  /// searched are the masked ones the agent would read: a digit-by-digit
  /// query can never tell what a placeholder hides (review V7-A2). A query
  /// that itself holds a number the rules would hide is refused by the
  /// caller (`mask.hides`).
  func search(query: String, space: String?) -> [MemoryHomeEntry] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return matters.filter { entry in
      if let space, snapshot.space(of: entry.eventID) != space { return false }
      guard !needle.isEmpty else { return true }
      let words =
        [entry.title, entry.statusLine, entry.searchText] + entry.people.map(\.name)
        + facts(entry.eventID).map(\.text) + snapshot.ropeChain(of: entry.eventID).map(\.title)
      return words.contains { mask($0).localizedCaseInsensitiveContains(needle) }
    }
  }

  func renderSearch(_ entries: [MemoryHomeEntry], matched: Int, waiting: Int) -> AgentToolOutput {
    var lines = [AgentCopy.dataHeader]
    lines.append(entries.isEmpty ? "没有找到。" : "找到 \(entries.count) 件事：")
    for entry in entries { lines.append(contentsOf: summaryLines(entry)) }
    if waiting > 0 { lines.append(AgentCopy.mattersWaiting(waiting)) }
    if let note = maskNote { lines.append(note) }
    return AgentToolOutput(
      text: lines.joined(separator: "\n"),
      structured: [
        "matters": .array(entries.map(summaryJSON)), "total_matched": .int(Int64(matched)),
        "waiting_approval": .int(Int64(waiting)),
      ],
      matterIDs: entries.map(\.eventID))
  }

  // MARK: get_matter

  func detail(_ matterID: String) -> MemoryEventDetail? {
    guard let entry = entry(matterID) else { return nil }
    return snapshot.projection.event(id: entry.eventID)
  }

  func renderMatter(_ detail: MemoryEventDetail, json: Bool) -> AgentToolOutput {
    let formatter = EventPlainTextFormatter(timeZone: snapshot.timeZone)
    let id = detail.eventID
    let facts = MemoryStatusFact.ordered(
      detail.statusFacts.isEmpty ? self.facts(id) : detail.statusFacts)
    let strands = snapshot.strands(of: id)
    let chain = snapshot.ropeChain(of: id)
    var lines = ["织机里的一件事（id：\(id)）", AgentCopy.dataHeader, ""]
    lines.append("标题：\(mask(oneLine(detail.title)))")
    var place = "空间：\(snapshot.spaceName(snapshot.space(of: id)))"
    if !chain.isEmpty {
      place += " · 绳：" + chain.reversed().map { mask(oneLine($0.title)) }.joined(separator: " › ")
    }
    lines.append(place)
    if let span = detail.span { lines.append("日期：\(formatter.dateLine(span))") }
    let status = detail.statusIsFallback ? "" : oneLine(detail.statusLine)
    if !status.isEmpty { lines.append("现在：\(mask(status))") }
    if !detail.shownPeople.isEmpty {
      lines.append("人物：" + detail.shownPeople.map { mask(oneLine($0.name)) }.joined(separator: "、"))
    }
    if !facts.isEmpty {
      lines.append("")
      lines.append("已经知道的：")
      for fact in facts {
        var line = "- [\(stateLabel(fact.state))] \(mask(oneLine(fact.text)))"
        if let day = fact.day { line += "（\(isoDay(day))）" }
        if !fact.itemIDs.isEmpty { line += " 〔依据：\(fact.itemIDs.joined(separator: "、"))〕" }
        lines.append(line)
      }
    }
    if !strands.isEmpty {
      lines.append("")
      lines.append("分线：")
      for strand in strands {
        lines.append(
          "- \(mask(oneLine(strand.name)))（\(strand.isOpen ? "进行中" : "已结束")）：\(mask(oneLine(strand.summary)))"
        )
      }
    }
    if let note = maskNote {
      lines.append("")
      lines.append(note)
    }
    lines.append("")
    lines.append("原始资料（每条正文以“> ”开头；“节选：”“读图概要：”“文件概要：”是织机写的说明）：")
    var budget = Self.totalExcerptCharacters
    var itemsJSON: [JSONValue] = []
    var omitted = 0
    for item in detail.items {
      guard budget > 0 else {
        omitted += 1
        continue
      }
      let parts = formatter.parts(of: item, in: detail) { showSibling($0.eventID) }
      let (excerpt, truncated) = clipped(
        mask(parts.body), min(Self.excerptCharacters, budget))
      budget -= excerpt.count
      lines.append("")
      lines.append("[条目 \(item.itemID)] \(mask(parts.header))")
      for note in parts.notes { lines.append(mask(note)) }
      for line in excerpt.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        lines.append(line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + line)
      }
      if truncated { lines.append("（节选；全文在织机里）") }
      var itemJSON: [String: JSONValue] = [
        "id": .string(item.itemID), "time": iso(item.startedAt),
        "source": .string(mask(item.sourceLabel)),
        "kind": .string(
          item.record?.itemKind?.rawValue ?? (item.record == nil ? "deleted" : "recording")),
        "excerpt": .string(excerpt), "truncated": .bool(truncated),
        "notes": .strings(parts.notes.map { mask($0) }),
      ]
      if let segment = item.segment { itemJSON["part"] = .string(mask(segment.gist)) }
      itemsJSON.append(.object(itemJSON))
    }
    if omitted > 0 {
      lines.append("")
      lines.append("（还有 \(omitted) 条资料没有列出）")
    }
    let structured: JSONValue = [
      "id": .string(id),
      "title": .string(mask(detail.title)),
      "space": .string(snapshot.space(of: id)),
      "ropes": .array(chain.map { ["id": .string($0.id), "title": .string(mask($0.title))] }),
      "span": detail.span.map { ["start": iso($0.start), "end": iso($0.end)] } ?? .null,
      "status": .string(mask(status)),
      "people": .strings(detail.shownPeople.map { mask($0.name) }),
      "facts": .array(facts.map(factJSON)),
      "strands": .array(
        strands.map {
          [
            "id": .string($0.id), "name": .string(mask($0.name)),
            "summary": .string(mask($0.summary)), "item_ids": .strings($0.itemIDs),
            "state": .string($0.isOpen ? "open" : "closed"),
          ]
        }),
      "items": .array(itemsJSON),
      "items_omitted": .int(Int64(omitted)),
      "numbers_masked": .bool(mask.isMasking),
      "note": .string(AgentCopy.dataHeader),
    ]
    let text = json ? structured.serialized : lines.joined(separator: "\n")
    return AgentToolOutput(text: text, structured: structured, matterIDs: [id])
  }

  // MARK: list_deadlines

  struct Deadline {
    let entry: MemoryHomeEntry
    let fact: MemoryStatusFact
    let day: Int
  }

  func deadlines(days: Int) -> [Deadline] {
    let first = dayNumber(daysFromToday: -Self.overdueDays)
    let last = dayNumber(daysFromToday: days)
    var result: [Deadline] = []
    for entry in matters {
      for fact in facts(entry.eventID) where fact.state == .planned {
        guard let day = fact.day.flatMap(dayNumber), day >= first, day <= last else { continue }
        result.append(Deadline(entry: entry, fact: fact, day: day))
      }
    }
    return result.enumerated().sorted {
      $0.element.day != $1.element.day ? $0.element.day < $1.element.day : $0.offset < $1.offset
    }.map(\.element)
  }

  func renderDeadlines(_ deadlines: [Deadline], days: Int, waiting: Int) -> AgentToolOutput {
    var lines = [AgentCopy.dataHeader]
    lines.append(deadlines.isEmpty ? "接下来 \(days) 天没有有日期的计划。" : "接下来 \(days) 天的截止（按日期）：")
    for deadline in deadlines {
      let overdue = deadline.day < today
      lines.append(
        "· \(isoDay(deadline.fact.day!))\(overdue ? "（已过期）" : "") \(mask(oneLine(deadline.fact.text)))"
          + " — \(mask(oneLine(deadline.entry.title)))（id：\(deadline.entry.eventID)）")
    }
    if waiting > 0 { lines.append(AgentCopy.mattersWaiting(waiting)) }
    if let note = maskNote { lines.append(note) }
    return AgentToolOutput(
      text: lines.joined(separator: "\n"),
      structured: [
        "deadlines": .array(
          deadlines.map {
            [
              "date": .string(isoDay($0.fact.day!)), "text": .string(mask($0.fact.text)),
              "matter_id": .string($0.entry.eventID), "matter_title": .string(mask($0.entry.title)),
              "overdue": .bool($0.day < today), "item_ids": .strings($0.fact.itemIDs),
            ]
          }),
        "days": .int(Int64(days)), "waiting_approval": .int(Int64(waiting)),
      ],
      matterIDs: Array(Set(deadlines.map(\.entry.eventID))).sorted())
  }

  // MARK: list_recent

  func recent(days: Int, space: String?) -> [MemoryHomeEntry] {
    let since = snapshot.now.addingTimeInterval(-Double(days) * 86_400)
    return matters.filter { entry in
      if let space, snapshot.space(of: entry.eventID) != space { return false }
      guard let moved = entry.lastUpdate ?? entry.span?.end else { return false }
      return moved >= since
    }.enumerated().sorted {
      let left = $0.element.lastUpdate ?? $0.element.span?.end ?? .distantPast
      let right = $1.element.lastUpdate ?? $1.element.span?.end ?? .distantPast
      return left != right ? left > right : $0.offset < $1.offset
    }.map(\.element)
  }

  func renderRecent(_ entries: [MemoryHomeEntry], days: Int, waiting: Int) -> AgentToolOutput {
    var lines = [AgentCopy.dataHeader]
    lines.append(entries.isEmpty ? "最近 \(days) 天没有有动静的事。" : "最近 \(days) 天有动静的事（最近的在前）：")
    for entry in entries {
      lines.append(contentsOf: summaryLines(entry))
      if let moved = entry.lastUpdate ?? entry.span?.end, case .string(let text) = iso(moved) {
        lines.append("  最近一次：\(text)")
      }
    }
    if waiting > 0 { lines.append(AgentCopy.mattersWaiting(waiting)) }
    if let note = maskNote { lines.append(note) }
    return AgentToolOutput(
      text: lines.joined(separator: "\n"),
      structured: [
        "matters": .array(entries.map(summaryJSON)), "days": .int(Int64(days)),
        "waiting_approval": .int(Int64(waiting)),
      ],
      matterIDs: entries.map(\.eventID))
  }

  // MARK: get_person

  /// The person the name means, with their in-scope matters; nil when the
  /// name matches no one who takes part in an in-scope matter.
  func person(named raw: String) -> (MemoryPersonEntry, [MemoryHomeEntry])? {
    let wanted = MemorySpeakerLines.normalized(raw)
    guard !wanted.isEmpty else { return nil }
    let people = snapshot.projection.people().compactMap {
      person -> (MemoryPersonEntry, [MemoryHomeEntry])? in
      let events = person.events.filter { inScope($0.eventID) }
      return events.isEmpty ? nil : (person, events)
    }
    if let exact = people.first(where: { MemorySpeakerLines.normalized($0.0.name) == wanted }) {
      return exact
    }
    let partial = people.filter {
      MemorySpeakerLines.normalized($0.0.name).contains(wanted)
    }
    return partial.count == 1 ? partial[0] : nil
  }

  struct Quote {
    let text: String
    let date: Date?
    let matterID: String
    let itemID: String
  }

  func quotes(of person: MemoryPersonEntry, in matters: [MemoryHomeEntry]) -> [Quote] {
    let wantedID = snapshot.projection.canonicalPersonID(person.personID).uppercased()
    let wantedName = MemorySpeakerLines.normalized(person.name)
    var found: [Quote] = []
    for entry in matters {
      guard let detail = snapshot.projection.event(id: entry.eventID) else { continue }
      var perMatter: [Quote] = []
      for item in detail.items {
        guard let record = item.record else { continue }
        if item.segment == nil, record.inputMode != .userItem {
          for segment in record.segments {
            let id = segment.personID.map {
              snapshot.projection.canonicalPersonID($0.rawValue.uuidString).uppercased()
            }
            let named = segment.personName.map(MemorySpeakerLines.normalized)
            guard id == wantedID || (id == nil && named == wantedName) else { continue }
            perMatter.append(
              Quote(
                text: segment.text,
                date: record.startedAt.addingTimeInterval(
                  Double(segment.startMilliseconds) / 1_000),
                matterID: entry.eventID, itemID: item.itemID))
          }
          continue
        }
        let text = item.shownText ?? ""
        if let transcript = MemoryTranscriptText.parse(text) {
          for turn in transcript.turns
          where MemorySpeakerLines.normalized(turn.speaker) == wantedName {
            perMatter.append(
              Quote(
                text: turn.text, date: record.startedAt, matterID: entry.eventID,
                itemID: item.itemID))
          }
        } else if let turns = MemoryChatText.turns(in: text, knownNames: [person.name]) {
          for turn in turns where MemorySpeakerLines.normalized(turn.name) == wantedName {
            perMatter.append(
              Quote(
                text: turn.text, date: record.startedAt, matterID: entry.eventID,
                itemID: item.itemID))
          }
        }
      }
      let useful = perMatter.filter { oneLine($0.text).count >= 4 }
      found.append(
        contentsOf: useful.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(
          2))
    }
    return Array(
      found.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(
        Self.maximumQuotes))
  }

  func renderPerson(
    _ person: MemoryPersonEntry, matters: [MemoryHomeEntry], quotes: [Quote], waiting: Int
  )
    -> AgentToolOutput
  {
    var lines = [AgentCopy.dataHeader, "人物：\(mask(oneLine(person.name)))"]
    lines.append("参与的事（\(matters.count) 件）：")
    for entry in matters { lines.append(contentsOf: summaryLines(entry)) }
    if !quotes.isEmpty {
      lines.append("最近说过的话（正文以“> ”开头）：")
      for quote in quotes {
        let (text, _) = clipped(mask(oneLine(quote.text)), Self.quoteCharacters)
        var place = "事 \(quote.matterID) · 条目 \(quote.itemID)"
        if case .string(let time) = iso(quote.date) { place = time + " · " + place }
        lines.append("> \(text)")
        lines.append("  （\(place)）")
      }
    }
    if waiting > 0 { lines.append(AgentCopy.mattersWaiting(waiting)) }
    if let note = maskNote { lines.append(note) }
    return AgentToolOutput(
      text: lines.joined(separator: "\n"),
      structured: [
        "name": .string(mask(person.name)),
        "matters": .array(matters.map(summaryJSON)),
        "quotes": .array(
          quotes.map {
            [
              "text": .string(clipped(mask(oneLine($0.text)), Self.quoteCharacters).0),
              "time": iso($0.date), "matter_id": .string($0.matterID),
              "item_id": .string($0.itemID),
            ]
          }),
        "waiting_approval": .int(Int64(waiting)),
      ],
      matterIDs: matters.map(\.eventID))
  }

  // MARK: resources

  func resourceList(_ entries: [MemoryHomeEntry]) -> JSONValue {
    [
      "resources": .array(
        entries.map {
          [
            "uri": .string(AgentResource.uri(matterID: $0.eventID)),
            "name": .string($0.eventID),
            "title": .string(mask(oneLine($0.title))),
            "description": .string($0.statusIsFallback ? "" : mask(oneLine($0.statusLine))),
            "mimeType": .string(AgentResource.mimeType),
          ]
        })
    ]
  }
}
