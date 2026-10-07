import BestASRDomain
import Foundation

/// One entry of a matter's 原文 tab (MAC-SPEC §4.10, §13.6): only the part of
/// a captured item that is about this matter, as speaker lines. The words are
/// the item's own (never autospaced, never rewritten beyond the display
/// guards of §13.3.1: dictation pauses as commas, chat codes as emoji).
public struct MatterTextEntry: Equatable, Identifiable, Sendable {
  /// The 原文 row (`MemoryEventItem.id`: the item, or `item#seg` for one part).
  public let id: String
  /// Upper-case item ID.
  public let itemID: String
  /// The part of the item this matter holds, if only a part.
  public let segID: String?
  public let time: Date
  public let source: MemorySourceWords
  /// Other speakers of a transcript or chat (at most three; never the owner).
  public let people: [String]
  /// A mail's subject line.
  public let subject: String?
  public let lines: [MemoryQuoteLine]
  /// The item goes on past these lines.
  public let more: Bool
  /// The span a step quotes from this item (highlighted), when one does.
  public let quote: String?
  /// The owner's own dictation (口述, 键盘): hidden in a member's view.
  public let ownerSpoken: Bool

  public init(
    id: String, itemID: String, segID: String?, time: Date, source: MemorySourceWords,
    people: [String] = [], subject: String? = nil, lines: [MemoryQuoteLine], more: Bool = false,
    quote: String? = nil, ownerSpoken: Bool = false
  ) {
    self.id = id
    self.itemID = itemID
    self.segID = segID
    self.time = time
    self.source = source
    self.people = people
    self.subject = subject
    self.lines = lines
    self.more = more
    self.quote = quote
    self.ownerSpoken = ownerSpoken
  }

  /// More than two lines, a line over 80 characters, or the item goes on:
  /// clamped to two lines with 「展开」.
  public var isLong: Bool { lines.count > 2 || lines.contains { $0.words.count > 80 } || more }
}

/// The 原文 derivation (`excerpt` in the prototype's builder, v9 文本 rules).
/// Pure: the same items and matter give the same entries.
public enum MatterTexts {
  /// What makes a clause about the matter: Latin words of its title, status,
  /// steps, facts and parts; Chinese chunks (2+) of its title and part
  /// names; the people its steps name (and their given names).
  public struct Terms: Equatable, Sendable {
    public var latin: Set<String>
    public var cjk: Set<String>

    public init(latin: Set<String>, cjk: Set<String>) {
      self.latin = latin
      self.cjk = cjk
    }

    public func matches(_ clause: String) -> Bool {
      latin.contains { clause.contains($0) } || cjk.contains { clause.contains($0) }
    }
  }

  static let stopLatin: Set<String> = [
    "the", "and", "for", "with", "ok", "hi", "re", "draft", "of", "to", "is", "in", "on",
  ]

  public static func terms(of matter: MatterDigest) -> Terms {
    let words = [matter.title, matter.status] + matter.steps.map(\.text) + matter.facts.map(\.text)
    let names = matter.parts.map(\.name)
    let latin = Set(
      MemoryDisplayText.matches(#"[A-Za-z][A-Za-z0-9]{1,}"#, in: (words + names).joined(separator: " "))
        .filter { !stopLatin.contains($0.lowercased()) })
    var cjk = Set<String>()
    for name in names + [matter.title] {
      let pieces = MemoryDisplayText.replace(#"[与和及、\s]|[A-Za-z0-9]+"#, in: name) { _ in "\u{1}" }
      for piece in pieces.split(separator: "\u{1}") where piece.count >= 2 {
        cjk.insert(String(piece))
      }
    }
    for step in matter.steps {
      for who in step.who where !who.isEmpty {
        cjk.insert(who)
        if who.count == 3 { cjk.insert(String(who.dropFirst())) }
      }
    }
    return Terms(latin: latin, cjk: cjk)
  }

  /// Clauses: split after 。！？；and line ends, then at commas and before
  /// 然后 / 还有哦对 / 对了 / 另外 / 不过; end punctuation dropped.
  static func clauses(_ text: String) -> [String] {
    var out: [String] = []
    var sentence = ""
    func flushSentence() {
      let marked = MemoryDisplayText.replace(#"[，,]|(?=然后|还有哦对|对了|另外|不过)"#, in: sentence) { _ in
        "\u{1}"
      }
      for piece in marked.split(separator: "\u{1}") {
        let clause = piece.trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?；"))
          .trimmingCharacters(in: .whitespaces)
        if !clause.isEmpty { out.append(clause) }
      }
      sentence = ""
    }
    for character in text {
      sentence.append(character)
      if "。！？!?；\n".contains(character) { flushSentence() }
    }
    flushSentence()
    return out
  }

  /// The first run of clauses about the matter, joined with 「，」 and ended
  /// with 「。」, at most `maxCharacters` long (the first clause always).
  public static func relevantPart(_ text: String, terms: Terms, maxCharacters: Int = 110) -> String? {
    let all = clauses(text)
    guard let first = all.firstIndex(where: terms.matches) else { return nil }
    var out: [String] = []
    var index = first
    while index < all.count, terms.matches(all[index]) {
      let next = (out + [all[index]]).joined(separator: "，")
      if !out.isEmpty, next.count > maxCharacters { break }
      out.append(all[index])
      index += 1
    }
    return out.joined(separator: "，") + "。"
  }

  /// A full stop followed by stray punctuation is tidied (「。，」 → 「。」).
  /// 「：，」 and a trailing 「：。」 (a heading line joined to its body) too.
  static func tidy(_ text: String) -> String {
    var s = MemoryDisplayText.replace(#"([。！？!?])\s*[。，、,]+"#, in: text) { groups in groups[1] }
    s = MemoryDisplayText.replace(#"[：:]\s*[，,]"#, in: s) { _ in "：" }
    s = MemoryDisplayText.replace(#"[：:]\s*。$"#, in: s) { _ in "。" }
    return s
  }

  static let shellCommand = #"^\s*(cd|ls|git|python3?|ssh|nvidia-smi|conda|pip)\b"#

  /// The excerpt of one item; nil when nothing in it is about the matter
  /// (`fallback` false) or it is a shell command.
  static func excerpt(
    text raw: String, speakerLines: [Turn]?, source: MemorySourceWords,
    terms: Terms, owners: Set<String>, fallback: Bool
  ) -> (lines: [MemoryQuoteLine], more: Bool, people: [String], subject: String?)? {
    let text = raw.replacingOccurrences(of: MemoryQuoteLines.watermark, with: "")
    if !MemoryDisplayText.matches(shellCommand, in: text).isEmpty || text.prefix(200).contains("/home/") {
      return nil
    }
    func me(_ name: String?) -> String {
      guard let name, !name.isEmpty else { return "" }
      return owners.contains(name) || owners.contains(name.lowercased()) ? "我" : name
    }
    func plain(_ words: String) -> [MemoryQuoteLine] {
      [MemoryQuoteLine(speaker: "", words: MemoryQuoteLines.withEmoji(words))]
    }
    // Claude / Codex: the prompt prefix and markdown marks go.
    if source.word == "Claude" || source.word == "Codex" {
      var body = MemoryDisplayText.replace(
        #"^(?i:claude|codex)[^：\n]*：\s*"#, in: text.trimmingCharacters(in: .whitespacesAndNewlines)
      ) { _ in "" }
      body = MemoryDisplayText.replace(#"[#*`>]+"#, in: body) { _ in "" }
      let flat = body.replacingOccurrences(of: "\n", with: "。")
      if let part = relevantPart(flat, terms: terms) { return (plain(tidy(part)), false, [], nil) }
      return fallback ? (plain(String(flat.prefix(110))), flat.count > 110, [], nil) : nil
    }
    // Mail: headers and greetings go; the subject is kept.
    if source.word == "邮件" {
      let subject = MemoryDisplayText.allGroups(#"(?m)^Subject:\s*(.+)$"#, in: text).first?[1]
        .trimmingCharacters(in: .whitespaces)
      let raw = text.split(whereSeparator: \.isNewline).map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }
      let body = raw.filter {
        MemoryDisplayText.matches(#"^(From|To|Cc|Date|Subject):"#, in: $0).isEmpty
          && MemoryDisplayText.matches(#"^(Hi|Dear|Hello)\b.*,$"#, in: $0).isEmpty
      }
      let prose = body.joined(separator: " ")
      let part = tidy(relevantPart(prose, terms: terms) ?? String(prose.prefix(110)))
      return (plain(part), false, [], subject?.isEmpty == false ? subject : nil)
    }
    let lines =
      speakerLines
      ?? MemoryQuoteLines.lines(text).map { Turn(speaker: $0.speaker, words: $0.words) }
    if lines.contains(where: { ($0.speaker ?? "").isEmpty == false }) {
      let relevant = lines.indices.filter { relevantPart(lines[$0].words, terms: terms) != nil }
      guard let first = relevant.first ?? (fallback ? 0 : nil) else { return nil }
      let start = max(0, first - (relevant.isEmpty ? 0 : 1))
      let shown = lines[start..<min(lines.count, start + 3)].map {
        MemoryQuoteLine(
          speaker: me($0.speaker), words: MemoryQuoteLines.withEmoji($0.words), voice: $0.voice)
      }
      var people: [String] = []
      for line in lines {
        let name = me(line.speaker)
        if !name.isEmpty, name != "我", !people.contains(name) { people.append(name) }
      }
      return (shown, lines.count > start + 3, Array(people.prefix(3)), nil)
    }
    var prose = lines.map(\.words).joined(separator: " ")
    if source.word == "口述" || source.word == "键盘" { prose = MemoryQuoteLines.punctuated(prose) }
    if let part = relevantPart(prose, terms: terms, maxCharacters: 150) {
      return (plain(tidy(part)), false, [], nil)
    }
    guard fallback else { return nil }
    return (plain(String(prose.prefix(150))), prose.count > 150, [], nil)
  }

  /// One line of an item: who said it and the words, and where it is in a
  /// recording when it was heard.
  struct Turn: Equatable {
    var speaker: String?
    var words: String
    var voice: MemoryQuoteVoice? = nil
  }

  /// A recording's sentences with their speakers (names as the matter
  /// shows them: 「没起名 N」 for a voice nobody named): all of them for a
  /// recording held whole with more than one sentence; for a part, the
  /// sentences overlapping it (one is enough). Nil for anything else, and
  /// when the part cannot be placed in the sentences (a text edited after
  /// it was split).
  static func speakerTurns(_ item: MemoryEventItem, record: MemoryItemRecord) -> [Turn]? {
    let segments = record.segments
    guard segments.contains(where: { $0.personID != nil || $0.personName != nil }) else {
      return nil
    }
    let chosen: [MemoryItemRecord.Segment]
    if let part = item.segment {
      // A pasted chat's part keeps its own 「名：」 lines.
      guard record.inputMode != .userItem, let text = record.text,
        let ranges = MemoryTranscriptText.sentenceRanges(text, sentences: segments.map(\.text))
      else { return nil }
      chosen = zip(segments, ranges)
        .filter { $0.1.lowerBound < part.end && $0.1.upperBound > part.start }
        .map(\.0)
      guard chosen.contains(where: { $0.personID != nil }) else { return nil }
    } else {
      guard segments.count > 1 else { return nil }
      chosen = segments
    }
    let itemID = record.sessionID.rawValue.uuidString
    return chosen.compactMap { segment in
      let words = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !words.isEmpty else { return nil }
      let key = segment.personID?.rawValue.uuidString.uppercased()
      let name = key.flatMap { item.speakerNames[$0] } ?? segment.personName
      var voice: MemoryQuoteVoice?
      if record.playbackAvailable, let key, let start = segment.monotonicStartNanoseconds,
        let end = segment.monotonicEndNanoseconds, end > start
      {
        voice = MemoryQuoteVoice(itemID: itemID, personID: key, start: start, end: end)
      }
      return Turn(speaker: name, words: words, voice: voice)
    }
  }

  /// The 原文 of a matter, newest first. Items with nothing about the matter
  /// are left out, except the ones a step quotes and `keep` (a revealed
  /// row); when nothing at all is about it, every item shows its start.
  public static func entries(
    matter: MatterDigest, items: [MemoryEventItem], ownerNames: Set<String>, keep: Set<String> = []
  ) -> [MatterTextEntry] {
    let terms = terms(of: matter)
    let quoted = Dictionary(
      matter.steps.compactMap { step -> (String, String)? in
        guard let evidence = step.evidence else { return nil }
        return (evidence.itemID, evidence.quote)
      }, uniquingKeysWith: { a, b in a.isEmpty ? b : a })
    func build(_ fallbackAll: Bool) -> [MatterTextEntry] {
      var out: [MatterTextEntry] = []
      var seen = Set<String>()
      for item in items {
        guard let record = item.record, !record.isKeyframe, seen.insert(item.id).inserted else {
          continue
        }
        let key = item.itemID.uppercased()
        let source = MemoryItemSource.words(record)
        let text =
          item.shownText?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
          ?? item.reading?.body.nonEmpty ?? record.localReading?.nonEmpty ?? ""
        guard !text.isEmpty, text != UserItemLimits.noTextLayerPlaceholder else { continue }
        // A recording's own speakers, when the Mac transcribed it in turns;
        // for a part of it (a meeting split across matters) the sentences
        // of that part, so 「谁说的」 stays (理3-5).
        let turns = speakerTurns(item, record: record)
        let mustKeep = fallbackAll || quoted[key] != nil || keep.contains(item.id)
        guard
          let found = excerpt(
            text: text, speakerLines: turns, source: source, terms: terms, owners: ownerNames,
            fallback: mustKeep)
        else { continue }
        let quote = quoted[key].flatMap { quote -> String? in
          guard !quote.isEmpty, found.lines.contains(where: { $0.words.contains(quote) }) else {
            return nil
          }
          return quote
        }
        out.append(
          MatterTextEntry(
            id: item.id, itemID: key, segID: item.segment?.segID, time: record.startedAt,
            source: source, people: found.people, subject: found.subject, lines: found.lines,
            more: found.more, quote: quote,
            ownerSpoken: source.word == "口述" || source.word == "键盘"))
      }
      return out.sorted { ($0.time, $0.id) > ($1.time, $1.id) }
    }
    let entries = build(false)
    if entries.isEmpty, items.contains(where: { $0.record != nil }) { return build(true) }
    return entries
  }
}

extension MemoryProjection {
  /// The matter's 原文 entries (§4.10), from the items it holds on this Mac.
  public func matterTexts(
    _ matter: MatterDigest, ownerNames: [String] = [], keep: Set<String> = []
  ) -> [MatterTextEntry] {
    guard let detail = event(id: matter.eventID) else { return [] }
    let owners = Set(MemoryDigest.ownerNames(projection: self, extra: ownerNames))
      .union(MemoryProjection.ownerNames)
    return MatterTexts.entries(matter: matter, items: detail.items, ownerNames: owners, keep: keep)
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
