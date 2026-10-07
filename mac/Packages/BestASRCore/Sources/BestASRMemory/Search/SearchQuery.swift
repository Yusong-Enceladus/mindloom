import Foundation

/// A person the query may name (the organizer's people and the library's).
public struct SearchPerson: Equatable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let aliases: [String]

  public init(id: String, name: String, aliases: [String] = []) {
    self.id = id
    self.name = name
    self.aliases = aliases
  }

  /// Every spelling of the person (name first).
  public var spellings: [String] { [name] + aliases }
}

/// One dictionary word: how it is written, and how it tends to be heard.
public struct SearchLexiconEntry: Equatable, Hashable, Sendable {
  public let canonical: String
  public let spoken: [String]

  public init(canonical: String, spoken: [String]) {
    self.canonical = canonical
    self.spoken = spoken
  }

  public var forms: [String] { [canonical] + spoken }
}

/// What the query may refer to, besides words.
public struct SearchContext: Sendable {
  public var people: [SearchPerson]
  /// The owner's own names: never a condition (every record is theirs).
  public var ownerNames: Set<String>
  public var lexicon: [SearchLexiconEntry]
  /// Source names seen in the library (「Overleaf」…), recognized when typed
  /// as a word of their own.
  public var sourceNames: [String]
  public var clock: SearchClock

  public init(
    people: [SearchPerson] = [], ownerNames: Set<String> = [], lexicon: [SearchLexiconEntry] = [],
    sourceNames: [String] = [], clock: SearchClock = SearchClock()
  ) {
    self.people = people
    self.ownerNames = ownerNames
    self.lexicon = lexicon
    self.sourceNames = sourceNames
    self.clock = clock
  }
}

/// A condition read from the query, shown as a grey chip under the title;
/// one click removes it (its words leave the search field).
public struct SearchChip: Equatable, Hashable, Identifiable, Sendable {
  public enum Kind: Equatable, Hashable, Sendable {
    case person(id: String)
    case source
    case time
  }

  public let kind: Kind
  public let label: String
  /// The words in the normalized query that made it.
  public let text: String

  public var id: String { "\(kind)|\(text)" }
}

/// One piece of a search index match: what must appear (B4 §3.2a).
public enum SearchAtom: Equatable, Hashable, Sendable {
  /// Two-character grams in a row (body, title or people).
  case grams([String])
  /// One Han character.
  case character(String)
  /// Pinyin grams in a row.
  case pinyin([String])
  /// One word; `prefix` while it is still being typed.
  case word(String, prefix: Bool)
}

/// One way of writing a query word: all atoms together.
public struct SearchForm: Equatable, Hashable, Sendable {
  public let atoms: [SearchAtom]
}

/// One word of the query, with every form that counts as it (the words as
/// typed, how they sound, the dictionary's other spellings).
public struct SearchUnit: Equatable, Hashable, Sendable {
  /// As typed (normalized).
  public let text: String
  public let forms: [SearchForm]
  /// Spellings to highlight in a hit.
  public let highlights: [String]
}

/// A parsed query: content words plus the conditions read out of it.
public struct SearchQuery: Equatable, Sendable {
  public let raw: String
  /// The query normalized (what chips refer to).
  public let normalized: String
  public let units: [SearchUnit]
  /// Words typed next to each other, as one run (「叠 衣服」, 「Robo Prior」):
  /// records that hold them together come first.
  public let phrases: [SearchForm]
  /// The same runs as typed (normalized), for highlighting.
  public let phraseTexts: [String]
  public let people: [SearchPerson]
  public let sources: [SearchSourceFilter]
  public let interval: DateInterval?
  public let chips: [SearchChip]

  /// Nothing to rank by: the list is in time order (only time, source or
  /// person, or nothing at all).
  public var ordersByTime: Bool { units.isEmpty }

  public var isEmpty: Bool { units.isEmpty && people.isEmpty && sources.isEmpty && interval == nil }

  /// The spellings to highlight in a hit (longest first).
  public var highlights: [String] {
    var seen = Set<String>()
    let all = phraseTexts + units.flatMap(\.highlights) + people.flatMap(\.spellings)
    return all.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
      .sorted { $0.count > $1.count }
  }

  // MARK: - FTS5

  /// The index match: every content word, and each named person (by name,
  /// alias or voice). `any` matches records with any of the words instead
  /// (the fallback when all of them together find little). Nil when there is
  /// nothing to match.
  public func match(any: Bool = false) -> String? {
    var parts = units.map(Self.render)
    if any, parts.count > 1 { parts = ["(" + parts.joined(separator: " OR ") + ")"] }
    parts += people.map(Self.render)
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " AND ")
  }

  /// Every word, with the words typed together also together in the record.
  /// Nil when no words were typed together.
  public var phraseMatch: String? {
    guard !phrases.isEmpty, let all = match() else { return nil }
    return ([all] + phrases.map(Self.render)).joined(separator: " AND ")
  }

  /// All words but (any) one, with the people: the middle step between
  /// every word and any word, for three words or more.
  public var mostMatch: String? {
    guard units.count >= 3 else { return nil }
    let rendered = units.map(Self.render)
    let combinations = rendered.indices.map { skip in
      "("
        + rendered.enumerated().filter { $0.offset != skip }.map(\.element)
        .joined(separator: " AND ") + ")"
    }
    return (["(" + combinations.joined(separator: " OR ") + ")"] + people.map(Self.render))
      .joined(separator: " AND ")
  }

  /// Only the people part (time-ordered lists that name a person).
  public var peopleMatch: String? {
    let parts = people.map(Self.render)
    return parts.isEmpty ? nil : parts.joined(separator: " AND ")
  }

  static let textColumns = "{body meta people}"

  static func render(_ unit: SearchUnit) -> String {
    "(" + unit.forms.map(render).joined(separator: " OR ") + ")"
  }

  /// A person: any spelling of the name, as written (never by sound: two
  /// names that sound alike are two people).
  static func render(_ person: SearchPerson) -> String {
    var forms: [SearchForm] = []
    for spelling in person.spellings {
      guard let written = SearchQueryParser.forms(of: spelling, prefix: false).first,
        !forms.contains(written)
      else { continue }
      forms.append(written)
    }
    return "(" + forms.map(render).joined(separator: " OR ") + ")"
  }

  static func render(_ form: SearchForm) -> String {
    let atoms = form.atoms.map(render)
    return atoms.count == 1 ? atoms[0] : "(" + atoms.joined(separator: " AND ") + ")"
  }

  static func render(_ atom: SearchAtom) -> String {
    switch atom {
    case .grams(let grams): return "\(textColumns) : \(quote(grams.joined(separator: " ")))"
    case .character(let c): return "{uni} : \(quote(c))"
    case .pinyin(let grams): return "{pin} : \(quote(grams.joined(separator: " ")))"
    case .word(let word, let prefix):
      return "\(textColumns) : \(quote(word))" + (prefix ? " *" : "")
    }
  }

  static func quote(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  // MARK: - In memory

  /// Whether a text (a matter's title and steps, a name) holds every content
  /// word, by the index's rules.
  public func matches(_ tokens: SearchTokens) -> Bool {
    !units.isEmpty && units.allSatisfy { tokens.contains($0) }
  }

  /// How many content words a text holds.
  public func matchCount(_ tokens: SearchTokens) -> Int {
    units.filter { tokens.contains($0) }.count
  }
}

/// A text's index tokens as arrays, for matching in memory.
public struct SearchTokens: Sendable {
  let body: [String]
  let uni: Set<String>
  let pin: [String]

  public init(_ text: String) {
    let indexed = SearchText.indexTokens(text)
    body = indexed.body.split(separator: " ").map(String.init)
    uni = Set(indexed.uni.split(separator: " ").map(String.init))
    pin = indexed.pin.split(separator: " ").map(String.init)
  }

  public func contains(_ unit: SearchUnit) -> Bool {
    unit.forms.contains { form in form.atoms.allSatisfy(contains) }
  }

  /// Whether the text holds one form: all its atoms (words typed together,
  /// `SearchQuery.phrases`).
  public func contains(_ form: SearchForm) -> Bool {
    form.atoms.allSatisfy { contains($0) }
  }

  /// Whether the text names a person: any spelling, as written (never by
  /// sound, as `SearchQuery.render(person)` matches the index).
  public func mentions(_ person: SearchPerson) -> Bool {
    person.spellings.contains { spelling in
      guard let written = SearchQueryParser.forms(of: spelling, prefix: false).first else {
        return false
      }
      return contains(written)
    }
  }

  func contains(_ atom: SearchAtom) -> Bool {
    switch atom {
    case .grams(let grams): return Self.has(body, run: grams)
    case .character(let c): return uni.contains(c)
    case .pinyin(let grams): return Self.has(pin, run: grams)
    case .word(let word, let prefix):
      return prefix ? body.contains { $0.hasPrefix(word) } : body.contains(word)
    }
  }

  static func has(_ haystack: [String], run: [String]) -> Bool {
    guard !run.isEmpty, run.count <= haystack.count else { return false }
    for start in 0...(haystack.count - run.count) where haystack[start] == run[0] {
      if Array(haystack[start..<(start + run.count)]) == run { return true }
    }
    return false
  }
}

/// Reads a query: time words, people and sources become conditions (chips);
/// what is left becomes content words, with their sounds and dictionary
/// spellings (B4 §3.2c). Rules only, no model; well under a millisecond.
public enum SearchQueryParser {
  public static func parse(_ raw: String, context: SearchContext) -> SearchQuery {
    let normalized = SearchText.normalize(raw)
    var chars = Array(normalized)
    var chips: [SearchChip] = []

    // Time words.
    let times = SearchTimeWords.find(in: normalized, clock: context.clock)
    var interval: DateInterval?
    for time in times {
      chips.append(SearchChip(kind: .time, label: time.label, text: time.text))
      interval =
        interval.map {
          $0.intersection(with: time.interval)
            ?? DateInterval(start: time.interval.start, duration: 0)
        } ?? time.interval
      for index in time.range { chars[index] = SearchQueryParser.gap }
    }

    // People, longest spelling first; the owner is never a condition.
    let owners = Set(context.ownerNames.map(SearchText.normalize))
    var spellings: [(String, SearchPerson)] = []
    for person in context.people {
      for spelling in person.spellings {
        let key = SearchText.normalize(spelling).trimmingCharacters(in: .whitespaces)
        guard key.count >= 2, !owners.contains(key), !stopwords.contains(key) else { continue }
        spellings.append((key, person))
      }
    }
    spellings.sort { $0.0.count > $1.0.count }
    var people: [SearchPerson] = []
    for (key, person) in spellings {
      while let at = find(
        key, in: chars, wholeWord: key.unicodeScalars.allSatisfy { !SearchText.isHan($0) })
      {
        if !people.contains(person) {
          people.append(person)
          chips.append(SearchChip(kind: .person(id: person.id), label: person.name, text: key))
        }
        for index in at..<(at + key.count) { chars[index] = gap }
      }
    }

    // Sources.
    var sources: [SearchSourceFilter] = []
    var words: [(String, Bool, SearchSourceFilter)] = SearchSources.words.flatMap { word in
      word.spellings.map { (SearchText.normalize($0), word.generic, word.filter) }
    }
    let known = Set(words.map(\.0))
    for name in context.sourceNames {
      let key = SearchText.normalize(name)
      guard key.count >= 2, !known.contains(key) else { continue }
      words.append((key, true, SearchSourceFilter(label: name, names: [name])))
    }
    words.sort { $0.0.count > $1.0.count }
    for (key, generic, filter) in words {
      let latin = key.unicodeScalars.allSatisfy { !SearchText.isHan($0) }
      while let at = find(key, in: chars, wholeWord: latin, standalone: generic) {
        if !sources.contains(filter) {
          sources.append(filter)
          chips.append(SearchChip(kind: .source, label: filter.label, text: key))
        }
        for index in at..<(at + key.count) { chars[index] = gap }
      }
    }

    // Content words.
    let rest = String(chars)
    let typing = !(raw.last?.isWhitespace ?? true)
    let (units, phrases, phraseTexts) = contentUnits(
      rest, lexicon: context.lexicon, typing: typing)
    return SearchQuery(
      raw: raw, normalized: normalized, units: units, phrases: phrases,
      phraseTexts: phraseTexts, people: people, sources: sources, interval: interval,
      chips: chips)
  }

  /// What a chip's words become in the rest of the query: a separator that
  /// keeps the words on either side apart.
  static let gap: Character = "\u{1F}"

  /// The query without a chip's words (spaces tidied).
  public static func removing(_ chip: SearchChip, from raw: String) -> String {
    var text = raw
    if let range = text.range(
      of: chip.text, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive])
    {
      text.removeSubrange(range)
    } else {
      text = SearchText.normalize(text).replacingOccurrences(of: chip.text, with: " ")
    }
    // Particles that only tied the chip to the rest (「微信里的报价」).
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
      .map { $0.hasPrefix("里的") ? String($0.dropFirst(2)) : $0 }
      .filter { !["里", "的", "里的", "上", "中"].contains($0) && !$0.isEmpty }
    return words.joined(separator: " ")
  }

  // MARK: - Content

  private struct Piece {
    var text: String
    let entry: SearchLexiconEntry?
    let han: Bool
    var stop: Bool
    /// Something other than spaces stands between it and the piece before.
    let apart: Bool
    /// Which run of the query it came from, and how many pieces that run has.
    var run: Int = 0
    var runPieces: Int = 1
  }

  static func contentUnits(_ text: String, lexicon: [SearchLexiconEntry], typing: Bool)
    -> ([SearchUnit], [SearchForm], [String])
  {
    let lexiconForms: [(String, SearchLexiconEntry)] =
      lexicon.flatMap { entry in
        entry.forms.map { (SearchText.normalize($0).filter { !$0.isWhitespace }, entry) }
      }
      .filter { !$0.0.isEmpty }
      .sorted { $0.0.count > $1.0.count }
    let scalars = Array(text.precomposedStringWithCompatibilityMapping.unicodeScalars)
    var pieces: [Piece] = []
    var previousEnd: Int?
    for (runIndex, run) in SearchText.runs(of: text).enumerated() {
      let gap = previousEnd.map { scalars[$0..<run.start] } ?? []
      let apart = previousEnd == nil || gap.contains { !CharacterSet.whitespaces.contains($0) }
      previousEnd = run.end
      switch run.kind {
      case .han(let characters):
        let found = hanPieces(characters.joined(), lexicon: lexiconForms)
        for (index, piece) in found.enumerated() {
          pieces.append(
            Piece(
              text: piece.text, entry: piece.entry, han: true,
              stop: piece.entry == nil && stopwords.contains(piece.text),
              apart: index == 0 ? apart : false, run: runIndex, runPieces: found.count))
        }
      case .word(let word):
        let lower = word.lowercased()
        pieces.append(
          Piece(
            text: word, entry: lexiconForms.first { $0.0 == lower }?.1, han: false,
            stop: englishStopwords.contains(lower), apart: apart))
      }
    }
    // Two characters typed alone, one of them a stopword, are one word
    // (「理聊」 is a typo of 理疗, not 理 and 聊).
    var index = 0
    while index + 1 < pieces.count {
      let a = pieces[index]
      let b = pieces[index + 1]
      if a.han, b.han, a.run == b.run, a.runPieces == 2, a.text.count == 1, b.text.count == 1,
        a.stop != b.stop, a.entry == nil, b.entry == nil
      {
        pieces[index].text += b.text
        pieces[index].stop = false
        pieces.remove(at: index + 1)
      }
      index += 1
    }
    var units: [SearchUnit] = []
    var phrases: [SearchForm] = []
    var phraseTexts: [String] = []
    var group: [Piece] = []
    func closeGroup() {
      defer { group = [] }
      guard group.count >= 2 else { return }
      if group[0].han {
        let characters = group.flatMap { $0.text.map(String.init) }
        phrases.append(SearchForm(atoms: [.grams(grams(characters))]))
        phraseTexts.append(characters.joined())
      } else {
        let joined = group.map { $0.text.lowercased() }.joined()
        phrases.append(SearchForm(atoms: [.word(joined, prefix: false)]))
        phraseTexts.append(group.map(\.text).joined(separator: " "))
        phraseTexts.append(joined)
      }
    }
    for piece in pieces {
      if piece.stop {
        closeGroup()
        continue
      }
      if piece.apart || group.first.map({ $0.han != piece.han }) == true { closeGroup() }
      group.append(piece)
      units.append(unit(piece.text, entry: piece.entry))
    }
    closeGroup()
    // A lone character (「传了吗」's 传) says little next to real words: it
    // still counts inside the words typed together, but no record has to
    // hold it on its own.
    let soft: (SearchUnit) -> Bool = { unit in
      unit.text.count == 1 && unit.text.unicodeScalars.allSatisfy(SearchText.isHan)
        && unit.highlights.count == 1
    }
    if units.contains(where: { !soft($0) }) { units.removeAll(where: soft) }
    // The last word may still be being typed.
    if typing, let last = units.last, last.forms.count >= 1,
      case .word(let w, false)? = last.forms.first?.atoms.first, w.count >= 2
    {
      units[units.count - 1] = SearchUnit(
        text: last.text,
        forms: [SearchForm(atoms: [.word(w, prefix: true)])] + last.forms.dropFirst(),
        highlights: last.highlights)
    }
    // The same word twice counts once.
    var seen = Set<String>()
    var seenPhrases = Set<SearchForm>()
    return (
      units.filter { seen.insert($0.text).inserted },
      phrases.filter { seenPhrases.insert($0).inserted },
      Array(Set(phraseTexts))
    )
  }

  private struct HanPiece {
    let text: String
    let entry: SearchLexiconEntry?
  }

  /// A Han run cut into words: dictionary words first (longest), the rest by
  /// the system's word boundaries, with single characters next to each other
  /// joined back (an unknown name or a typo is one word, not two letters).
  private static func hanPieces(
    _ run: String, lexicon: [(String, SearchLexiconEntry)]
  ) -> [HanPiece] {
    var pieces: [HanPiece] = []
    var rest = Substring(run)
    var pending = ""
    func flush() {
      if !pending.isEmpty { pieces += segment(pending).map { HanPiece(text: $0, entry: nil) } }
      pending = ""
    }
    while !rest.isEmpty {
      if let (form, entry) = lexicon.first(where: { rest.hasPrefix($0.0) }) {
        flush()
        pieces.append(HanPiece(text: form, entry: entry))
        rest = rest.dropFirst(form.count)
      } else {
        pending.append(rest.removeFirst())
      }
    }
    flush()
    return pieces
  }

  /// System word boundaries (Chinese), stopwords split out, neighbouring
  /// single characters joined.
  static func segment(_ text: String) -> [String] {
    var words: [String] = []
    let cf = text as CFString
    let tokenizer = CFStringTokenizerCreate(
      nil, cf, CFRangeMake(0, CFStringGetLength(cf)), kCFStringTokenizerUnitWordBoundary,
      Locale(identifier: "zh_CN") as CFLocale)
    var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
    let ns = text as NSString
    while type != [] {
      let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      let word = ns.substring(with: NSRange(location: range.location, length: range.length))
      if !word.trimmingCharacters(in: .whitespaces).isEmpty { words.append(word) }
      type = CFStringTokenizerAdvanceToNextToken(tokenizer)
    }
    if words.isEmpty { words = [text] }
    // Stopwords the tokenizer kept inside a word (「聊了」, 「什么时候」).
    var split: [String] = []
    for word in words {
      if stopwords.contains(word) {
        split.append(word)
        continue
      }
      if let stop = stopwords.filter({ $0.count >= 2 && word.contains($0) }).max(by: {
        $0.count < $1.count
      }),
        let range = word.range(of: stop)
      {
        let before = String(word[..<range.lowerBound])
        let after = String(word[range.upperBound...])
        if !before.isEmpty { split.append(before) }
        split.append(stop)
        if !after.isEmpty { split.append(after) }
      } else if word.count == 2, stopwords.contains(String(word.last!)),
        stopwords.contains(String(word.first!))
      {
        split.append(contentsOf: word.map(String.init))
      } else {
        split.append(word)
      }
    }
    // Join single non-stopword characters that sit next to each other.
    var joined: [String] = []
    var run = ""
    for word in split {
      if word.count == 1, !stopwords.contains(word) {
        run += word
      } else {
        if !run.isEmpty { joined.append(run) }
        run = ""
        joined.append(word)
      }
    }
    if !run.isEmpty { joined.append(run) }
    return joined
  }

  /// One content word as a unit: its own forms, plus the dictionary entry's
  /// other spellings.
  static func unit(_ text: String, entry: SearchLexiconEntry?, prefix: Bool = false) -> SearchUnit {
    var forms = forms(of: text, prefix: prefix)
    var highlights = [text]
    if let entry {
      for spelling in entry.forms {
        let more = Self.forms(of: spelling, prefix: false)
        for form in more where !forms.contains(form) { forms.append(form) }
        highlights.append(spelling)
      }
    }
    return SearchUnit(text: SearchText.normalize(text), forms: forms, highlights: highlights)
  }

  /// The forms of a spelling: Han runs as grams (or one character) with
  /// their pinyin as an alternative; words as themselves, their camel-case
  /// parts, and (letters only) as pinyin typed in place of characters.
  static func forms(of spelling: String, prefix: Bool) -> [SearchForm] {
    let runs = SearchText.runs(of: spelling)
    guard !runs.isEmpty else { return [] }
    // Several runs in one spelling (「TES 论文」): all of them, as written.
    var written: [SearchAtom] = []
    var sounds: [SearchAtom] = []
    var alternatives: [SearchForm] = []
    for run in runs {
      switch run.kind {
      case .han(let characters):
        if characters.count == 1 {
          written.append(.character(characters[0]))
          sounds.append(.character(characters[0]))
        } else {
          written.append(.grams(grams(characters)))
          let syllables = characters.map { SearchText.pinyin($0.unicodeScalars.first!) }
          if syllables.allSatisfy({ !$0.isEmpty }) {
            sounds.append(.pinyin(grams(syllables)))
          } else {
            sounds.append(.grams(grams(characters)))
          }
        }
      case .word(let word):
        let lower = word.lowercased()
        written.append(.word(lower, prefix: prefix && runs.count == 1))
        sounds.append(.word(lower, prefix: prefix && runs.count == 1))
        if runs.count == 1 {
          let parts = SearchText.wordParts(word)
          if parts.count > 1 {
            alternatives.append(SearchForm(atoms: parts.map { .word($0, prefix: false) }))
          }
          if lower.count >= 4, lower.allSatisfy({ $0.isASCII && $0.isLetter }) {
            alternatives.append(SearchForm(atoms: [.pinyin([lower])]))
          }
        }
      }
    }
    var forms = [SearchForm(atoms: written)]
    if sounds != written { forms.append(SearchForm(atoms: sounds)) }
    for alternative in alternatives where !forms.contains(alternative) { forms.append(alternative) }
    return forms
  }

  static func grams(_ items: [String]) -> [String] {
    guard items.count >= 2 else { return items }
    return (0..<(items.count - 1)).map { items[$0] + items[$0 + 1] }
  }

  // MARK: - Finding words

  /// The first place `key` appears in `chars` (a whole word when asked; a
  /// generic word needs a space, the edge, or a particle around it).
  static func find(_ key: String, in chars: [Character], wholeWord: Bool, standalone: Bool = false)
    -> Int?
  {
    let needle = Array(key)
    guard !needle.isEmpty, needle.count <= chars.count else { return nil }
    for start in 0...(chars.count - needle.count) {
      guard Array(chars[start..<(start + needle.count)]) == needle else { continue }
      let before = start > 0 ? chars[start - 1] : " "
      let after = start + needle.count < chars.count ? chars[start + needle.count] : " "
      if wholeWord, isWordCharacter(before) || isWordCharacter(after) { continue }
      if standalone {
        let beforeOK = before.isWhitespace || "在从用".contains(before) || !isHanCharacter(before)
        let afterOK = after.isWhitespace || "里中上的".contains(after) || !isHanCharacter(after)
        guard beforeOK, afterOK else { continue }
      }
      return start
    }
    return nil
  }

  static func isHanCharacter(_ c: Character) -> Bool {
    c.unicodeScalars.first.map(SearchText.isHan) ?? false
  }

  /// A letter or digit of a word (not Han).
  static func isWordCharacter(_ c: Character) -> Bool {
    c.unicodeScalars.first.map(SearchText.isWordCharacter) ?? false
  }

  // MARK: - Stopwords

  /// Words that carry no content in a question (「上周跟周老师聊了什么」).
  public static let stopwords: Set<String> = [
    "的", "了", "吗", "呢", "吧", "啊", "呀", "和", "跟", "与", "及", "在", "是", "有", "我", "你",
    "他", "她", "它", "们", "这", "那", "就", "都", "也", "还", "把", "被", "给", "对", "从", "到",
    "说", "聊", "讲", "问", "过", "么", "里", "中", "上", "下", "个", "些", "又", "再", "很", "要",
    "想", "去", "来", "做", "让", "等", "之", "得", "地", "着", "哪", "谁", "啥", "怎", "什",
    "什么", "什么时候", "怎么", "怎么样", "为什么", "哪些", "哪个", "哪里", "有没有", "是不是", "一下",
    "那个", "这个", "那些", "这些", "关于", "有关", "相关", "时候", "之前", "之后", "以前", "以后",
    "说过", "聊过", "提到", "提过", "讨论", "我们", "他们", "你们", "她们", "自己", "一些", "还有",
    "然后", "已经", "应该", "可以", "需要", "所有", "全部", "那天", "那次", "当时", "最近", "里面",
    "记得", "好像", "大概", "到底", "多少", "几个", "聊了", "说了", "讲了", "问了", "找", "搜",
    "东西", "事情", "一下子", "的话", "几号", "几点", "几天", "哪天", "多久", "多少钱", "怎么办", "了吗",
    "没有", "好了", "要不要", "能不能", "是谁", "谁写", "在哪",
  ]

  static let englishStopwords: Set<String> = [
    "the", "a", "an", "of", "and", "or", "to", "in", "on", "for", "is", "are", "was", "with",
    "about",
    "what", "when", "did", "do", "does",
  ]
}
