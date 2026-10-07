import BestASRDomain
import BestASRMemory
import Foundation
import GRDB

// v12 (find): the record search index and the history list (ALIGNMENT 查-1
// to 查-7, B4 §3). One derived index over every record (dictations, Typeless
// imports, meetings, imports, pasted items): normalized two-character grams,
// single characters, toneless pinyin grams, words with their camel-case
// parts, the people heard in it, its title and source. A search is one FTS5
// MATCH ranked by relevance (bm25, a little recency); a list with no words
// is the history, newest first, paged by a time cursor. Derived data only:
// rebuilt from the portable tables at any time, never exported.

/// Where a page of results continues.
public enum RecordSearchCursor: Equatable, Sendable {
  /// Time order: records older than this one.
  case before(createdAt: Double, sessionID: String)
  /// Relevance order: skip this many.
  case offset(Int)
}

public struct RecordSearchHit: Equatable, Sendable {
  public let sessionID: SessionID
  public let createdAt: Date
  /// bm25 (lower is better); nil in time order.
  public let score: Double?
  /// Holds only some of the words (shown after every record that holds all
  /// of them, when those are few).
  public let partial: Bool
  /// Found by meaning only: it holds none of the words searched together
  /// (`searchRecords(_:meaning:…)`).
  public let meaningOnly: Bool
  /// The piece of the record closest in meaning, when the meaning search
  /// found it (the row shows its line).
  public let meaningPiece: RecordMeaningPiece?

  public init(
    sessionID: SessionID, createdAt: Date, score: Double?, partial: Bool = false,
    meaningOnly: Bool = false, meaningPiece: RecordMeaningPiece? = nil
  ) {
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.score = score
    self.partial = partial
    self.meaningOnly = meaningOnly
    self.meaningPiece = meaningPiece
  }
}

public struct RecordSearchPage: Equatable, Sendable {
  public let hits: [RecordSearchHit]
  /// Nil when there is nothing more.
  public let next: RecordSearchCursor?
  /// Every match (first page only).
  public let total: Int?
}

public struct RecordSearchSyncResult: Equatable, Sendable {
  public let indexed: Int
  public let removed: Int
  public let unchanged: Int
}

extension BestASRPersistenceSchema {
  /// Creates the record search index when missing (rebuilt from scratch when
  /// its revision changes). Derived, never exported.
  public static func installRecordSearchIndex(in database: Database) throws {
    let revision = "1"
    try database.execute(
      sql: """
        CREATE TABLE IF NOT EXISTS bestasr_derived_index_metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        );
        """)
    let installed = try String.fetchOne(
      database,
      sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-search'")
    if installed != revision {
      try database.execute(sql: "DROP TABLE IF EXISTS record_search_fts")
      try database.execute(sql: "DROP TABLE IF EXISTS record_search_docs")
    }
    try database.execute(
      sql: """
        CREATE TABLE IF NOT EXISTS record_search_docs (
          doc_id INTEGER PRIMARY KEY,
          session_id TEXT NOT NULL UNIQUE,
          fingerprint TEXT NOT NULL,
          created_at REAL NOT NULL,
          input_mode TEXT NOT NULL,
          source_kind TEXT,
          source_name TEXT,
          source_identifier TEXT,
          item_kind TEXT,
          hidden INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS record_search_docs_time
          ON record_search_docs(created_at DESC, session_id DESC);
        """)
    // Lookup indexes the history and the record reads need: a record's
    // current text is found by session (every row of the history list and
    // of `memoryItemRecords` asks), and the history walks sessions by time.
    // Without them each lookup scanned every revision (50 ms per 50 rows at
    // 20,000 records). Indexes hold no data of their own.
    try database.execute(
      sql: """
        CREATE INDEX IF NOT EXISTS record_search_transcript_session_index
          ON transcript_revisions(session_id, created_at);
        CREATE INDEX IF NOT EXISTS record_search_session_time_index
          ON sessions(created_at DESC, id DESC);
        """)
    let exists =
      try Bool.fetchOne(
        database,
        sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'record_search_fts')") ?? false
    if !exists {
      let columns = "body, uni, pin, people, meta"
      let options = "tokenize = 'unicode61 remove_diacritics 0', prefix = '2 3'"
      do {
        // Contentless: the index keeps no second copy of the text.
        try database.execute(
          sql: """
            CREATE VIRTUAL TABLE record_search_fts USING fts5(
              \(columns), content = '', contentless_delete = 1, \(options))
            """)
      } catch {
        try database.execute(
          sql: "CREATE VIRTUAL TABLE record_search_fts USING fts5(\(columns), \(options))")
      }
    }
    try database.execute(
      sql: """
        INSERT INTO bestasr_derived_index_metadata(key, value) VALUES ('record-search', ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [revision])
  }
}

extension GRDBDictationStore {
  // MARK: - Index upkeep

  /// Brings the record search index up to date: records whose text, title,
  /// source or people changed are read again, deleted ones leave. Cheap when
  /// nothing changed (one pass over the fingerprints). Tokenizing runs off
  /// the store's actor; writes go in small batches so a recording's commit
  /// never waits long.
  public nonisolated func syncRecordSearchIndex(batchSize: Int = 300) async throws
    -> RecordSearchSyncResult
  {
    let database = try await requirePool()
    let (current, stored) = try await database.read { db in
      let current = try Row.fetchAll(db, sql: Self.recordFingerprintSQL).map(RecordFingerprint.init)
      var stored: [String: String] = [:]
      for row in try Row.fetchAll(db, sql: "SELECT session_id, fingerprint FROM record_search_docs")
      {
        stored[row["session_id"]] = row["fingerprint"]
      }
      return (current, stored)
    }
    let live = Set(current.map(\.sessionID))
    let changed = current.filter { stored[$0.sessionID] != $0.fingerprint }
    let removed = stored.keys.filter { !live.contains($0) }
    if !removed.isEmpty {
      for chunk in removed.chunked(batchSize) {
        try await database.write { db in
          for id in chunk {
            if let rowid = try Int64.fetchOne(
              db, sql: "SELECT doc_id FROM record_search_docs WHERE session_id = ?", arguments: [id]
            ) {
              try db.execute(
                sql: "DELETE FROM record_search_fts WHERE rowid = ?", arguments: [rowid])
              try db.execute(
                sql: "DELETE FROM record_search_docs WHERE doc_id = ?", arguments: [rowid])
            }
          }
        }
      }
    }
    for chunk in changed.chunked(batchSize) {
      let texts = try await database.read { db in
        try Self.recordTexts(db, ids: chunk.filter { !$0.hidden }.map(\.sessionID))
      }
      let documents = chunk.map { item -> (RecordFingerprint, RecordDocument?) in
        guard !item.hidden else { return (item, nil) }
        return (item, RecordDocument(item, texts: texts[item.sessionID]))
      }
      try await database.write { db in
        for (item, document) in documents {
          try Self.storeRecord(db, print: item, document: document)
        }
      }
    }
    return RecordSearchSyncResult(
      indexed: changed.count, removed: removed.count, unchanged: current.count - changed.count)
  }

  static let recordFingerprintSQL = """
    SELECT s.id, s.created_at, s.input_mode, COALESCE(dsn.phase, '') AS phase,
           m.source_kind, m.source_display_name, m.source_identifier, m.title,
           COALESCE(m.title_is_user_edited, 0) AS title_edited, COALESCE(m.updated_at, 0) AS mu,
           uid.item_kind, uid.parent_session_id,
           (SELECT tr.id || ':' || tr.revision FROM transcript_revisions tr
            WHERE tr.session_id = s.id
            ORDER BY CASE WHEN tr.kind IN ('final', 'userEdit') THEN 1 ELSE 0 END DESC,
                     tr.created_at DESC, tr.revision DESC, tr.id DESC
            LIMIT 1) AS tid,
           (SELECT group_concat(id) FROM (
              SELECT dt.id FROM derived_text_revisions dt
              WHERE dt.session_id = s.id AND dt.state = 'current' ORDER BY dt.id)) AS dts,
           (SELECT group_concat(x) FROM (
              SELECT DISTINCT p.id || ':' || p.revision AS x
              FROM speaker_occurrences o JOIN persons p ON p.id = o.person_id
              WHERE o.session_id = s.id AND p.retired_at IS NULL
                AND o.association_status IN ('anonymousIdentity', 'automaticMatch', 'userConfirmed')
              ORDER BY x)) AS ppl
    FROM sessions s
    JOIN dictation_snapshots dsn ON dsn.session_id = s.id
    LEFT JOIN session_metadata m ON m.session_id = s.id
    LEFT JOIN user_item_details uid ON uid.session_id = s.id
    """

  struct RecordFingerprint: Sendable {
    /// `TypelessImportCLI.sourceKind`.
    static let typelessImportSourceKind = "typeless-import"

    let sessionID: String
    let createdAt: Double
    let inputMode: String
    let sourceKind: String?
    let sourceName: String?
    let sourceIdentifier: String?
    let title: String?
    let titleEdited: Bool
    let itemKind: String?
    let hidden: Bool
    let fingerprint: String

    init(row: Row) {
      sessionID = row["id"]
      createdAt = row["created_at"]
      inputMode = row["input_mode"]
      sourceKind = row["source_kind"]
      sourceName = row["source_display_name"]
      sourceIdentifier = row["source_identifier"]
      title = row["title"]
      titleEdited = row["title_edited"]
      itemKind = row["item_kind"]
      let phase: String = row["phase"]
      let parent: String? = row["parent_session_id"]
      // A cancelled capture, or a video's keyframe (shown under its
      // recording), is not a record of its own. A cancelled or failed
      // Typeless dictation brought across is (收1-26): it stays off the
      // timeline (the time-ordered page skips cancelled phases) but search
      // finds it, by its words, its App and its title.
      hidden =
        (phase == "cancelled" && sourceKind != Self.typelessImportSourceKind)
        || parent != nil
      let tid: String? = row["tid"]
      let dts: String? = row["dts"]
      let ppl: String? = row["ppl"]
      let mu: Double = row["mu"]
      fingerprint = [
        tid ?? "", dts ?? "", ppl ?? "", String(mu), phase, String(createdAt),
      ].joined(separator: "|")
    }
  }

  struct RecordTexts: Sendable {
    var text: String = ""
    var people: [String] = []
  }

  /// The words of each record: its current text, its current derived texts
  /// (the cleaned-up dictation, a screenshot's reading), and the people
  /// heard in it.
  static func recordTexts(_ db: Database, ids: [String]) throws -> [String: RecordTexts] {
    guard !ids.isEmpty else { return [:] }
    let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
    var out: [String: RecordTexts] = [:]
    let transcripts = try Row.fetchAll(
      db,
      sql: """
        SELECT s.id,
               (SELECT tr.content FROM transcript_revisions tr WHERE tr.session_id = s.id
                ORDER BY CASE WHEN tr.kind IN ('final', 'userEdit') THEN 1 ELSE 0 END DESC,
                         tr.created_at DESC, tr.revision DESC, tr.id DESC LIMIT 1) AS content
        FROM sessions s WHERE s.id IN (SELECT value FROM json_each(?))
        """, arguments: [json])
    for row in transcripts {
      out[row["id"], default: RecordTexts()].text = (row["content"] as String?) ?? ""
    }
    let derived = try Row.fetchAll(
      db,
      sql: """
        SELECT session_id, output_text FROM derived_text_revisions
        WHERE state = 'current' AND session_id IN (SELECT value FROM json_each(?))
        ORDER BY session_id, created_at
        """, arguments: [json])
    for row in derived {
      let id: String = row["session_id"]
      let text: String = row["output_text"]
      guard !text.isEmpty, out[id]?.text != text else { continue }
      out[id, default: RecordTexts()].text += "\n" + text
    }
    let people = try Row.fetchAll(
      db,
      sql: """
        SELECT DISTINCT o.session_id, p.display_name, p.aliases_json
        FROM speaker_occurrences o JOIN persons p ON p.id = o.person_id
        WHERE o.session_id IN (SELECT value FROM json_each(?)) AND p.retired_at IS NULL
          AND o.association_status IN ('anonymousIdentity', 'automaticMatch', 'userConfirmed')
        """, arguments: [json])
    for row in people {
      let id: String = row["session_id"]
      if let name: String = row["display_name"], !name.isEmpty {
        out[id, default: RecordTexts()].people.append(name)
      }
      if let aliases: String = row["aliases_json"],
        let list = try? JSONDecoder().decode([String].self, from: Data(aliases.utf8))
      {
        out[id, default: RecordTexts()].people += list
      }
    }
    return out
  }

  struct RecordDocument: Sendable {
    let body: String
    let uni: String
    let pin: String
    let people: String
    let meta: String

    init(_ print: RecordFingerprint, texts: RecordTexts?) {
      let indexed = SearchText.indexTokens(texts?.text ?? "")
      body = indexed.body
      uni = indexed.uni
      pin = indexed.pin
      people = SearchText.indexTokens((texts?.people ?? []).joined(separator: " ")).body
      var meta: [String] = []
      if print.titleEdited, let title = print.title { meta.append(title) }
      if let name = print.sourceName { meta.append(name) }
      if print.inputMode == SessionInputMode.userItem.rawValue, let file = print.sourceIdentifier {
        meta.append(file)
      }
      self.meta = SearchText.indexTokens(meta.joined(separator: " ")).body
    }
  }

  static func storeRecord(_ db: Database, print: RecordFingerprint, document: RecordDocument?)
    throws
  {
    let existing = try Int64.fetchOne(
      db, sql: "SELECT doc_id FROM record_search_docs WHERE session_id = ?",
      arguments: [print.sessionID])
    if let existing {
      try db.execute(sql: "DELETE FROM record_search_fts WHERE rowid = ?", arguments: [existing])
    }
    try db.execute(
      sql: """
        INSERT INTO record_search_docs (
          doc_id, session_id, fingerprint, created_at, input_mode, source_kind, source_name,
          source_identifier, item_kind, hidden
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
          fingerprint = excluded.fingerprint, created_at = excluded.created_at,
          input_mode = excluded.input_mode, source_kind = excluded.source_kind,
          source_name = excluded.source_name, source_identifier = excluded.source_identifier,
          item_kind = excluded.item_kind, hidden = excluded.hidden
        """,
      arguments: [
        existing, print.sessionID, print.fingerprint, print.createdAt, print.inputMode,
        print.sourceKind, print.sourceName, print.sourceIdentifier, print.itemKind,
        print.hidden ? 1 : 0,
      ])
    guard let document else { return }
    let rowid =
      try existing
      ?? Int64.fetchOne(
        db, sql: "SELECT doc_id FROM record_search_docs WHERE session_id = ?",
        arguments: [print.sessionID])
    try db.execute(
      sql: """
        INSERT INTO record_search_fts(rowid, body, uni, pin, people, meta)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [rowid, document.body, document.uni, document.pin, document.people, document.meta])
  }

  // MARK: - Search and history

  /// bm25 weights per column: body, uni, pin, people, meta.
  static let recordRankSQL = "bm25(record_search_fts, 10.0, 3.0, 2.0, 6.0, 8.0)"

  /// One page of records for a query: by relevance when it has words, else
  /// newest first (the history, or a list narrowed by time, source or person).
  /// `now` dates the gentle preference for recent records.
  public nonisolated func searchRecords(
    _ query: SearchQuery, cursor: RecordSearchCursor? = nil, limit: Int = 50, now: Date = Date()
  ) async throws -> RecordSearchPage {
    let database = try await requirePool()
    let bounded = max(1, min(limit, 1_000))
    return try await database.read { db in
      if query.ordersByTime {
        return try Self.timeOrderedPage(db, query: query, cursor: cursor, limit: bounded)
      }
      return try Self.rankedPage(db, query: query, cursor: cursor, limit: bounded, now: now)
    }
  }

  static func rankedPage(
    _ db: Database, query: SearchQuery, cursor: RecordSearchCursor?, limit: Int, now: Date
  ) throws -> RecordSearchPage {
    guard let all = query.match() else {
      return RecordSearchPage(hits: [], next: nil, total: 0)
    }
    var filters = ["d.hidden = 0"]
    var filterArgs = StatementArguments()
    if let interval = query.interval {
      filters.append("d.created_at >= ? AND d.created_at < ?")
      filterArgs += [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
    }
    if let source = sourceSQL(
      query.sources, name: "d.source_name", mode: "d.input_mode", kind: "d.item_kind",
      sourceKind: "d.source_kind", identifier: "d.source_identifier")
    {
      filters.append(source.sql)
      filterArgs += source.arguments
    }
    let whereSQL = filters.joined(separator: " AND ")
    func count(_ match: String) throws -> Int {
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM record_search_fts
          JOIN record_search_docs d ON d.doc_id = record_search_fts.rowid
          WHERE record_search_fts MATCH ? AND \(whereSQL)
          """, arguments: [match] + filterArgs) ?? 0
    }
    func page(_ match: String, offset: Int, limit: Int, partial: Bool) throws -> [RecordSearchHit] {
      guard limit > 0 else { return [] }
      return try Row.fetchAll(
        db,
        sql: """
          SELECT d.session_id, d.created_at, \(recordRankSQL) AS score
          FROM record_search_fts
          JOIN record_search_docs d ON d.doc_id = record_search_fts.rowid
          WHERE record_search_fts MATCH ? AND \(whereSQL)
          ORDER BY score * (1.0 + 0.15 / (1.0 + max(0.0, ? - d.created_at) / 2592000.0)),
                   d.created_at DESC, d.session_id DESC
          LIMIT ? OFFSET ?
          """,
        arguments: [match] + filterArgs + [now.timeIntervalSince1970, limit, offset]
      ).compactMap { row in
        guard let uuid = UUID(uuidString: row["session_id"]) else { return nil }
        return RecordSearchHit(
          sessionID: SessionID(uuid), createdAt: Date(timeIntervalSince1970: row["created_at"]),
          score: row["score"], partial: partial)
      }
    }
    // Steps, each one MATCH by relevance, each without the steps before:
    // the words typed together found together; every word; then, only when
    // those find little, all words but one, and any word (marked partial).
    var steps: [(match: String, partial: Bool)] = []
    if let phrase = query.phraseMatch {
      steps = [(phrase, false), ("(\(all)) NOT (\(phrase))", false)]
    } else {
      steps = [(all, false)]
    }
    var counts = try steps.map { try count($0.match) }
    if counts.reduce(0, +) < 10, query.units.count > 1 {
      var covered = all
      if let most = query.mostMatch {
        steps.append(("(\(most)) NOT (\(covered))", true))
        counts.append(try count(steps.last!.match))
        covered = most
      }
      if let any = query.match(any: true) {
        steps.append(("(\(any)) NOT (\(covered))", true))
        counts.append(try count(steps.last!.match))
      }
    }
    let total = counts.reduce(0, +)
    let offset: Int
    if case .offset(let value)? = cursor { offset = value } else { offset = 0 }
    var hits: [RecordSearchHit] = []
    var before = 0
    for (step, n) in zip(steps, counts) {
      defer { before += n }
      guard hits.count < limit, offset + hits.count < before + n else { continue }
      let skip = max(0, offset + hits.count - before)
      hits += try page(step.match, offset: skip, limit: limit - hits.count, partial: step.partial)
    }
    let consumed = offset + hits.count
    let next: RecordSearchCursor? = consumed < total && !hits.isEmpty ? .offset(consumed) : nil
    return RecordSearchPage(hits: hits, next: next, total: cursor == nil ? total : nil)
  }

  static func timeOrderedPage(
    _ db: Database, query: SearchQuery, cursor: RecordSearchCursor?, limit: Int
  ) throws -> RecordSearchPage {
    var filters = [
      "dsn.phase <> 'cancelled'", "uid.parent_session_id IS NULL",
    ]
    var arguments = StatementArguments()
    if let interval = query.interval {
      filters.append("s.created_at >= ? AND s.created_at < ?")
      arguments += [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
    }
    if let source = sourceSQL(
      query.sources, name: "m.source_display_name", mode: "s.input_mode", kind: "uid.item_kind",
      sourceKind: "m.source_kind", identifier: "m.source_identifier")
    {
      filters.append(source.sql)
      arguments += source.arguments
    }
    if let people = query.peopleMatch {
      filters.append(
        """
        s.id IN (SELECT d.session_id FROM record_search_fts
                 JOIN record_search_docs d ON d.doc_id = record_search_fts.rowid
                 WHERE record_search_fts MATCH ?)
        """)
      arguments += [people]
    }
    let from = """
      FROM sessions s
      JOIN dictation_snapshots dsn ON dsn.session_id = s.id
      LEFT JOIN session_metadata m ON m.session_id = s.id
      LEFT JOIN user_item_details uid ON uid.session_id = s.id
      """
    let total =
      cursor == nil
      ? try Int.fetchOne(
        db, sql: "SELECT COUNT(*) \(from) WHERE \(filters.joined(separator: " AND "))",
        arguments: arguments) : nil
    var pageFilters = filters
    var pageArguments = arguments
    if case .before(let createdAt, let sessionID)? = cursor {
      pageFilters.append("(s.created_at < ? OR (s.created_at = ? AND s.id < ?))")
      pageArguments += [createdAt, createdAt, sessionID]
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT s.id, s.created_at \(from)
        WHERE \(pageFilters.joined(separator: " AND "))
        ORDER BY s.created_at DESC, s.id DESC
        LIMIT ?
        """, arguments: pageArguments + [limit + 1])
    let page = rows.prefix(limit)
    let hits = page.compactMap { row -> RecordSearchHit? in
      guard let uuid = UUID(uuidString: row["id"]) else { return nil }
      return RecordSearchHit(
        sessionID: SessionID(uuid), createdAt: Date(timeIntervalSince1970: row["created_at"]),
        score: nil)
    }
    let next: RecordSearchCursor? =
      rows.count > limit
      ? page.last.map { .before(createdAt: $0["created_at"], sessionID: $0["id"]) } : nil
    return RecordSearchPage(hits: hits, next: next, total: total)
  }

  /// A record matches any of the source filters (each: names, prefixes,
  /// modes, item kinds, source kinds, file suffixes).
  static func sourceSQL(
    _ filters: [SearchSourceFilter], name: String, mode: String, kind: String, sourceKind: String,
    identifier: String
  ) -> (sql: String, arguments: StatementArguments)? {
    guard !filters.isEmpty else { return nil }
    var any: [String] = []
    var arguments = StatementArguments()
    func list(_ values: Set<String>) -> String {
      Array(repeating: "?", count: values.count).joined(separator: ", ")
    }
    for filter in filters {
      if !filter.names.isEmpty {
        any.append("\(name) IN (\(list(filter.names)))")
        arguments += StatementArguments(filter.names.sorted())
      }
      for prefix in filter.namePrefixes.sorted() {
        any.append("substr(COALESCE(\(name), ''), 1, ?) = ?")
        arguments += [prefix.count, prefix]
      }
      if !filter.inputModes.isEmpty {
        any.append("\(mode) IN (\(list(filter.inputModes)))")
        arguments += StatementArguments(filter.inputModes.sorted())
      }
      if !filter.sourceKinds.isEmpty {
        any.append("\(sourceKind) IN (\(list(filter.sourceKinds)))")
        arguments += StatementArguments(filter.sourceKinds.sorted())
      }
      if !filter.itemKinds.isEmpty {
        var clause = "\(kind) IN (\(list(filter.itemKinds)))"
        arguments += StatementArguments(filter.itemKinds.sorted())
        if !filter.fileSuffixes.isEmpty {
          let suffixes = filter.fileSuffixes.sorted().map { _ in
            "lower(COALESCE(\(identifier), '')) LIKE ?"
          }
          clause += " AND (" + suffixes.joined(separator: " OR ") + ")"
          arguments += StatementArguments(filter.fileSuffixes.sorted().map { "%" + $0 })
        }
        any.append("(\(clause))")
      }
    }
    guard !any.isEmpty else { return nil }
    return ("(" + any.joined(separator: " OR ") + ")", arguments)
  }

  // MARK: - Lookups for the history page

  /// History rows for these sessions, in their order (a record older than
  /// the App's loaded lists, to play it).
  public func historyItems(sessionIDs: [SessionID]) async throws -> [DictationHistoryItem] {
    let items = try await loadHistory(limit: max(1, sessionIDs.count), sessionIDs: sessionIDs)
    let byID = Dictionary(items.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
    return sessionIDs.compactMap { byID[$0] }
  }

  /// The people search can name: the organizer's people (a merged one's
  /// names join the person it was merged into) and the library's named
  /// voices, with their aliases.
  public nonisolated func recordSearchPeople() async throws -> [SearchPerson] {
    let database = try await requirePool()
    return try await database.read { db in
      struct Entry {
        var name: String
        var aliases: [String]
      }
      var entries: [String: Entry] = [:]
      var merges: [(from: String, into: String)] = []
      for row in try Row.fetchAll(
        db, sql: "SELECT person_id, payload_json FROM remote_organizer_persons")
      {
        let id: String = row["person_id"]
        let data: Data = row["payload_json"]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          continue
        }
        let name = (object["display_name"] as? String) ?? ""
        let aliases = (object["aliases"] as? [String]) ?? []
        entries[id] = Entry(name: name, aliases: aliases)
        if let into = object["merged_into"] as? String, !into.isEmpty { merges.append((id, into)) }
      }
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT id, display_name, aliases_json FROM persons
          WHERE retired_at IS NULL AND merged_into_person_id IS NULL
            AND trim(COALESCE(display_name, '')) <> ''
          """)
      {
        let aliases =
          (try? JSONDecoder().decode(
            [String].self, from: Data(((row["aliases_json"] as String?) ?? "[]").utf8))) ?? []
        entries["library-" + (row["id"] as String)] = Entry(
          name: row["display_name"], aliases: aliases)
      }
      for (from, into) in merges {
        guard let source = entries.removeValue(forKey: from), entries[into] != nil else { continue }
        entries[into]?.aliases += [source.name] + source.aliases
      }
      return entries.compactMap { id, entry -> SearchPerson? in
        let name = entry.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var seen: Set<String> = [name]
        let aliases = entry.aliases.map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty && seen.insert($0).inserted }
        return SearchPerson(id: id, name: name, aliases: aliases)
      }.sorted { $0.id < $1.id }
    }
  }

  /// Source names seen in the library, most used first (search reads them
  /// as source words).
  public nonisolated func recordSourceNames(limit: Int = 60) async throws -> [String] {
    let database = try await requirePool()
    return try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT source_display_name FROM session_metadata
          WHERE source_display_name IS NOT NULL AND source_display_name <> ''
          GROUP BY source_display_name ORDER BY COUNT(*) DESC LIMIT ?
          """, arguments: [limit])
    }
  }
}

extension Array {
  fileprivate func chunked(_ size: Int) -> [ArraySlice<Element>] {
    stride(from: 0, to: count, by: Swift.max(1, size)).map {
      self[$0..<Swift.min($0 + size, count)]
    }
  }
}
