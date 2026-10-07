import BestASRMemory
import Foundation

import struct CryptoKit.SHA256

/// One matter as the agent's search sees it: only matters inside the grant,
/// and only their words as the agent would read them (numbers already masked
/// for a grant that masks them, AGENT-005), so a search can never find what
/// the agent may not read.
public struct AgentSearchDocument: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    public let itemID: String
    public let text: String
    /// When it was taken in (time words in a query read this).
    public let at: Date?
    /// Where it came from (source words read this); nil when not known.
    public let source: AgentSearchSource?
    /// Who speaks in it (already masked).
    public let speakers: [String]

    public init(
      itemID: String, text: String, at: Date? = nil, source: AgentSearchSource? = nil,
      speakers: [String] = []
    ) {
      self.itemID = itemID
      self.text = text
      self.at = at
      self.source = source
      self.speakers = speakers
    }
  }

  public let matterID: String
  public let title: String
  public let status: String
  public let people: [String]
  /// Steps, deadlines and facts, one line each.
  public let steps: [String]
  public let items: [Item]
  public let updatedAt: Date?

  public init(
    matterID: String, title: String, status: String, people: [String], steps: [String],
    items: [Item], updatedAt: Date?
  ) {
    self.matterID = matterID
    self.title = title
    self.status = status
    self.people = people
    self.steps = steps
    self.items = items
    self.updatedAt = updatedAt
  }
}

/// Where an item came from, as the App's source words read it
/// (`SearchSourceFilter`).
public struct AgentSearchSource: Sendable, Equatable {
  /// The App or device it came from (「微信」).
  public let name: String?
  /// `SessionInputMode` raw value.
  public let inputMode: String
  /// `UserItemKind` raw value, for pasted and dragged items.
  public let itemKind: String?
  /// A file's name, only to tell a PDF from other files; never shown.
  public let fileName: String?

  public init(name: String?, inputMode: String, itemKind: String? = nil, fileName: String? = nil) {
    self.name = name
    self.inputMode = inputMode
    self.itemKind = itemKind
    self.fileName = fileName
  }
}

/// A matter the search found, best first, with the line that shows why.
public struct AgentSearchHit: Sendable, Equatable {
  public let matterID: String
  public let score: Double
  /// 「标题」, 「现在」, 「步骤」, 「人物」 or 「原文」.
  public let field: String
  /// The words that matched, cut short (already masked).
  public let why: String
  /// The item the words are in, when they are in one.
  public let itemID: String?
  /// It holds only some of the words (nothing held them all).
  public let partial: Bool

  public init(
    matterID: String, score: Double, field: String, why: String, itemID: String?,
    partial: Bool = false
  ) {
    self.matterID = matterID
    self.score = score
    self.field = field
    self.why = why
    self.itemID = itemID
    self.partial = partial
  }
}

/// What one search found.
public struct AgentSearchResult: Sendable, Equatable {
  public var hits: [AgentSearchHit]
  /// The conditions read from the query and applied: a time (「上周 · 9月28日–10月4日」),
  /// a source (「微信」), a person's name.
  public var conditions: [String]
  /// A condition nothing in reach met together with the rest of the query:
  /// left out to find `hits` (the App's 「不限「…」」).
  public var dropped: [String]
  /// The meaning side compared only part of the matters' words: some pieces
  /// had no vector yet (the background warm-up has not reached them, or a
  /// search may make only so many). The answer says so.
  public var meaningPartial: Bool

  public init(
    hits: [AgentSearchHit] = [], conditions: [String] = [], dropped: [String] = [],
    meaningPartial: Bool = false
  ) {
    self.hits = hits
    self.conditions = conditions
    self.dropped = dropped
    self.meaningPartial = meaningPartial
  }
}

/// The App's search, as agents use it (ALIGNMENT 用-8: the agent searches with
/// the same engine as the App). The App injects its engine here.
public protocol AgentSearching: Sendable {
  /// Matters among `documents` for `query`, best first, at most `limit`.
  /// `clock` reads time words (the product time zone, the service's now).
  func search(
    _ query: String, in documents: [AgentSearchDocument], limit: Int, clock: SearchClock
  ) async -> AgentSearchResult
}

/// The meaning half of the App's search, as agents use it (v12 search): the
/// same model and the same way of combining as 历史. The vectors are made
/// from exactly the words the agent may read (masked when the grant masks),
/// so meaning never reaches past them.
public struct AgentMeaning: Sendable {
  public let embed: @Sendable ([String], MeaningTextRole) async throws -> [[Float]]
  /// Pieces less similar than this are not results.
  public let floor: Float
  public let policy: MeaningFusion.Policy
  /// Pieces one search embeds, at most. The App makes the vectors in the
  /// background (`AgentRecordSearch.warmMeaning`); a search embeds only what
  /// that has not reached (a grant's masked words, new matters).
  public let maximumNewPieces: Int
  /// Asked before each batch of new pieces: false stops embedding (the App
  /// says false once dictation or a recording starts); the search goes on
  /// with the vectors it has.
  public let mayEmbed: @Sendable () async -> Bool
  /// Names the model the vectors come from: vectors of another are never
  /// compared.
  public let model: String
  /// Vectors kept in the library, by piece key (`AgentRecordSearch.pieceKey`).
  public let stored: @Sendable ([String]) async -> [String: [Float]]
  /// Keeps new vectors in the library (`fromSearch`: made while a search ran).
  public let store: @Sendable (_ vectors: [String: [Float]], _ fromSearch: Bool) async -> Void

  public init(
    floor: Float, policy: MeaningFusion.Policy = .standard, maximumNewPieces: Int = 1_500,
    model: String = "",
    stored: @escaping @Sendable ([String]) async -> [String: [Float]] = { _ in [:] },
    store: @escaping @Sendable ([String: [Float]], Bool) async -> Void = { _, _ in },
    mayEmbed: @escaping @Sendable () async -> Bool = { true },
    embed: @escaping @Sendable ([String], MeaningTextRole) async throws -> [[Float]]
  ) {
    self.embed = embed
    self.floor = floor
    self.policy = policy
    self.maximumNewPieces = maximumNewPieces
    self.mayEmbed = mayEmbed
    self.model = model
    self.stored = stored
    self.store = store
  }
}

/// What one background warm-up of the agents' vectors did.
public struct AgentMeaningWarmup: Equatable, Sendable {
  /// Every piece key of the matters warmed (the ones to keep).
  public let keys: Set<String>
  /// Pieces that got a vector now.
  public let embedded: Int
}

/// The App's own search engine (v12 find, B4 §3.2) over the matters an agent
/// may read. The query is read the way 历史 reads it (`SearchQueryParser`):
/// time words (product time zone), source words and people's names become
/// conditions, the rest content words with their sounds and dictionary
/// spellings. Text is matched by the record index's own rules
/// (`SearchTokens`: two-character grams, single characters, toneless pinyin
/// for homophone typos, full/half width, case, traditional/simplified,
/// camel-case parts), so 「穹鼎」 finds 穹顶 and 「Robo Prior」 finds RoboPrior.
///
/// Only `documents` are searched — the grant's matters, already masked — and
/// the people and source names the query may name are taken from them, never
/// from the rest of the library. A matter must hold every content word
/// (title, status, steps, people, items); words typed together and held
/// together rank first, rarer words count more (BM25's IDF), and the title
/// above status and steps, above people, above the 原文. Time and source
/// conditions keep the items they fit (a matter needs at least one). When no
/// matter holds every word, those holding the most come back marked
/// `partial`; when the conditions leave nothing, each one is left out in turn
/// (`AgentSearchResult.dropped`), as the App offers 「不限「…」」.
public struct AgentRecordSearch: AgentSearching {
  /// What the App's search reads besides the matters: the dictionary
  /// (spoken ↔ written forms; it stays in the engine, nothing of it is
  /// returned) and the owner's own names (never a condition).
  public struct Vocabulary: Sendable {
    public var lexicon: [SearchLexiconEntry]
    public var ownerNames: Set<String>

    public init(lexicon: [SearchLexiconEntry] = [], ownerNames: Set<String> = []) {
      self.lexicon = lexicon
      self.ownerNames = ownerNames
    }
  }

  private let vocabulary: @Sendable () async -> Vocabulary
  /// The meaning half, when the App has its model (nil: by characters only).
  private let meaning: @Sendable () async -> AgentMeaning?
  /// Index tokens by text, kept between searches (about 32 MB of text).
  let cache = AgentGenerationCache<SearchTokens>(budget: 32_000_000)
  /// Vectors of the pieces the agent may read, by piece key: at most 32 MB
  /// in memory (about 7,800 pieces of 1,024 values); the rest are read from
  /// the library (`AgentMeaning.stored`) when a search needs them.
  let vectors = AgentMeaningVectors(budget: 32_000_000)

  public init(
    vocabulary: @escaping @Sendable () async -> Vocabulary = { Vocabulary() },
    meaning: @escaping @Sendable () async -> AgentMeaning? = { nil }
  ) {
    self.vocabulary = vocabulary
    self.meaning = meaning
  }

  /// A matter holding only some of the words, scoring below this share of
  /// the best one, is left out.
  static let partialShare = 0.25

  /// What a word held only by sound counts, against one held as written.
  static let soundOnly = 0.4

  public func search(
    _ query: String, in documents: [AgentSearchDocument], limit: Int, clock: SearchClock
  ) async -> AgentSearchResult {
    guard !documents.isEmpty, limit > 0 else { return AgentSearchResult() }
    let words = await vocabulary()
    let context = Self.context(for: documents, vocabulary: words, clock: clock)
    // The query is complete (an agent does not type as it goes): no prefix
    // reading of the last word.
    let parsed = SearchQueryParser.parse(query + " ", context: context)
    guard !parsed.isEmpty else { return AgentSearchResult() }
    cache.beginUse()
    let prepared = documents.map(prepare)
    let meaning = await meaning()
    let found = await combined(parsed, prepared, limit: limit, meaning: meaning)
    guard found.hits.isEmpty, !parsed.chips.isEmpty else {
      return AgentSearchResult(
        hits: found.hits, conditions: parsed.chips.map(\.label), meaningPartial: found.partial)
    }
    for chip in parsed.chips {
      let rest = SearchQueryParser.removing(chip, from: query)
      let wider = SearchQueryParser.parse(rest + " ", context: context)
      guard !wider.isEmpty else { continue }
      let more = await combined(wider, prepared, limit: limit, meaning: meaning)
      if !more.hits.isEmpty {
        return AgentSearchResult(
          hits: more.hits, conditions: wider.chips.map(\.label), dropped: [chip.label],
          meaningPartial: more.partial)
      }
    }
    return AgentSearchResult(conditions: parsed.chips.map(\.label), meaningPartial: found.partial)
  }

  /// By characters, and by meaning when the App has its model, combined the
  /// way 历史 combines them (`MeaningFusion`). `partial`: the meaning side
  /// compared only part of the words in reach.
  func combined(
    _ query: SearchQuery, _ prepared: [Prepared], limit: Int, meaning: AgentMeaning?
  ) async -> (hits: [AgentSearchHit], partial: Bool) {
    guard let meaning, MeaningQueryText.asksMeaning(query) else {
      return (run(query, prepared, limit: limit), false)
    }
    let lexical = run(query, prepared, limit: max(limit, meaning.policy.depth))
    let (meant, partial) = await meaningHits(query, prepared, meaning: meaning)
    guard !meant.isEmpty else { return (Array(lexical.prefix(limit)), partial) }
    let byID = Dictionary(lexical.map { ($0.matterID, $0) }, uniquingKeysWith: { a, _ in a })
    let meantByID = Dictionary(meant.map { ($0.matterID, $0) }, uniquingKeysWith: { a, _ in a })
    let fused = MeaningFusion.fuse(
      lexical: lexical.map { MeaningFusion.Lexical(id: $0.matterID, partial: $0.partial) },
      meaning: meant.map { MeaningFusion.Meaning(id: $0.matterID, similarity: $0.similarity) },
      policy: meaning.policy)
    let hits = fused.prefix(limit).compactMap { item -> AgentSearchHit? in
      if let hit = byID[item.id] {
        return AgentSearchHit(
          matterID: hit.matterID, score: hit.score, field: hit.field, why: hit.why,
          itemID: hit.itemID, partial: item.partial)
      }
      guard let hit = meantByID[item.id] else { return nil }
      return AgentSearchHit(
        matterID: hit.matterID, score: Double(hit.similarity), field: hit.field.name,
        why: Self.excerpt(hit.piece, around: []), itemID: hit.field.item?.itemID)
    }
    return (hits, partial)
  }

  struct MeaningHit {
    let matterID: String
    let similarity: Float
    let field: Field
    /// The closest piece of the field's words.
    let piece: String
  }

  /// Matters nearest in meaning, among those the query's conditions keep
  /// (time, source, people), best first; nothing below the floor. Only the
  /// words the agent may read are compared. `partial`: some pieces in reach
  /// had no vector (none stored yet, and this search may make only so many).
  func meaningHits(_ query: SearchQuery, _ prepared: [Prepared], meaning: AgentMeaning) async
    -> (hits: [MeaningHit], partial: Bool)
  {
    let candidates = Self.candidates(query, prepared)
    guard !candidates.isEmpty else { return ([], false) }
    let text = MeaningQueryText.text(query)
    guard let vector = try? await meaning.embed([text], .query).first, !vector.isEmpty else {
      return ([], false)
    }
    // Pieces: the matter's own lines and each item's words, cut the way the
    // background warm-up cuts them (`meaningPieces`).
    var pieces: [(candidate: Int, field: Field, text: String)] = []
    for (index, candidate) in candidates.enumerated() {
      let own = candidate.fields.filter { $0.item == nil }
      for piece in Self.headerPieces(own.map(\.text)) {
        pieces.append((index, own[0], piece))
      }
      for field in candidate.fields where field.item != nil {
        for piece in Self.itemPieces(field.text) {
          pieces.append((index, field, piece))
        }
      }
    }
    var keyOf: [String: String] = [:]
    var wanted: [(key: String, text: String)] = []
    for piece in pieces where keyOf[piece.text] == nil {
      let key = Self.pieceKey(piece.text)
      keyOf[piece.text] = key
      wanted.append((key, piece.text))
    }
    let outcome = await vectors.vectors(
      for: wanted, meaning: meaning, maximumNew: meaning.maximumNewPieces)
    var best: [Int: (similarity: Float, field: Field, text: String)] = [:]
    for piece in pieces {
      guard let key = keyOf[piece.text], let other = outcome.found[key],
        other.count == vector.count
      else { continue }
      var similarity: Float = 0
      for index in other.indices { similarity += other[index] * vector[index] }
      if similarity > (best[piece.candidate]?.similarity ?? -.infinity) {
        best[piece.candidate] = (similarity, piece.field, piece.text)
      }
    }
    let hits = best.filter { $0.value.similarity >= meaning.floor }
      .map {
        MeaningHit(
          matterID: candidates[$0.key].prepared.document.matterID,
          similarity: $0.value.similarity, field: $0.value.field, piece: $0.value.text)
      }
      .sorted {
        $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.matterID < $1.matterID
      }
    return (hits, outcome.missing > 0)
  }

  // MARK: - Pieces and the background warm-up

  /// A matter's own lines (title, status, steps, people) give their first
  /// two pieces; each item its first six.
  static let headerPieceLimit = 2
  static let itemPieceLimit = 6

  static func headerPieces(_ lines: [String]) -> [String] {
    MeaningChunker.chunks(of: lines.joined(separator: "\n")).prefix(headerPieceLimit).map(\.text)
  }

  static func itemPieces(_ text: String) -> [String] {
    MeaningChunker.chunks(of: text).prefix(itemPieceLimit).map(\.text)
  }

  /// The words a matter's meaning side compares, as `prepare` orders them:
  /// its own lines, then each item's words.
  static func meaningPieces(of document: AgentSearchDocument) -> [String] {
    var lines = [document.title]
    if !document.status.isEmpty { lines.append(document.status) }
    lines += document.steps + document.people
    return headerPieces(lines) + document.items.flatMap { itemPieces($0.text) }
  }

  /// A piece's key: a digest of its words exactly as the agent reads them
  /// (a masked number gives another key than the number itself).
  public static func pieceKey(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// Every piece key of `documents` (no model needed).
  public static func meaningKeys(of documents: [AgentSearchDocument]) -> Set<String> {
    Set(documents.flatMap(meaningPieces).map(pieceKey))
  }

  /// Makes, in the background, the vectors a search over `documents` will
  /// compare, so searches do not make them. The App passes every matter's
  /// words as a grant that shows numbers reads them: a grant that masks
  /// reads the same words wherever nothing was masked, so it finds the same
  /// keys; only its masked pieces are left to its searches. `stored`: keys
  /// already in the library (they are not made again). `pause` is awaited
  /// before every batch (the App waits there while dictation, a recording or
  /// its recognition runs; it may throw to stop). A search that needs a
  /// piece this is making waits for it instead of making it again.
  public func warmMeaning(
    _ documents: [AgentSearchDocument], meaning: AgentMeaning, stored: Set<String>,
    pause: @escaping @Sendable () async throws -> Void
  ) async throws -> AgentMeaningWarmup {
    var keys = Set<String>()
    var wanted: [(key: String, text: String)] = []
    for piece in documents.flatMap(Self.meaningPieces) {
      let key = Self.pieceKey(piece)
      guard keys.insert(key).inserted, !stored.contains(key) else { continue }
      wanted.append((key, piece))
    }
    let embedded = try await vectors.warm(wanted, meaning: meaning, pause: pause)
    return AgentMeaningWarmup(keys: keys, embedded: embedded)
  }

  /// The people and sources the query may name: those of the matters in
  /// reach only.
  public static func context(
    for documents: [AgentSearchDocument], vocabulary: Vocabulary = Vocabulary(),
    clock: SearchClock
  ) -> SearchContext {
    var names: [String] = []
    var seenNames = Set<String>()
    var sources: [String] = []
    var seenSources = Set<String>()
    for document in documents {
      for name in document.people + document.items.flatMap(\.speakers)
      where !name.isEmpty && seenNames.insert(name).inserted {
        names.append(name)
      }
      for name in document.items.compactMap(\.source?.name)
      where !name.isEmpty && seenSources.insert(name).inserted {
        sources.append(name)
      }
    }
    return SearchContext(
      people: names.map { SearchPerson(id: $0, name: $0) }, ownerNames: vocabulary.ownerNames,
      lexicon: vocabulary.lexicon, sourceNames: sources, clock: clock)
  }

  // MARK: - Matching

  struct Field {
    let name: String
    let weight: Double
    let text: String
    let tokens: SearchTokens
    let item: AgentSearchDocument.Item?
  }

  struct Prepared {
    let document: AgentSearchDocument
    /// Title, status, steps and people.
    let matter: [Field]
    let items: [Field]
  }

  func prepare(_ document: AgentSearchDocument) -> Prepared {
    func field(_ name: String, _ weight: Double, _ text: String, _ item: AgentSearchDocument.Item?)
      -> Field
    {
      Field(
        name: name, weight: weight, text: text, tokens: cache.value(text) { SearchTokens(text) },
        item: item)
    }
    var matter = [field("标题", 3, document.title, nil)]
    if !document.status.isEmpty { matter.append(field("现在", 2, document.status, nil)) }
    matter += document.steps.map { field("步骤", 2, $0, nil) }
    matter += document.people.map { field("人物", 1.5, $0, nil) }
    return Prepared(
      document: document, matter: matter, items: document.items.map { field("原文", 1, $0.text, $0) })
  }

  /// Whether an item fits the query's time and source conditions.
  static func fits(_ item: AgentSearchDocument.Item, _ query: SearchQuery) -> Bool {
    if let interval = query.interval {
      guard let at = item.at, interval.contains(at), at < interval.end else { return false }
    }
    if !query.sources.isEmpty {
      guard let source = item.source,
        query.sources.contains(where: {
          $0.matches(
            sourceName: source.name, inputMode: source.inputMode, itemKind: source.itemKind,
            sourceKind: nil, sourceIdentifier: source.fileName)
        })
      else { return false }
    }
    return true
  }

  /// Whether a matter (its own fields, the items kept) names a person.
  static func names(_ person: SearchPerson, _ document: AgentSearchDocument, _ fields: [Field])
    -> Bool
  {
    let spellings = Set(person.spellings.map(SearchText.normalize))
    let listed =
      document.people + fields.compactMap(\.item).flatMap(\.speakers)
    if listed.contains(where: { spellings.contains(SearchText.normalize($0)) }) { return true }
    return fields.contains { $0.tokens.mentions(person) }
  }

  /// The matters a query's conditions keep (time and source keep the items
  /// they fit; a matter needs one), with the fields searched.
  static func candidates(_ query: SearchQuery, _ prepared: [Prepared]) -> [(
    prepared: Prepared, fields: [Field], newest: Date?
  )] {
    let conditioned = query.interval != nil || !query.sources.isEmpty
    var candidates: [(prepared: Prepared, fields: [Field], newest: Date?)] = []
    for entry in prepared {
      let items = conditioned ? entry.items.filter { Self.fits($0.item!, query) } : entry.items
      if conditioned, items.isEmpty { continue }
      let fields = entry.matter + items
      guard query.people.allSatisfy({ Self.names($0, entry.document, fields) }) else { continue }
      let newest = conditioned ? items.compactMap(\.item?.at).max() : entry.document.updatedAt
      candidates.append((entry, fields, newest))
    }
    return candidates
  }

  func run(_ query: SearchQuery, _ prepared: [Prepared], limit: Int) -> [AgentSearchHit] {
    let candidates = Self.candidates(query, prepared)
    guard !candidates.isEmpty else { return [] }
    if query.units.isEmpty {
      return Self.byTime(query, candidates, limit: limit)
    }
    // How rare each word is among the matters in reach.
    let count = Double(candidates.count)
    let idf: [Double] = query.units.map { unit in
      let holding = Double(
        candidates.filter { $0.fields.contains { $0.tokens.contains(unit) } }.count)
      return log(1 + (count - holding + 0.5) / (holding + 0.5))
    }
    var scored: [(hit: AgentSearchHit, held: Int, date: Date)] = []
    for candidate in candidates {
      var score = 0.0
      var held = 0
      for (index, unit) in query.units.enumerated() {
        // As written counts fully; only by sound (a homophone, the pinyin
        // form) counts less, so the words typed rank above sound-alikes.
        let written = unit.forms.first
        let best = candidate.fields.filter { $0.tokens.contains(unit) }.map { field in
          field.weight * (written.map { field.tokens.contains($0) } == true ? 1 : Self.soundOnly)
        }.max()
        guard let best else { continue }
        held += 1
        score += best * idf[index]
      }
      guard held > 0 else { continue }
      // Words typed together, also together in one place.
      if !query.phrases.isEmpty,
        query.phrases.allSatisfy({ phrase in candidate.fields.contains { $0.tokens.contains(phrase) } })
      {
        score *= 1.5
      }
      let why = Self.why(query, candidate.fields, idf: idf)
      scored.append(
        (
          AgentSearchHit(
            matterID: candidate.prepared.document.matterID, score: score, field: why.name,
            why: Self.excerpt(why.text, around: query.highlights), itemID: why.item?.itemID,
            partial: held < query.units.count),
          held, candidate.newest ?? .distantPast
        ))
    }
    let all = scored.filter { $0.held == query.units.count }
    var kept = all
    if kept.isEmpty, query.units.count >= 2 {
      // Nothing holds every word: those holding the most, marked partial.
      let most = scored.map(\.held).max() ?? 0
      kept = scored.filter { $0.held == most }
      if let top = kept.map(\.hit.score).max() {
        kept = kept.filter { $0.hit.score >= top * Self.partialShare }
      }
    }
    return kept.sorted {
      $0.hit.score != $1.hit.score ? $0.hit.score > $1.hit.score : $0.date > $1.date
    }.prefix(limit).map(\.hit)
  }

  /// Only conditions (a time, a source, a person): the matters that fit,
  /// the most recent first, each with its newest fitting item.
  static func byTime(
    _ query: SearchQuery, _ candidates: [(prepared: Prepared, fields: [Field], newest: Date?)],
    limit: Int
  ) -> [AgentSearchHit] {
    candidates.sorted { ($0.newest ?? .distantPast) > ($1.newest ?? .distantPast) }
      .prefix(limit).map { candidate in
        let items = candidate.fields.filter { $0.item != nil }
        let naming = items.filter { field in query.people.contains { field.tokens.mentions($0) } }
        let chosen =
          (naming.isEmpty ? items : naming).max { ($0.item?.at ?? .distantPast) < ($1.item?.at ?? .distantPast) }
          ?? candidate.fields[0]
        return AgentSearchHit(
          matterID: candidate.prepared.document.matterID, score: 0, field: chosen.name,
          why: excerpt(chosen.text, around: query.highlights), itemID: chosen.item?.itemID)
      }
  }

  /// The place that shows best why: the one holding the rarest words; on a
  /// tie the item that fits the query's time or source (it is what the
  /// condition found), else the heavier field.
  static func why(_ query: SearchQuery, _ fields: [Field], idf: [Double]) -> Field {
    let conditioned = query.interval != nil || !query.sources.isEmpty
    func rank(_ field: Field) -> Double {
      conditioned && field.item != nil ? 10 : field.weight
    }
    var best = fields[0]
    var bestValue = -1.0
    for field in fields {
      var value = 0.0
      for (index, unit) in query.units.enumerated() where field.tokens.contains(unit) {
        value += idf[index]
      }
      if value > bestValue || (value == bestValue && rank(field) > rank(best)) {
        best = field
        bestValue = value
      }
    }
    return best
  }

  /// About 60 characters of `text` around the first spelling of the query
  /// in it, on one line (its start when the words met only by sound).
  static func excerpt(_ text: String, around highlights: [String]) -> String {
    let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    let characters = Array(line)
    guard characters.count > 60 else { return line }
    var start = 0
    for key in highlights where !key.isEmpty {
      guard
        let range = line.range(
          of: key, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive])
      else { continue }
      start = max(0, line.distance(from: line.startIndex, to: range.lowerBound) - 20)
      break
    }
    let end = min(characters.count, start + 60)
    return (start > 0 ? "…" : "") + String(characters[start..<end])
      + (end < characters.count ? "…" : "")
  }
}

/// Kept between calls, keyed by text: an agent asks about the same matters
/// again and again, so their index tokens (and masked text) are made once.
/// Generational (review v12-B #10): nothing is dropped while a call runs, so
/// one call over a corpus bigger than the budget never throws away what it
/// is about to use (the old cache cleared itself whole past 4 MB, mid-call,
/// and every call then tokenized everything again); at the start of the next
/// call, when over budget, what the last call did not use goes first, least
/// recently used first.
final class AgentGenerationCache<Value>: @unchecked Sendable {
  private struct Entry {
    let value: Value
    let cost: Int
    var used: UInt64
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var size = 0
  private var generation: UInt64 = 0
  let budget: Int
  /// How many values were made (not found): for tests and measurements.
  private(set) var made = 0

  init(budget: Int) {
    self.budget = budget
  }

  /// A call begins: over budget, what the previous call did not use goes.
  func beginUse() {
    lock.withLock {
      if size > budget {
        let stale = entries.filter { $0.value.used < generation }
          .sorted { $0.value.used < $1.value.used }
        for (key, entry) in stale {
          guard size > budget else { break }
          entries[key] = nil
          size -= entry.cost
        }
      }
      generation += 1
    }
  }

  func value(_ key: String, make: () -> Value) -> Value {
    if let hit = lock.withLock({ () -> Value? in
      guard var entry = entries[key] else { return nil }
      entry.used = generation
      entries[key] = entry
      return entry.value
    }) {
      return hit
    }
    let value = make()
    let cost = key.utf8.count
    lock.withLock {
      made += 1
      if entries[key] == nil { size += cost }
      entries[key] = Entry(value: value, cost: cost, used: generation)
    }
    return value
  }

  var count: Int { lock.withLock { entries.count } }
}
