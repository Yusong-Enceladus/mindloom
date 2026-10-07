import BestASRDomain
import BestASRMemory
import Foundation
import GRDB

import struct CryptoKit.SHA256

// v12 search (ALIGNMENT 查-3, 查-6; B4 §3.2b, §3.2e): the record meaning
// index. Every record in the record search index (`record_search_docs`) is
// cut into pieces (`MeaningChunker`); each piece gets one vector from the
// injected `MeaningEmbedding`, stored as 16-bit floats. Derived data only,
// like the character index: rebuilt from the portable tables at any time,
// never exported, emptied when the model (or anything shaping its vectors)
// changes.
//
// Upkeep is incremental and resumable: a record is brought up to date when
// its fingerprint in `record_search_docs` differs from the one stored here;
// a piece whose text did not change keeps its vector; work stops between
// small steps (the caller's `pause` waits while dictation runs) and an
// interrupted run continues where it stopped the next time.

public struct RecordMeaningSyncResult: Equatable, Sendable {
  /// Records brought up to date.
  public let records: Int
  /// Pieces that got a new vector.
  public let embedded: Int
  /// Pieces whose text was unchanged (vector kept).
  public let reused: Int
  /// Records that left the index (deleted, cancelled).
  public let removed: Int
  /// Records still to do when the run stopped early (`maximumRecords`).
  public let remaining: Int
  /// The index was emptied first because the model changed.
  public let rebuilt: Bool
}

/// A record the meaning search found, with its closest piece.
public struct RecordMeaningHit: Equatable, Sendable {
  public let sessionID: SessionID
  public let similarity: Float
  /// The closest piece, in characters of the record's meaning text.
  public let piece: RecordMeaningPiece
}

public struct RecordMeaningPiece: Equatable, Sendable {
  public let start: Int
  public let length: Int
  public let text: String?

  public init(start: Int, length: Int, text: String? = nil) {
    self.start = start
    self.length = length
    self.text = text
  }
}

/// What the meaning side of one search needs: the query's vector, the model
/// it came from (vectors of another model are never compared) and how far
/// apart counts as unrelated.
public struct RecordMeaningQuery: Sendable {
  public let vector: [Float]
  public let modelVersion: String
  /// Pieces less similar than this are not results (calibrated per model).
  public let floor: Float
  public let policy: MeaningFusion.Policy
  /// How many records the meaning side contributes.
  public let depth: Int

  public init(
    vector: [Float], modelVersion: String, floor: Float,
    policy: MeaningFusion.Policy = .standard, depth: Int = 100
  ) {
    self.vector = vector
    self.modelVersion = modelVersion
    self.floor = floor
    self.policy = policy
    self.depth = depth
  }
}

public struct RecordMeaningStatus: Equatable, Sendable {
  /// The model the stored vectors came from (nil before the first run).
  public let modelVersion: String?
  public let records: Int
  public let pieces: Int
  /// Records in the character index without up-to-date vectors.
  public let pending: Int
  /// Bytes of stored vectors.
  public let vectorBytes: Int
}

extension BestASRPersistenceSchema {
  /// Creates the record meaning index when missing (emptied when its
  /// revision changes). Derived, never exported.
  public static func installRecordMeaningIndex(in database: Database) throws {
    let revision = "1"
    let installed = try String.fetchOne(
      database,
      sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-meaning'")
    if installed != revision {
      try database.execute(sql: "DROP TABLE IF EXISTS record_meaning_pieces")
      try database.execute(sql: "DROP TABLE IF EXISTS record_meaning_records")
      try database.execute(sql: "DROP TABLE IF EXISTS agent_meaning_vectors")
      try database.execute(
        sql: """
          DELETE FROM bestasr_derived_index_metadata
          WHERE key IN ('record-meaning-model', 'record-meaning-generation', 'agent-meaning-model')
          """)
    }
    try database.execute(
      sql: """
        CREATE TABLE IF NOT EXISTS record_meaning_pieces (
          piece_id INTEGER PRIMARY KEY,
          session_id TEXT NOT NULL,
          ordinal INTEGER NOT NULL,
          text_sha TEXT NOT NULL,
          start_offset INTEGER NOT NULL,
          length INTEGER NOT NULL,
          vector BLOB NOT NULL,
          UNIQUE(session_id, ordinal)
        );
        CREATE TABLE IF NOT EXISTS record_meaning_records (
          session_id TEXT PRIMARY KEY NOT NULL,
          fingerprint TEXT NOT NULL,
          text_sha TEXT NOT NULL,
          pieces INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS agent_meaning_vectors (
          piece_key TEXT PRIMARY KEY NOT NULL,
          vector BLOB NOT NULL,
          from_search INTEGER NOT NULL,
          stored_at REAL NOT NULL
        );
        """)
    try database.execute(
      sql: """
        INSERT INTO bestasr_derived_index_metadata(key, value) VALUES ('record-meaning', ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """, arguments: [revision])
  }
}

extension GRDBDictationStore {
  /// The model key stored with the vectors: the model's version and the
  /// vector length.
  public static func meaningModelKey(_ modelVersion: String, dimension: Int) -> String {
    "\(modelVersion)|\(dimension)"
  }

  // MARK: - Upkeep

  /// Brings the meaning index up to date with the character index (run
  /// `syncRecordSearchIndex` first). Newest records first. `pause` is
  /// awaited before every step (it may wait, or throw to stop); at most
  /// `maximumRecords` records are done per call (nil: all).
  public nonisolated func syncRecordMeaningIndex(
    embedder: any MeaningEmbedding, recordsPerStep: Int = 16, piecesPerCall: Int = 16,
    maximumRecords: Int? = nil, pause: @Sendable () async throws -> Void = {}
  ) async throws -> RecordMeaningSyncResult {
    let database = try await requirePool()
    let model = Self.meaningModelKey(embedder.modelVersion, dimension: embedder.dimension)
    let rebuilt = try await database.write { db -> Bool in
      let current = try String.fetchOne(
        db,
        sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-meaning-model'")
      guard current != model else { return false }
      try db.execute(sql: "DELETE FROM record_meaning_pieces")
      try db.execute(sql: "DELETE FROM record_meaning_records")
      try db.execute(
        sql: """
          INSERT INTO bestasr_derived_index_metadata(key, value) VALUES ('record-meaning-model', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """, arguments: [model])
      try Self.bumpMeaningGeneration(db)
      return current != nil
    }
    let (live, stored) = try await database.read { db in
      let live = try Row.fetchAll(
        db,
        sql: """
          SELECT session_id, fingerprint FROM record_search_docs
          WHERE hidden = 0 ORDER BY created_at DESC, session_id DESC
          """
      ).map { (id: $0["session_id"] as String, fingerprint: $0["fingerprint"] as String) }
      var stored: [String: String] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT session_id, fingerprint FROM record_meaning_records")
      {
        stored[row["session_id"]] = row["fingerprint"]
      }
      return (live, stored)
    }
    let liveIDs = Set(live.map(\.id))
    let removed = stored.keys.filter { !liveIDs.contains($0) }
    if !removed.isEmpty {
      try await database.write { db in
        for chunk in removed.meaningChunked(300) {
          let json = Self.jsonArray(Array(chunk))
          try db.execute(
            sql:
              "DELETE FROM record_meaning_pieces WHERE session_id IN (SELECT value FROM json_each(?))",
            arguments: [json])
          try db.execute(
            sql:
              "DELETE FROM record_meaning_records WHERE session_id IN (SELECT value FROM json_each(?))",
            arguments: [json])
        }
        try Self.bumpMeaningGeneration(db)
      }
    }
    let changed = live.filter { stored[$0.id] != $0.fingerprint }
    let todo = maximumRecords.map { Array(changed.prefix(max(0, $0))) } ?? changed
    var records = 0
    var embedded = 0
    var reused = 0
    for group in todo.meaningChunked(max(1, recordsPerStep)) {
      try await pause()
      try Task.checkCancellation()
      let ids = group.map(\.id)
      let (texts, existing) = try await database.read { db in
        (
          try Self.meaningTexts(db, ids: ids),
          try Self.storedPieces(db, ids: ids)
        )
      }
      // Pieces per record; a piece whose text is unchanged keeps its vector.
      struct Planned {
        let id: String
        let fingerprint: String
        let textSHA: String
        var pieces: [(chunk: MeaningChunk, sha: String, vector: Data?)]
      }
      var plans: [Planned] = []
      var wanted: [(plan: Int, piece: Int)] = []
      for item in group {
        let text = texts[item.id] ?? ""
        var plan = Planned(
          id: item.id, fingerprint: item.fingerprint, textSHA: Self.meaningSHA(text), pieces: [])
        let old = existing[item.id] ?? [:]
        for chunk in MeaningChunker.chunks(of: text) {
          let sha = Self.meaningSHA(chunk.text)
          plan.pieces.append((chunk, sha, old[sha]))
          if old[sha] == nil { wanted.append((plans.count, plan.pieces.count - 1)) }
        }
        reused += plan.pieces.count - plan.pieces.filter { $0.vector == nil }.count
        plans.append(plan)
      }
      for batch in wanted.meaningChunked(max(1, piecesPerCall)) {
        if embedded > 0 { try await pause() }
        try Task.checkCancellation()
        let inputs = batch.map { plans[$0.plan].pieces[$0.piece].chunk.text }
        let vectors = try await embedder.embed(inputs, role: .document)
        guard vectors.count == inputs.count,
          vectors.allSatisfy({ $0.count == embedder.dimension })
        else { throw RecordMeaningError.badVectors }
        for (slot, vector) in zip(batch, vectors) {
          plans[slot.plan].pieces[slot.piece].vector = MeaningMatrix.pack(
            MeaningMatrix.normalized(vector))
        }
        embedded += batch.count
      }
      try Task.checkCancellation()
      let finished = plans
      try await database.write { db in
        // The model may have changed while this step embedded.
        let current = try String.fetchOne(
          db,
          sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-meaning-model'"
        )
        guard current == model else { throw CancellationError() }
        for plan in finished {
          try db.execute(
            sql: "DELETE FROM record_meaning_pieces WHERE session_id = ?", arguments: [plan.id])
          for (ordinal, piece) in plan.pieces.enumerated() {
            guard let vector = piece.vector else { continue }
            try db.execute(
              sql: """
                INSERT INTO record_meaning_pieces(
                  session_id, ordinal, text_sha, start_offset, length, vector)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
              arguments: [
                plan.id, ordinal, piece.sha, piece.chunk.start, piece.chunk.length, vector,
              ])
          }
          try db.execute(
            sql: """
              INSERT INTO record_meaning_records(session_id, fingerprint, text_sha, pieces)
              VALUES (?, ?, ?, ?)
              ON CONFLICT(session_id) DO UPDATE SET
                fingerprint = excluded.fingerprint, text_sha = excluded.text_sha,
                pieces = excluded.pieces
              """, arguments: [plan.id, plan.fingerprint, plan.textSHA, plan.pieces.count])
        }
        try Self.bumpMeaningGeneration(db)
      }
      records += group.count
    }
    return RecordMeaningSyncResult(
      records: records, embedded: embedded, reused: reused, removed: removed.count,
      remaining: changed.count - todo.count, rebuilt: rebuilt)
  }

  /// How far the meaning index is (sizes only).
  public nonisolated func recordMeaningStatus() async throws -> RecordMeaningStatus {
    let database = try await requirePool()
    return try await database.read { db in
      let model = try String.fetchOne(
        db,
        sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-meaning-model'")
      let records = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_meaning_records") ?? 0
      let pieces = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_meaning_pieces") ?? 0
      let bytes =
        try Int.fetchOne(
          db, sql: "SELECT COALESCE(SUM(length(vector)), 0) FROM record_meaning_pieces")
        ?? 0
      let pending =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM record_search_docs d
            LEFT JOIN record_meaning_records r ON r.session_id = d.session_id
            WHERE d.hidden = 0 AND (r.fingerprint IS NULL OR r.fingerprint <> d.fingerprint)
            """) ?? 0
      return RecordMeaningStatus(
        modelVersion: model, records: records, pieces: pieces, pending: pending,
        vectorBytes: bytes)
    }
  }

  // MARK: - Without the model

  /// Keeps the meaning index honest when no model can bring it up to date
  /// (not downloaded, failing its check, or replaced by an App update):
  /// vectors of records that left the character index (deleted, cancelled,
  /// hidden) go now, and when the stored vectors come from a model other
  /// than `model` (the one this App installs) the whole index goes, the
  /// agents' vectors with it. Run after `syncRecordSearchIndex`. Returns the
  /// records whose vectors were removed.
  @discardableResult
  public nonisolated func pruneRecordMeaningIndex(keepingModel model: String) async throws -> Int {
    let database = try await requirePool()
    let removed = try await database.write { db -> Int in
      let stored = try String.fetchOne(
        db,
        sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-meaning-model'")
      let agents = try String.fetchOne(
        db,
        sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'agent-meaning-model'")
      if let agents, agents != model {
        try db.execute(sql: "DELETE FROM agent_meaning_vectors")
        try db.execute(
          sql: "DELETE FROM bestasr_derived_index_metadata WHERE key = 'agent-meaning-model'")
      }
      if let stored, stored != model {
        let records =
          try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record_meaning_records") ?? 0
        try db.execute(sql: "DELETE FROM record_meaning_pieces")
        try db.execute(sql: "DELETE FROM record_meaning_records")
        try db.execute(
          sql: "DELETE FROM bestasr_derived_index_metadata WHERE key = 'record-meaning-model'")
        try Self.bumpMeaningGeneration(db)
        return records
      }
      let live = "SELECT session_id FROM record_search_docs WHERE hidden = 0"
      try db.execute(sql: "DELETE FROM record_meaning_pieces WHERE session_id NOT IN (\(live))")
      try db.execute(sql: "DELETE FROM record_meaning_records WHERE session_id NOT IN (\(live))")
      let records = db.changesCount
      if records > 0 { try Self.bumpMeaningGeneration(db) }
      return records
    }
    if removed > 0 { RecordMeaningCache.shared.forget(databaseURL.path) }
    return removed
  }

  /// Drops this library's vectors from memory (the model was released after
  /// idle, or the library closes); the next search by meaning reads them
  /// again.
  public nonisolated func forgetRecordMeaningMatrix() {
    RecordMeaningCache.shared.forget(databaseURL.path)
  }

  // MARK: - Agents' vectors

  /// Stored vectors of the pieces other Apps' search compares, by piece key
  /// (a digest of the piece's words exactly as the agent reads them), when
  /// they come from `model`. Derived data like the record meaning index:
  /// rebuilt at any time, never exported.
  public nonisolated func agentMeaningVectors(_ keys: [String], model: String) async throws
    -> [String: [Float]]
  {
    guard !keys.isEmpty else { return [:] }
    let database = try await requirePool()
    return try await database.read { db in
      let stored = try String.fetchOne(
        db,
        sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'agent-meaning-model'")
      guard stored == model else { return [:] }
      var out: [String: [Float]] = [:]
      for chunk in keys.meaningChunked(500) {
        for row in try Row.fetchAll(
          db,
          sql: """
            SELECT piece_key, vector FROM agent_meaning_vectors
            WHERE piece_key IN (SELECT value FROM json_each(?))
            """, arguments: [Self.jsonArray(Array(chunk))])
        {
          let data: Data = row["vector"]
          guard data.count >= 2,
            let vector = MeaningMatrix.unpack(data, dimension: data.count / 2)
          else { continue }
          out[row["piece_key"]] = vector
        }
      }
      return out
    }
  }

  /// The piece keys stored for `model` (the background warm-up embeds only
  /// the others).
  public nonisolated func agentMeaningKeys(model: String) async throws -> Set<String> {
    let database = try await requirePool()
    return try await database.read { db in
      let stored = try String.fetchOne(
        db,
        sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'agent-meaning-model'")
      guard stored == model else { return [] }
      return Set(try String.fetchAll(db, sql: "SELECT piece_key FROM agent_meaning_vectors"))
    }
  }

  /// Keeps new vectors (16-bit floats). Vectors of another model are
  /// dropped first. `fromSearch`: made while a search ran (a grant's masked
  /// words), not by the background warm-up.
  public nonisolated func saveAgentMeaningVectors(
    _ vectors: [String: [Float]], model: String, fromSearch: Bool, at: Date = Date()
  ) async throws {
    guard !vectors.isEmpty else { return }
    let database = try await requirePool()
    try await database.write { db in
      let stored = try String.fetchOne(
        db,
        sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'agent-meaning-model'")
      if stored != model {
        try db.execute(sql: "DELETE FROM agent_meaning_vectors")
        try db.execute(
          sql: """
            INSERT INTO bestasr_derived_index_metadata(key, value) VALUES ('agent-meaning-model', ?)
              ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [model])
      }
      for (key, vector) in vectors {
        try db.execute(
          sql: """
            INSERT INTO agent_meaning_vectors(piece_key, vector, from_search, stored_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(piece_key) DO UPDATE SET
              vector = excluded.vector, from_search = excluded.from_search,
              stored_at = excluded.stored_at
            """,
          arguments: [
            key, MeaningMatrix.pack(MeaningMatrix.normalized(vector)), fromSearch ? 1 : 0,
            at.timeIntervalSince1970,
          ])
      }
    }
  }

  /// After a warm-up over every matter's words: pieces no matter holds any
  /// more go at once (a deleted record's words with them); pieces made while
  /// a search ran (a grant's masked words, which the warm-up cannot make)
  /// go once they are older than `searchPiecesBefore`. Returns how many went.
  @discardableResult
  public nonisolated func pruneAgentMeaningVectors(
    keeping keys: Set<String>, searchPiecesBefore: Date
  ) async throws -> Int {
    let database = try await requirePool()
    return try await database.write { db in
      try db.execute(
        sql: "CREATE TEMP TABLE IF NOT EXISTS agent_meaning_keep(key TEXT PRIMARY KEY)")
      try db.execute(sql: "DELETE FROM agent_meaning_keep")
      for chunk in Array(keys).meaningChunked(500) {
        try db.execute(
          sql: "INSERT OR IGNORE INTO agent_meaning_keep SELECT value FROM json_each(?)",
          arguments: [Self.jsonArray(Array(chunk))])
      }
      try db.execute(
        sql: """
          DELETE FROM agent_meaning_vectors
          WHERE piece_key NOT IN (SELECT key FROM agent_meaning_keep)
            AND (from_search = 0 OR stored_at < ?)
          """, arguments: [searchPiecesBefore.timeIntervalSince1970])
      let removed = db.changesCount
      try db.execute(sql: "DELETE FROM agent_meaning_keep")
      return removed
    }
  }

  /// Drops every agent vector (other Apps may no longer read).
  public nonisolated func clearAgentMeaningVectors() async throws {
    let database = try await requirePool()
    try await database.write { db in
      try db.execute(sql: "DELETE FROM agent_meaning_vectors")
      try db.execute(
        sql: "DELETE FROM bestasr_derived_index_metadata WHERE key = 'agent-meaning-model'")
    }
  }

  static func bumpMeaningGeneration(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO bestasr_derived_index_metadata(key, value) VALUES ('record-meaning-generation', '1')
          ON CONFLICT(key) DO UPDATE SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)
        """)
  }

  /// The text a record is searched by meaning: a title the owner wrote, then
  /// its words (a meeting App's transcript read as 「名字：话」).
  static func meaningTexts(_ db: Database, ids: [String]) throws -> [String: String] {
    let texts = try recordTexts(db, ids: ids)
    let json = jsonArray(ids)
    var titles: [String: String] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT session_id, title FROM session_metadata
        WHERE COALESCE(title_is_user_edited, 0) = 1 AND title IS NOT NULL
          AND session_id IN (SELECT value FROM json_each(?))
        """, arguments: [json])
    {
      titles[row["session_id"]] = row["title"]
    }
    var out: [String: String] = [:]
    for id in ids {
      let raw = texts[id]?.text ?? ""
      let body = MemoryTranscriptText.readable(raw) ?? raw
      let title = titles[id].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
      out[id] = title.isEmpty ? body : title + "\n" + body
    }
    return out
  }

  /// Stored vectors by piece text, per record.
  static func storedPieces(_ db: Database, ids: [String]) throws -> [String: [String: Data]] {
    var out: [String: [String: Data]] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT session_id, text_sha, vector FROM record_meaning_pieces
        WHERE session_id IN (SELECT value FROM json_each(?))
        """, arguments: [jsonArray(ids)])
    {
      out[row["session_id"], default: [:]][row["text_sha"]] = row["vector"]
    }
    return out
  }

  static func meaningSHA(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  static func jsonArray(_ ids: [String]) -> String {
    String(decoding: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8), as: UTF8.self)
  }

  // MARK: - Search

  /// Records nearest in meaning to `query.vector` that fit the query's
  /// conditions (time, source, people), best first; nothing below
  /// `query.floor`. Empty when the stored vectors come from another model.
  public nonisolated func searchRecordMeaning(
    _ query: SearchQuery, meaning: RecordMeaningQuery, limit: Int = 100
  ) async throws -> [RecordMeaningHit] {
    let database = try await requirePool()
    let key = Self.meaningModelKey(meaning.modelVersion, dimension: meaning.vector.count)
    let loaded = try await RecordMeaningCache.shared.matrix(
      for: databaseURL.path, model: key, database: database)
    guard let loaded, loaded.matrix.count > 0 else { return [] }
    let allowed = try await database.read { db in
      try Self.meaningAllowed(db, query: query)
    }
    let vector = MeaningMatrix.normalized(meaning.vector)
    let best = loaded.matrix.best(
      vector, allowed: allowed.map { set in { set.contains($0) } }, floor: meaning.floor,
      limit: limit)
    return best.compactMap { hit in
      guard let uuid = UUID(uuidString: hit.owner) else { return nil }
      return RecordMeaningHit(
        sessionID: SessionID(uuid), similarity: hit.similarity,
        piece: RecordMeaningPiece(
          start: Int(loaded.pieceStart[hit.row]), length: Int(loaded.pieceLength[hit.row])))
    }
  }

  /// The records a query's conditions allow (nil: all of them).
  static func meaningAllowed(_ db: Database, query: SearchQuery) throws -> Set<String>? {
    var filters: [String] = []
    var arguments = StatementArguments()
    if let interval = query.interval {
      filters.append("d.created_at >= ? AND d.created_at < ?")
      arguments += [interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970]
    }
    if let source = sourceSQL(
      query.sources, name: "d.source_name", mode: "d.input_mode", kind: "d.item_kind",
      sourceKind: "d.source_kind", identifier: "d.source_identifier")
    {
      filters.append(source.sql)
      arguments += source.arguments
    }
    if let people = query.peopleMatch {
      filters.append(
        """
        d.doc_id IN (SELECT rowid FROM record_search_fts WHERE record_search_fts MATCH ?)
        """)
      arguments += [people]
    }
    guard !filters.isEmpty else { return nil }
    filters.append("d.hidden = 0")
    return Set(
      try String.fetchAll(
        db,
        sql: "SELECT d.session_id FROM record_search_docs d WHERE "
          + filters.joined(separator: " AND "), arguments: arguments
      ).map { $0.uppercased() })
  }

  /// One page of a search by characters and by meaning together
  /// (`MeaningFusion`). Without `meaning`, or for a query that only names a
  /// time, a source or a person, this is `searchRecords(_:cursor:limit:now:)`.
  public nonisolated func searchRecords(
    _ query: SearchQuery, meaning: RecordMeaningQuery?, cursor: RecordSearchCursor? = nil,
    limit: Int = 50, now: Date = Date()
  ) async throws -> RecordSearchPage {
    guard let meaning, MeaningQueryText.asksMeaning(query) else {
      return try await searchRecords(query, cursor: cursor, limit: limit, now: now)
    }
    let database = try await requirePool()
    let bounded = max(1, min(limit, 1_000))
    let lexical = try await database.read { db in
      try Self.rankedList(db, query: query, now: now)
    }
    let found = try await searchRecordMeaning(query, meaning: meaning, limit: meaning.depth)
    let fused = MeaningFusion.fuse(
      lexical: lexical.map { MeaningFusion.Lexical(id: $0.id, partial: $0.partial) },
      meaning: found.map {
        MeaningFusion.Meaning(
          id: $0.sessionID.rawValue.uuidString.uppercased(), similarity: $0.similarity)
      }, policy: meaning.policy)
    var created: [String: Double] = [:]
    for hit in lexical { created[hit.id] = hit.createdAt }
    // Records found only by meaning must still be in the library: the
    // vectors of a record deleted or cancelled since the last upkeep stay
    // until the next one, and are neither shown nor counted.
    let missing = fused.map(\.id).filter { created[$0] == nil }
    if !missing.isEmpty {
      let extra = try await database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT session_id, created_at FROM record_search_docs
            WHERE hidden = 0 AND session_id IN (SELECT value FROM json_each(?))
            """, arguments: [Self.jsonArray(missing)]
        ).map { (($0["session_id"] as String).uppercased(), $0["created_at"] as Double) }
      }
      for (id, at) in extra { created[id] = at }
    }
    let live = fused.filter { created[$0.id] != nil }
    let offset: Int
    if case .offset(let value)? = cursor { offset = value } else { offset = 0 }
    let page = Array(live.dropFirst(offset).prefix(bounded))
    var pieces = Dictionary(
      found.map { ($0.sessionID.rawValue.uuidString.uppercased(), $0.piece) },
      uniquingKeysWith: { a, _ in a })
    // The closest piece's words, for the row's line (only this page's).
    let shown = page.map(\.id).filter { pieces[$0] != nil }
    if !shown.isEmpty {
      let texts = try await database.read { db in try Self.meaningTexts(db, ids: shown) }
      for id in shown {
        guard let piece = pieces[id], let text = texts[id] else { continue }
        let characters = Array(text)
        let start = min(max(0, piece.start), characters.count)
        let end = min(characters.count, start + max(0, piece.length))
        pieces[id] = RecordMeaningPiece(
          start: piece.start, length: piece.length,
          text: String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    let hits = page.compactMap { item -> RecordSearchHit? in
      guard let uuid = UUID(uuidString: item.id), let at = created[item.id] else { return nil }
      return RecordSearchHit(
        sessionID: SessionID(uuid), createdAt: Date(timeIntervalSince1970: at),
        score: item.score, partial: item.partial, meaningOnly: item.meaningOnly,
        meaningPiece: pieces[item.id])
    }
    let consumed = offset + page.count
    let next: RecordSearchCursor? =
      consumed < live.count && !page.isEmpty ? .offset(consumed) : nil
    return RecordSearchPage(hits: hits, next: next, total: cursor == nil ? live.count : nil)
  }

  /// The character search's whole ranking for a query (the steps of
  /// `rankedPage`, in order), at most `cap` records.
  static func rankedList(
    _ db: Database, query: SearchQuery, now: Date, cap: Int = 5_000
  ) throws -> [(id: String, createdAt: Double, partial: Bool)] {
    var out: [(id: String, createdAt: Double, partial: Bool)] = []
    var cursor: RecordSearchCursor?
    repeat {
      let page = try rankedPage(db, query: query, cursor: cursor, limit: 1_000, now: now)
      out += page.hits.map {
        (
          $0.sessionID.rawValue.uuidString.uppercased(), $0.createdAt.timeIntervalSince1970,
          $0.partial
        )
      }
      cursor = page.next
    } while cursor != nil && out.count < cap
    return Array(out.prefix(cap))
  }
}

enum RecordMeaningError: Error {
  case badVectors
}

/// The stored vectors of each open library, in memory between searches;
/// read again when the index changed (its generation) or another model is
/// asked for.
final class RecordMeaningCache: @unchecked Sendable {
  static let shared = RecordMeaningCache()

  struct Loaded: Sendable {
    let model: String
    let generation: String
    let matrix: MeaningMatrix
    let pieceStart: [Int32]
    let pieceLength: [Int32]
  }

  private let lock = NSLock()
  private var entries: [String: Loaded] = [:]

  func matrix(for path: String, model: String, database: DatabasePool) async throws -> Loaded? {
    let (storedModel, generation) = try await database.read { db in
      (
        try String.fetchOne(
          db,
          sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-meaning-model'"
        ),
        try String.fetchOne(
          db,
          sql:
            "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'record-meaning-generation'"
        )
          ?? "0"
      )
    }
    guard storedModel == model else {
      // Vectors of another model are never compared: nothing of them stays.
      forget(path)
      return nil
    }
    if let hit = lock.withLock({ entries[path] }), hit.model == model, hit.generation == generation
    {
      return hit
    }
    let dimension = Int(model.split(separator: "|").last.flatMap { Int($0) } ?? 0)
    guard dimension > 0 else { return nil }
    let loaded = try await database.read { db -> Loaded in
      var values: [Float] = []
      var owners: [String] = []
      var ownerIndex: [String: Int32] = [:]
      var rowOwner: [Int32] = []
      var starts: [Int32] = []
      var lengths: [Int32] = []
      let cursor = try Row.fetchCursor(
        db,
        sql: """
          SELECT session_id, start_offset, length, vector FROM record_meaning_pieces
          ORDER BY session_id, ordinal
          """)
      while let row = try cursor.next() {
        let data: Data = row["vector"]
        guard let vector = MeaningMatrix.unpack(data, dimension: dimension) else { continue }
        let id = (row["session_id"] as String).uppercased()
        let owner: Int32
        if let known = ownerIndex[id] {
          owner = known
        } else {
          owner = Int32(owners.count)
          ownerIndex[id] = owner
          owners.append(id)
        }
        values += vector
        rowOwner.append(owner)
        starts.append(Int32(truncatingIfNeeded: row["start_offset"] as Int))
        lengths.append(Int32(truncatingIfNeeded: row["length"] as Int))
      }
      return Loaded(
        model: model, generation: generation,
        matrix: MeaningMatrix(
          dimension: dimension, values: values, rowOwner: rowOwner, owners: owners),
        pieceStart: starts, pieceLength: lengths)
    }
    lock.withLock { entries[path] = loaded }
    return loaded
  }

  /// Forgets a library's vectors (the model was released after idle, the
  /// library closes, or its vectors are of another model).
  func forget(_ path: String) {
    lock.withLock { _ = entries.removeValue(forKey: path) }
  }

  /// Libraries whose vectors are in memory (for tests).
  var paths: Set<String> { lock.withLock { Set(entries.keys) } }
}

extension Array {
  fileprivate func meaningChunked(_ size: Int) -> [ArraySlice<Element>] {
    stride(from: 0, to: count, by: Swift.max(1, size)).map {
      self[$0..<Swift.min($0 + size, count)]
    }
  }
}
