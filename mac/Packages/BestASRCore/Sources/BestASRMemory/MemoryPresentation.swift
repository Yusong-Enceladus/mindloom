import BestASRDomain
import Foundation

/// One "where it stands" fact of a Spark event, styled by its state: a plan
/// is shown differently from a completion.
public struct MemoryStatusFact: Equatable, Sendable {
  public enum State: String, Equatable, Sendable {
    case planned
    case inProgress = "in_progress"
    case done
    case cancelled
    case info
  }

  public let text: String
  public let state: State
  /// The day the fact is about, when the organizer gave one (`YYYY-MM-DD`).
  public let day: DateComponents?
  /// A short verbatim clause backing a done, in-progress or cancelled fact.
  public let quote: String?
  public let itemIDs: [String]

  public init(
    text: String, state: State, day: DateComponents? = nil, quote: String? = nil,
    itemIDs: [String] = []
  ) {
    self.text = text
    self.state = state
    self.day = day
    self.quote = quote
    self.itemIDs = itemIDs
  }

  /// Older services send no state: such a fact is plain information.
  public init(remote fact: RemoteOrganizerEvent.StatusFact) {
    let quote = fact.quote?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      text: fact.text, state: fact.state.flatMap(State.init(rawValue:)) ?? .info,
      day: fact.date.flatMap(Self.day(from:)),
      quote: quote?.isEmpty == false ? quote : nil, itemIDs: fact.itemIDs)
  }

  static func day(from value: String) -> DateComponents? {
    let parts = value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
      return nil
    }
    return DateComponents(year: parts[0], month: parts[1], day: parts[2])
  }

  /// The day to show beside the text: nil when there is none, or when the
  /// text already says that day ("9月28日", "9月28号", "9/28", "2026-09-28",
  /// or "28日" in a text naming no month).
  public var chipDay: DateComponents? {
    guard let day, !Self.text(text, mentions: day) else { return nil }
    return day
  }

  static func text(_ text: String, mentions day: DateComponents) -> Bool {
    guard let month = day.month, let date = day.day else { return false }
    let m = "0?\(month)"
    let d = "0?\(date)"
    var patterns = [
      #"(?<!\d)"# + m + #"\s*月\s*"# + d + #"\s*[日号](?!\d)"#,
      #"(?<!\d)"# + m + "/" + d + #"(?![\d/])"#,
      #"(?<![\d-])"# + m + "-" + d + #"(?![\d-])"#,
      #"(?<!\d)\d{4}\s*[-/.年]\s*"# + m + #"\s*[-/.月]\s*"# + d + #"(?!\d)"#,
    ]
    if !text.contains("月") {
      patterns.append(#"(?<!\d)"# + d + #"\s*[日号](?!\d)"#)
    }
    return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
  }

  /// A fixed order however the organizer listed them: what is still to do by
  /// its day (earliest first, undated after), then what is under way, then
  /// what is done, then what was dropped, then plain information. Ties keep
  /// the organizer's order.
  public static func ordered(_ facts: [MemoryStatusFact]) -> [MemoryStatusFact] {
    func rank(_ state: State) -> Int {
      switch state {
      case .planned: 0
      case .inProgress: 1
      case .done: 2
      case .cancelled: 3
      case .info: 4
      }
    }
    func key(_ day: DateComponents?) -> (Int, Int) {
      guard let day, let year = day.year, let month = day.month, let date = day.day else {
        return (1, 0)
      }
      return (0, year * 10_000 + month * 100 + date)
    }
    return facts.enumerated().sorted { left, right in
      let a = left.element
      let b = right.element
      if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
      let (ka, kb) = (key(a.day), key(b.day))
      if ka != kb { return ka < kb }
      return left.offset < right.offset
    }.map(\.element)
  }
}

/// A pasted chat or a screenshot's reading, read as turns when its lines
/// start with a name and a colon ("周经理：……"), optionally after a
/// "[10:02] " or "[9月24日 19:28] " time stamp (how the Spark writes a
/// screenshot's messages).
/// Only text that plainly is a conversation qualifies: at least two turns,
/// its first line one of them, and a name that comes back or is the Mac's
/// user (a list of "时间：… / 地点：…" is not a chat). One named line whose
/// name is in `knownNames` (a person of the event) is a turn too. A
/// screenshot's reading may open with one summary line before the messages;
/// pass `leadingSummary` to skip it.
public enum MemoryChatText {
  public struct Turn: Equatable, Sendable {
    public let name: String
    public var text: String

    public init(name: String, text: String) {
      self.name = name
      self.text = text
    }
  }

  private static let speaker = try! NSRegularExpression(
    pattern:
      #"^([^\s\d：:，,。.、；;！!？?（）()\[\]【】「」『』"“”'‘’/<>《》-][^\s：:，,。、；;！!？?（）()\[\]【】「」『』"“”'‘’/<>《》]{0,11})\s*[：:]\s*(\S.*)$"#
  )

  /// Nil when the text does not read as a conversation.
  public static func turns(
    in text: String, ownerNames: Set<String> = MemoryProjection.ownerNames,
    leadingSummary: Bool = false, knownNames: Set<String> = []
  ) -> [Turn]? {
    var lines = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if leadingSummary, let first = lines.first, turn(first) == nil { lines.removeFirst() }
    // One line of someone the event knows: "小刘：林晓，表更新好了".
    if lines.count == 1, let only = turn(lines[0]), knownNames.contains(only.name),
      !ownerNames.contains(only.name.lowercased())
    {
      return [only]
    }
    guard lines.count >= 2 else { return nil }
    var turns: [Turn] = []
    var named = 0
    for line in lines {
      if let turn = turn(line) {
        turns.append(turn)
        named += 1
      } else if !turns.isEmpty {
        turns[turns.count - 1].text += " " + line
      } else {
        return nil
      }
    }
    guard named >= 2 else { return nil }
    let names = turns.map(\.name)
    let repeats = Set(names).count < names.count
    let hasOwner = names.contains { ownerNames.contains($0.lowercased()) }
    return repeats || hasOwner ? turns : nil
  }

  /// "[10:02] ", "[9月24日 19:28] ", "[昨天 19:28] ": a bracketed time,
  /// possibly after a short day.
  static let timeStamp = try! NSRegularExpression(
    pattern: #"^\[[^\[\]]{0,16}?\d{1,2}:\d{2}\]\s*"#)

  private static func turn(_ raw: String) -> Turn? {
    let whole = NSRange(raw.startIndex..., in: raw)
    let line = timeStamp.stringByReplacingMatches(in: raw, range: whole, withTemplate: "")
    let range = NSRange(line.startIndex..., in: line)
    guard let match = speaker.firstMatch(in: line, range: range),
      let name = Range(match.range(at: 1), in: line),
      let rest = Range(match.range(at: 2), in: line)
    else { return nil }
    let who = String(line[name])
    guard !["http", "https", "ftp", "mailto"].contains(who.lowercased()) else { return nil }
    return Turn(name: who, text: String(line[rest]).trimmingCharacters(in: .whitespaces))
  }
}

/// The organizing device's reading of a screenshot, split the way it writes
/// one: a one-line summary of its own (its screenshot reading always has
/// one), then what it read, either the messages as "[time] sender：text"
/// lines or the text. The summary is the device's description, not text in
/// the screenshot, so the pages and the export show it apart from what was
/// read. A reading made on this Mac has no summary. `raw` is kept as sent,
/// for search.
public struct MemoryScreenshotReading: Equatable, Sendable {
  public let raw: String
  /// The device's one-line summary, when it wrote one.
  public let summary: String?
  /// What was read, without the summary; a time stamp that every message
  /// line repeats (the screenshot's one time label) is left out.
  public let body: String

  /// A reading from the organizing device. When it sends its summary apart
  /// (`summary` not nil, `""` for none), `text` is only what was read. From
  /// an older device (`summary` nil), the first of two or more lines is its
  /// summary unless it is itself a time-stamped message.
  public init(organizer text: String, summary sentSummary: String? = nil) {
    raw = text
    var lines = Self.lines(text)
    if let sentSummary {
      let line = Self.lines(sentSummary).joined(separator: " ")
      summary = line.isEmpty ? nil : line
    } else if lines.count >= 2, !Self.isStamped(lines[0]) {
      summary = lines.removeFirst()
    } else {
      summary = nil
    }
    body = Self.withoutRepeatedStamp(lines).joined(separator: "\n")
  }

  /// A reading made on this Mac: no summary.
  public init(local text: String) {
    raw = text
    summary = nil
    body = Self.withoutRepeatedStamp(Self.lines(text)).joined(separator: "\n")
  }

  private static func lines(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  private static func stamp(_ line: String) -> Range<String.Index>? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = MemoryChatText.timeStamp.firstMatch(in: line, range: range) else {
      return nil
    }
    return Range(match.range, in: line)
  }

  private static func isStamped(_ line: String) -> Bool { stamp(line) != nil }

  /// Two or more lines, every one stamped with the same time: that time says
  /// nothing per line, so it goes. Different times stay.
  private static func withoutRepeatedStamp(_ lines: [String]) -> [String] {
    guard lines.count >= 2 else { return lines }
    let stamps = lines.map { line in
      stamp(line).map { line[$0].trimmingCharacters(in: .whitespaces) }
    }
    guard let first = stamps[0], stamps.allSatisfy({ $0 == first }) else { return lines }
    return lines.map { line in
      stamp(line).map { String(line[$0.upperBound...]) } ?? line
    }
  }
}

/// One yes/no question, whichever organizer asked it. The prompt is shown
/// exactly as written.
public struct MemoryQuestion: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// Is this new item part of event `b`? Yes files it there.
    case itemIntoEvent
    /// Item `a` is already in `b`; does it belong? No takes it out.
    case itemStaysInEvent
    /// Are events `a` and `b` one matter? Yes merges `b` into `a`.
    case mergeEvents
    /// Are people `a` and `b` the same person?
    case samePerson
  }

  public enum Origin: Equatable, Sendable {
    /// Asked by the Spark; answered with its question ID.
    case spark
    /// Made on this Mac from a local organizer candidate (its ID).
    case local
  }

  public let questionID: String
  public let kind: Kind
  public let prompt: String
  public let a: String
  public let b: String
  public let createdAt: Date?
  public let origin: Origin

  public init(
    questionID: String, kind: Kind, prompt: String, a: String, b: String,
    createdAt: Date?, origin: Origin
  ) {
    self.questionID = questionID
    self.kind = kind
    self.prompt = prompt
    self.a = a
    self.b = b
    self.createdAt = createdAt
    self.origin = origin
  }

  public var id: String { questionID }

  /// The item the question is about, for item questions.
  public var itemID: String? {
    kind == .itemIntoEvent || kind == .itemStaysInEvent ? a : nil
  }

  /// The two people of a same-person question.
  public var personIDs: [String] { kind == .samePerson ? [a, b] : [] }

  /// An item question that names its item, in the organizer's own words:
  /// 这条「<first 24 characters>」和「<event>」是同一件事吗？
  public static func itemPrompt(itemText: String, eventTitle: String) -> String {
    let flat = itemText.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      .joined(separator: " ")
    let snippet = flat.count > 24 ? String(flat.prefix(23)) + "…" : flat
    let name = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return "这条「\(snippet)」和「\(name.isEmpty ? "那件事" : name)」是同一件事吗？"
  }
}

/// Six voice colours, one per person, stable across launches and Macs: an
/// FNV-1a hash of the person ID (Swift's `hashValue` is seeded per process).
public enum MemoryPersonColor {
  public static let count = 6

  public static func index(for personID: String) -> Int {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in personID.uppercased().utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return Int(hash % UInt64(count))
  }
}

/// Dates as the memory pages write them, in Chinese, independent of the
/// system locale; the calendar (with its time zone) is injected.
public enum MemoryDateText {
  public static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

  /// A position in a recording: `m:ss`, or `h:mm:ss` past an hour.
  public static func clock(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1_000)
    let (h, m, s) = (seconds / 3_600, seconds / 60 % 60, seconds % 60)
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  /// "9月22日", with the year when it is not the current one.
  public static func day(_ date: Date, calendar: Calendar, now: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    let thisYear = calendar.component(.year, from: now)
    let year = parts.year.map { $0 == thisYear ? "" : "\($0)年" } ?? ""
    return "\(year)\(parts.month ?? 0)月\(parts.day ?? 0)日"
  }

  /// "9月22日 周一" for a day header.
  public static func dayHeader(_ date: Date, calendar: Calendar, now: Date) -> String {
    let weekday = calendar.component(.weekday, from: date)
    return "\(day(date, calendar: calendar, now: now)) \(weekdays[(weekday - 1 + 7) % 7])"
  }

  /// "9月22日 – 9月25日", or one day.
  public static func span(_ span: MemoryEventSpan, calendar: Calendar, now: Date) -> String {
    let start = day(span.start, calendar: calendar, now: now)
    guard !calendar.isDate(span.start, inSameDayAs: span.end) else { return start }
    return "\(start) – \(day(span.end, calendar: calendar, now: now))"
  }

  /// "20:14".
  public static func time(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
  }

  /// "3 分 12 秒", "45 秒", "1 小时 2 分".
  public static func duration(nanoseconds: UInt64) -> String {
    let seconds = Int(nanoseconds / 1_000_000_000)
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let rest = seconds % 60
    if hours > 0 { return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时" }
    if minutes > 0 { return rest > 0 ? "\(minutes) 分 \(rest) 秒" : "\(minutes) 分" }
    return "\(max(rest, 1)) 秒"
  }

  /// "9月25日" for a status fact's day.
  public static func factDay(_ components: DateComponents, calendar: Calendar, now: Date) -> String?
  {
    guard let date = calendar.date(from: components) else { return nil }
    return day(date, calendar: calendar, now: now)
  }
}

/// The decision each in-place correction on the memory pages records while
/// the organizing device's events are shown. One place, so the pages and the
/// tests agree on the wire shape.
public enum MemoryDecisions {
  public static func rename(eventID: String, title: String) -> RemoteOrganizerDecision {
    RemoteOrganizerDecision(kind: "rename_event", eventID: eventID, title: title)
  }

  public static func pin(eventID: String, pinned: Bool) -> RemoteOrganizerDecision {
    RemoteOrganizerDecision(kind: "pin_event", eventID: eventID, pinned: pinned)
  }

  public static func featureLess(eventID: String) -> RemoteOrganizerDecision {
    RemoteOrganizerDecision(kind: "feature_less", eventID: eventID)
  }

  /// "这不是这件事的": the item (or only its part `segID`) waits in Unfiled.
  public static func remove(itemID: String, from eventID: String, segID: String? = nil)
    -> RemoteOrganizerDecision
  {
    RemoteOrganizerDecision(kind: "remove_item", eventID: eventID, itemID: itemID, segID: segID)
  }

  /// "移到…" and "放进…" (also files an unfiled item); with `segID` only
  /// that part of the item moves.
  public static func move(itemID: String, to eventID: String, segID: String? = nil)
    -> RemoteOrganizerDecision
  {
    RemoteOrganizerDecision(kind: "move_item", itemID: itemID, toEventID: eventID, segID: segID)
  }

  /// "单独成一件事", under a client ID the overlay and the device share.
  public static func fileAsNewEvent(itemID: String, newEventID: UUID = UUID())
    -> RemoteOrganizerDecision
  {
    RemoteOrganizerDecision(
      kind: "file_item_new_event", itemID: itemID,
      newEventID: newEventID.uuidString.lowercased())
  }

  public static func name(personID: String, name: String) -> RemoteOrganizerDecision {
    RemoteOrganizerDecision(kind: "name_person", personID: personID, displayName: name)
  }

  /// A rope or relation decision (MAP-CONTRACT §2) as it is stored and sent.
  public static func relation(_ decision: MemoryRelationDecision) -> RemoteOrganizerDecision {
    switch decision {
    case .confirmRope(let ropeID):
      RemoteOrganizerDecision(kind: "confirm_rope", ropeID: ropeID)
    case .rejectRope(let ropeID):
      RemoteOrganizerDecision(kind: "reject_rope", ropeID: ropeID)
    case .renameRope(let ropeID, let title):
      RemoteOrganizerDecision(
        kind: "rename_rope", title: title.trimmingCharacters(in: .whitespacesAndNewlines),
        ropeID: ropeID)
    case .moveToRope(let eventID, let ropeID):
      RemoteOrganizerDecision(kind: "move_to_rope", eventID: eventID, ropeID: ropeID)
    case .rejectBlocks(let a, let b):
      RemoteOrganizerDecision(kind: "reject_relation", a: a, b: b, relation: "blocks")
    case .hideCrossing(let a, let b):
      RemoteOrganizerDecision(kind: "hide_crossing", a: a, b: b)
    }
  }
}

/// What the user can say about ropes and relations: confirm or reject a
/// rope, rename it, move a matter to another rope (or none), reject a
/// blocks edge, hide a crossing. User decisions win; a rejected proposal is
/// never proposed again.
public enum MemoryRelationDecision: Equatable, Hashable, Sendable {
  case confirmRope(String)
  case rejectRope(String)
  case renameRope(String, title: String)
  /// The matter goes on the rope; nil puts it on none.
  case moveToRope(eventID: String, ropeID: String?)
  /// `a` blocks `b` (b waits on a) is wrong.
  case rejectBlocks(a: String, b: String)
  case hideCrossing(a: String, b: String)
}
