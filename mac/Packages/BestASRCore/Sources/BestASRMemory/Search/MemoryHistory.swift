import BestASRDomain
import Foundation

/// One record as the 历史 page shows it (ALIGNMENT 查-1, 查-7): when, from
/// where, in which matter, its words (near the hit when searching), and
/// whether it can be played from the sentence that matched.
public struct MemoryHistoryRow: Equatable, Identifiable, Sendable {
  /// Upper-case item (session) ID.
  public let itemID: String
  public let time: Date
  /// 「口述」「微信」「会议」…
  public let source: String
  public let symbol: String
  /// The matter that holds it, if any.
  public let eventID: String?
  public let matterTitle: String?
  /// The words shown (two lines at most; from the hit's line when searching).
  public let line: String
  /// `line` starts after the record's start (its first words fade in).
  public let cutBefore: Bool
  /// Everything the record says (copy, share, 加进词典, 展开).
  public let fullText: String
  public let playable: Bool
  /// Where the matched sentence starts on the recording's clock; nil plays
  /// from the start.
  public let playFrom: UInt64?
  /// 「1 分 12 秒」 for a recording.
  public let duration: String?
  /// Holds only some of the words searched for.
  public let partial: Bool
  /// Words in this record that sound like a typed word (穹顶 for 穹鼎), lit
  /// as hits too.
  public var soundAlikes: [String] = []

  public var id: String { itemID }

  public init(
    itemID: String, time: Date, source: String, symbol: String, eventID: String?,
    matterTitle: String?, line: String, cutBefore: Bool = false, fullText: String,
    playable: Bool = false, playFrom: UInt64? = nil, duration: String? = nil, partial: Bool = false
  ) {
    self.itemID = itemID
    self.time = time
    self.source = source
    self.symbol = symbol
    self.eventID = eventID
    self.matterTitle = matterTitle
    self.line = line
    self.cutBefore = cutBefore
    self.fullText = fullText
    self.playable = playable
    self.playFrom = playFrom
    self.duration = duration
    self.partial = partial
  }
}

/// A matter that answers the query (「事」).
public struct MemoryHistoryMatter: Equatable, Identifiable, Sendable {
  public let eventID: String
  public let title: String
  /// The line that matched (status, a step, a part, or the people).
  public let why: String

  public var id: String { eventID }

  public init(eventID: String, title: String, why: String) {
    self.eventID = eventID
    self.title = title
    self.why = why
  }
}

/// The 历史 page: every record by day when nothing is typed, else what the
/// query found, grouped 事 · 人 · 原话 (B4 §3.4–§3.5).
public struct MemoryHistoryState: Equatable, Sendable {
  /// The words these results are for ("" is the whole history).
  public var query: String
  /// Conditions read out of the query (grey chips, one click removes one).
  public var chips: [SearchChip]
  /// Records come newest first, under day headers (nothing to rank by).
  public var ordersByTime: Bool
  public var matters: [MemoryHistoryMatter]
  /// Person IDs (the projection's) named by the query.
  public var personIDs: [String]
  public var rows: [MemoryHistoryRow]
  /// How many records match in all (nil while counting).
  public var total: Int?
  public var hasMore: Bool
  public var loading: Bool
  /// Spellings to highlight in the rows.
  public var highlights: [String]
  /// Nothing found: what each condition left out would find (「不限「上周」有
  /// 362 条」), the query without it.
  public var widen: [MemoryHistoryWiden] = []

  public init(
    query: String = "", chips: [SearchChip] = [], ordersByTime: Bool = true,
    matters: [MemoryHistoryMatter] = [], personIDs: [String] = [], rows: [MemoryHistoryRow] = [],
    total: Int? = nil, hasMore: Bool = false, loading: Bool = false, highlights: [String] = []
  ) {
    self.query = query
    self.chips = chips
    self.ordersByTime = ordersByTime
    self.matters = matters
    self.personIDs = personIDs
    self.rows = rows
    self.total = total
    self.hasMore = hasMore
    self.loading = loading
    self.highlights = highlights
  }
}

/// One way to find more when nothing was found: the query without one of
/// its conditions, and how many records that finds.
public struct MemoryHistoryWiden: Equatable, Identifiable, Sendable {
  public let chip: SearchChip
  public let query: String
  public let count: Int

  public var id: String { chip.id }

  public init(chip: SearchChip, query: String, count: Int) {
    self.chip = chip
    self.query = query
    self.count = count
  }
}

/// Builds the page's values from the store's records and the read model.
/// Pure; the App calls it off the main thread.
public enum MemoryHistoryBuilder {
  /// One row. `query` nil (or with no words) shows the record's start;
  /// else the line of its first hit, and the sentence to play from. `near`
  /// is the piece the meaning search found closest (v12 search): when none
  /// of the words are in the record, the row shows and plays from there.
  public static func row(
    _ record: MemoryItemRecord, query: SearchQuery?, matter: (eventID: String, title: String)?,
    partial: Bool = false, near: String? = nil
  ) -> MemoryHistoryRow {
    let source = MemoryItemSource.words(record)
    let text = shownText(record)
    // A meeting App's transcript reads 「名字：话」 in the row, not its file
    // marks (v12 integration: 收进会议记录 items now show in 历史).
    let shown = MemoryTranscriptText.readable(text) ?? text
    let alike = query.map { soundAlikes(shown, query: $0) } ?? []
    let highlights = query?.units.isEmpty == false ? query!.highlights + alike : []
    let nearKeys = nearKeys(near)
    let (line, cut) = snippet(shown, highlights: highlights + nearKeys)
    var playFrom: UInt64?
    if record.playbackAvailable, !highlights.isEmpty || !nearKeys.isEmpty {
      let keys = (highlights + nearKeys).map(SearchText.normalize).filter { !$0.isEmpty }
      playFrom =
        record.segments.first { segment in
          let words = SearchText.normalize(segment.text)
          return keys.contains { words.contains($0) }
        }?.monotonicStartNanoseconds
    }
    var row = MemoryHistoryRow(
      itemID: record.sessionID.rawValue.uuidString.uppercased(), time: record.startedAt,
      source: source.app.isEmpty ? source.word : source.app, symbol: source.symbol,
      eventID: matter?.eventID, matterTitle: matter?.title, line: line, cutBefore: cut,
      fullText: text, playable: record.playbackAvailable, playFrom: playFrom,
      duration: record.playbackAvailable
        ? record.durationNanoseconds.map { MemoryDateText.duration(nanoseconds: $0) } : nil,
      partial: partial)
    row.soundAlikes = alike
    return row
  }

  /// Where the closest piece starts, as keys to find its line: its first
  /// words up to a sentence end (at most 12 characters).
  public static func nearKeys(_ near: String?) -> [String] {
    guard let near else { return [] }
    let line = near.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    var key = ""
    for character in line {
      if "。！？!?；;".contains(character) || key.count >= 12 { break }
      key.append(character)
    }
    key = key.trimmingCharacters(in: .whitespaces)
    return key.count >= 2 ? [key] : []
  }

  /// The places in `text` that sound like a typed Han word but are written
  /// otherwise (the pinyin match of a homophone typo), as written there.
  public static func soundAlikes(_ text: String, query: SearchQuery, limit: Int = 8_000)
    -> [String]
  {
    let plain = SearchText.normalize(String(text.prefix(limit)))
    // Only words the record does not hold as typed (a typo or another
    // spelling of the same sound).
    let targets = query.units.compactMap { unit -> [String]? in
      guard !plain.contains(unit.text) else { return nil }
      let scalars = Array(unit.text.unicodeScalars)
      guard scalars.count >= 2, scalars.allSatisfy(SearchText.isHan) else { return nil }
      let syllables = scalars.map(SearchText.pinyin)
      return syllables.allSatisfy({ !$0.isEmpty }) ? syllables : nil
    }
    guard !targets.isEmpty else { return [] }
    let characters = Array(text.prefix(limit))
    let readings = characters.map { character -> String in
      guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
        SearchText.isHan(scalar)
      else { return "" }
      return SearchText.pinyin(HanReadingsBridge.simplified(scalar))
    }
    var found: [String] = []
    for target in targets where target.count <= characters.count {
      for start in 0...(characters.count - target.count) {
        guard readings[start] == target[0] else { continue }
        if Array(readings[start..<(start + target.count)]) == target {
          let word = String(characters[start..<(start + target.count)])
          if !found.contains(word) { found.append(word) }
        }
      }
    }
    return found
  }

  /// What a record says: the delivered (cleaned-up) dictation, else its
  /// text, else a screenshot's reading.
  public static func shownText(_ record: MemoryItemRecord) -> String {
    let text = record.deliveredText ?? record.text ?? record.localReading ?? ""
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The line holding the first highlight, starting about 20 characters
  /// before it when it is long; the text's start when nothing matches.
  public static func snippet(_ text: String, highlights: [String]) -> (String, Bool) {
    let flat = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard !highlights.isEmpty else {
      let first = flat.split(separator: "\n", omittingEmptySubsequences: true).prefix(2)
        .joined(separator: " ")
      return (first.isEmpty ? flat : first, false)
    }
    let lines = flat.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    for line in lines {
      for key in highlights {
        guard
          let range = line.range(
            of: key, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive])
        else { continue }
        let at = line.distance(from: line.startIndex, to: range.lowerBound)
        guard line.count > 90, at > 30 else { return (line, false) }
        var start = line.index(range.lowerBound, offsetBy: -20)
        while start < range.lowerBound, line[start].isWhitespace || line[start].isPunctuation {
          start = line.index(after: start)
        }
        return (String(line[start...]), true)
      }
    }
    return (lines.first ?? flat, false)
  }

  /// Matters whose title, status, steps, parts or people hold every word
  /// (and every person named), title hits first.
  public static func matters(_ query: SearchQuery, digest: MemoryDigest?) -> [MemoryHistoryMatter] {
    guard let digest, !query.units.isEmpty else { return [] }
    let personNames = query.people.map { Set($0.spellings) }
    var titled: [MemoryHistoryMatter] = []
    var others: [MemoryHistoryMatter] = []
    for matter in digest.matters {
      let names = matter.people.map(\.name)
      guard
        personNames.allSatisfy({ spellings in names.contains(where: spellings.contains) })
      else { continue }
      let all =
        [matter.title, matter.status] + matter.steps.map(\.text) + matter.parts.map(\.name)
        + names
      guard query.matches(SearchTokens(all.joined(separator: "\n"))) else { continue }
      if query.matches(SearchTokens(matter.title)) {
        titled.append(
          MemoryHistoryMatter(eventID: matter.eventID, title: matter.title, why: matter.status))
        continue
      }
      let why =
        [matter.status].first { query.matchCount(SearchTokens($0)) > 0 }
        ?? matter.steps.map(\.text).first { query.matchCount(SearchTokens($0)) > 0 }
        ?? matter.parts.map(\.name).first { query.matchCount(SearchTokens($0)) > 0 }
        ?? names.joined(separator: "、")
      others.append(MemoryHistoryMatter(eventID: matter.eventID, title: matter.title, why: why))
    }
    return titled + others
  }

  /// The people a query names, or whose name holds one of its words.
  public static func people(_ query: SearchQuery, people: [MemoryPersonEntry]) -> [String] {
    var ids = query.people.compactMap { named in
      people.first { $0.personID.caseInsensitiveCompare(named.id) == .orderedSame }?.personID
    }
    guard !query.units.isEmpty else { return ids }
    for person in people where person.isNamed && !ids.contains(person.personID) {
      if query.units.contains(where: { SearchTokens(person.name).contains($0) }) {
        ids.append(person.personID)
      }
    }
    return ids
  }

  /// Item → the matter holding it (the first in Home order).
  public static func matterIndex(_ digest: MemoryDigest?) -> [String: (
    eventID: String, title: String
  )] {
    var index: [String: (eventID: String, title: String)] = [:]
    for matter in digest?.matters ?? [] {
      for item in matter.itemIDs where index[item.uppercased()] == nil {
        index[item.uppercased()] = (matter.eventID, matter.title)
      }
    }
    return index
  }

  /// Rows under day headers (product calendar), in the rows' order.
  public static func days(_ rows: [MemoryHistoryRow], calendar: Calendar) -> [MemoryHistoryDay] {
    var out: [MemoryHistoryDay] = []
    for row in rows {
      let day = calendar.startOfDay(for: row.time)
      if out.last?.day == day {
        out[out.count - 1].rows.append(row)
      } else {
        out.append(MemoryHistoryDay(day: day, rows: [row]))
      }
    }
    return out
  }
}

/// One day of the history (its midnight, its rows).
public struct MemoryHistoryDay: Equatable, Identifiable, Sendable {
  public let day: Date
  public var rows: [MemoryHistoryRow]
  public var id: Date { day }
}
