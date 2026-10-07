import BestASRDictation
import BestASRDomain
import Foundation
import GRDB

/// What learning one correction did.
public struct LearnedCorrectionOutcome: Equatable, Sendable {
  public let entryID: DictionaryEntryID
  /// How many times this exact correction has now been seen.
  public let times: Int
  /// The word is in what the recognizer is told to expect.
  public let usedForRecognition: Bool
  /// Learning made the word (it is listed under 自动添加).
  public let createdEntry: Bool
}

/// What 自动添加 lists: a dictionary word learning made, or the forms
/// learning added to a word the user made (`learnedForms`).
public struct AutomaticDictionaryEntry: Equatable, Sendable {
  public let entryID: DictionaryEntryID
  /// The most times one of its corrections was seen.
  public let times: Int
  public let usedForRecognition: Bool
  public let lastSource: String
  public let lastAt: Date
  /// For a word the user made: the 「识别为」 forms corrections added to it,
  /// which the user can remove (review 10-6 S15). Empty for a word learning
  /// made (the whole word is listed and deleted).
  public let learnedForms: [String]
}

extension GRDBDictationStore {
  /// The user changed `heard` (what dictation wrote) to `written` (ALIGNMENT
  /// 收1-8). The first time, `written` becomes a dictionary word with `heard`
  /// as a form it is heard as — a replacement, listed under 自动添加 — or,
  /// when the dictionary already has `written`, that word gains `heard`. The
  /// second time the same correction is seen, a word learning made also
  /// joins what the recognizer is told to expect (`dictionaryContext`).
  ///
  /// Each call is one sighting. Existing derived texts are not marked stale:
  /// what is learned applies to dictations from now on. Nil when the user
  /// deleted the word this correction made or joined: a deleted word is not
  /// learned again.
  public func learnCorrection(
    heard: String, written: String, source: String, at date: Date? = nil
  ) async throws -> LearnedCorrectionOutcome? {
    let heardForm = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    let writtenForm = written.trimmingCharacters(in: .whitespacesAndNewlines)
    let pairKey = Self.correctionKey(heardForm) + "\u{1F}" + Self.correctionKey(writtenForm)
    guard !heardForm.isEmpty, !writtenForm.isEmpty,
      Self.correctionKey(heardForm) != Self.correctionKey(writtenForm),
      ["field", "selection", "history"].contains(source)
    else { throw BestASRPersistenceError.invalidSnapshot }
    let now = Self.databaseDate(date ?? clock.wallTime())
    let database = try requirePool()
    return try await database.write { db in
      // The word that holds this correction: the one it made or joined
      // before, while it is still in the dictionary, else a live word
      // written this way, else a new one.
      let existing = try Row.fetchOne(
        db, sql: "SELECT * FROM learned_corrections WHERE pair_key = ?", arguments: [pairKey])
      if (existing?["dismissed_at"] as Double?) != nil { return nil }
      var entry: DictionaryEntry?
      if let id: String = existing?["dictionary_entry_id"] {
        entry = try Row.fetchOne(
          db,
          sql: "SELECT * FROM dictionary_entries WHERE id = ? AND tombstoned_at IS NULL",
          arguments: [id]
        ).map(Self.dictionaryEntry)
      }
      var createdEntry = (existing?["created_entry"] as Int64? ?? 0) == 1
      if entry == nil {
        entry = try Row.fetchOne(
          db,
          sql: """
            SELECT * FROM dictionary_entries
            WHERE tombstoned_at IS NULL AND canonical_form = ? COLLATE NOCASE
            ORDER BY created_at, id LIMIT 1
            """,
          arguments: [writtenForm]
        ).map(Self.dictionaryEntry)
        createdEntry = entry == nil
      }
      let current: DictionaryEntry
      if let entry {
        current = entry
      } else {
        current = try DictionaryEntry(
          revision: Revision(1), canonicalForm: writtenForm, spokenForms: [],
          enabled: true, createdAt: now, updatedAt: now)
        try db.execute(
          sql: """
            INSERT INTO dictionary_entries (
              id, revision, canonical_form, spoken_forms_json, enabled,
              created_at, updated_at, tombstoned_at
            ) VALUES (?, 1, ?, '[]', 1, ?, ?, NULL)
            """,
          arguments: [
            current.id.rawValue.uuidString, writtenForm, now.timeIntervalSince1970,
            now.timeIntervalSince1970,
          ])
      }
      // `heard` becomes a form the word is heard as, unless it is one already
      // (or the word is full: 32 forms).
      let known = current.spokenForms.contains {
        Self.correctionKey($0) == Self.correctionKey(heardForm)
      }
      if !known, current.spokenForms.count < 32,
        Self.correctionKey(current.canonicalForm) != Self.correctionKey(heardForm)
      {
        let updated = try DictionaryEntry(
          id: current.id, revision: Revision(current.revision.value + 1),
          canonicalForm: current.canonicalForm, spokenForms: current.spokenForms + [heardForm],
          enabled: current.enabled, createdAt: current.createdAt,
          updatedAt: max(now, current.createdAt))
        try db.execute(
          sql: """
            UPDATE dictionary_entries SET revision = ?, spoken_forms_json = ?, updated_at = ?
            WHERE id = ? AND revision = ?
            """,
          arguments: [
            try Self.sqliteInt(updated.revision.value),
            try Self.dictionaryJSONValue(updated.spokenForms),
            updated.updatedAt.timeIntervalSince1970,
            current.id.rawValue.uuidString,
            try Self.sqliteInt(current.revision.value),
          ])
      }
      let times: Int
      if let existing {
        times = Int(existing["times"] as Int64) + 1
        try db.execute(
          sql: """
            UPDATE learned_corrections
            SET times = ?, last_source = ?, last_at = ?, dictionary_entry_id = ?, created_entry = ?
            WHERE pair_key = ?
            """,
          arguments: [
            times, source, now.timeIntervalSince1970, current.id.rawValue.uuidString,
            createdEntry ? 1 : 0, pairKey,
          ])
      } else {
        times = 1
        try db.execute(
          sql: """
            INSERT INTO learned_corrections (
              id, heard, written, pair_key, times, last_source, dictionary_entry_id,
              created_entry, first_at, last_at
            ) VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
            """,
          arguments: [
            UUID().uuidString, heardForm, writtenForm, pairKey, source,
            current.id.rawValue.uuidString, createdEntry ? 1 : 0,
            now.timeIntervalSince1970, now.timeIntervalSince1970,
          ])
      }
      let replacementOnly = try Self.replacementOnlyDictionaryEntryIDs(db)
      return LearnedCorrectionOutcome(
        entryID: current.id, times: times,
        usedForRecognition: !replacementOnly.contains(current.id),
        createdEntry: createdEntry)
    }
  }

  /// The words learning made, for 自动添加.
  public func automaticDictionaryEntries() async throws -> [AutomaticDictionaryEntry] {
    let database = try requirePool()
    return try await database.read { db in
      let replacementOnly = try Self.replacementOnlyDictionaryEntryIDs(db)
      return try Row.fetchAll(
        db,
        sql: """
          SELECT l.dictionary_entry_id AS id, MAX(l.times) AS times,
                 MAX(l.last_at) AS last_at,
                 (SELECT x.last_source FROM learned_corrections x
                  WHERE x.dictionary_entry_id = l.dictionary_entry_id
                  ORDER BY x.last_at DESC LIMIT 1) AS last_source
          FROM learned_corrections l
          JOIN dictionary_entries e ON e.id = l.dictionary_entry_id
          WHERE l.created_entry = 1 AND l.dismissed_at IS NULL AND e.tombstoned_at IS NULL
          GROUP BY l.dictionary_entry_id
          ORDER BY last_at DESC
          """
      ).compactMap { row in
        guard let uuid = UUID(uuidString: row["id"]) else { return nil }
        let id = DictionaryEntryID(uuid)
        return AutomaticDictionaryEntry(
          entryID: id, times: Int(row["times"] as Int64),
          usedForRecognition: !replacementOnly.contains(id),
          lastSource: row["last_source"] ?? "field",
          lastAt: Date(timeIntervalSince1970: row["last_at"]), learnedForms: [])
      } + Self.learnedFormsOfUserWords(db)
    }
  }

  /// The words the user made that corrections added forms to, each with the
  /// forms still on it.
  static func learnedFormsOfUserWords(_ db: Database) throws -> [AutomaticDictionaryEntry] {
    let learnedWords = try learnedDictionaryEntryIDs(db)
    var byEntry: [DictionaryEntryID: [Row]] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM learned_corrections
        WHERE created_entry = 0 AND dismissed_at IS NULL ORDER BY first_at, id
        """)
    {
      guard let value: String = row["dictionary_entry_id"], let uuid = UUID(uuidString: value)
      else { continue }
      let id = DictionaryEntryID(uuid)
      guard !learnedWords.contains(id) else { continue }
      byEntry[id, default: []].append(row)
    }
    return try byEntry.compactMap { id, rows -> AutomaticDictionaryEntry? in
      guard
        let entry = try Row.fetchOne(
          db, sql: "SELECT * FROM dictionary_entries WHERE id = ? AND tombstoned_at IS NULL",
          arguments: [id.rawValue.uuidString]
        ).map(Self.dictionaryEntry)
      else { return nil }
      let onWord = Set(entry.spokenForms.map(correctionKey))
      var forms: [String] = []
      for row in rows {
        let heard: String = row["heard"]
        if onWord.contains(correctionKey(heard)), !forms.contains(heard) { forms.append(heard) }
      }
      guard !forms.isEmpty else { return nil }
      let latest = rows.max { ($0["last_at"] as Double) < ($1["last_at"] as Double) }
      return AutomaticDictionaryEntry(
        entryID: id, times: rows.map { Int($0["times"] as Int64) }.max() ?? 1,
        usedForRecognition: true, lastSource: latest?["last_source"] ?? "field",
        lastAt: Date(timeIntervalSince1970: latest?["last_at"] ?? 0), learnedForms: forms)
    }.sorted { $0.lastAt > $1.lastAt }
  }

  /// The user removed what corrections added to one of their words: the
  /// forms leave the word, and the same corrections are not learned again
  /// (as for a learned word that is deleted).
  public func forgetLearnedForms(entryID: DictionaryEntryID, at date: Date? = nil) async throws {
    let now = Self.databaseDate(date ?? clock.wallTime())
    let database = try requirePool()
    try await database.write { db in
      guard
        let entry = try Row.fetchOne(
          db, sql: "SELECT * FROM dictionary_entries WHERE id = ? AND tombstoned_at IS NULL",
          arguments: [entryID.rawValue.uuidString]
        ).map(Self.dictionaryEntry)
      else { throw BestASRPersistenceError.missingSession }
      let heard = Set(
        try String.fetchAll(
          db,
          sql: """
            SELECT heard FROM learned_corrections
            WHERE dictionary_entry_id = ? AND created_entry = 0 AND dismissed_at IS NULL
            """,
          arguments: [entryID.rawValue.uuidString]
        ).map(Self.correctionKey))
      let kept = entry.spokenForms.filter { !heard.contains(Self.correctionKey($0)) }
      if kept != entry.spokenForms {
        try db.execute(
          sql: """
            UPDATE dictionary_entries SET revision = revision + 1, spoken_forms_json = ?,
              updated_at = ?
            WHERE id = ?
            """,
          arguments: [
            try Self.dictionaryJSONValue(kept), max(now, entry.createdAt).timeIntervalSince1970,
            entryID.rawValue.uuidString,
          ])
      }
      try db.execute(
        sql: """
          UPDATE learned_corrections SET dismissed_at = ?
          WHERE dictionary_entry_id = ? AND created_entry = 0 AND dismissed_at IS NULL
          """,
        arguments: [now.timeIntervalSince1970, entryID.rawValue.uuidString])
    }
  }

  /// Words learning made whose corrections have each been seen only once:
  /// replacements, not yet part of what the recognizer expects.
  static func replacementOnlyDictionaryEntryIDs(_ db: Database) throws -> Set<DictionaryEntryID> {
    Set(
      try String.fetchAll(
        db,
        sql: """
          SELECT dictionary_entry_id FROM learned_corrections
          WHERE dismissed_at IS NULL
          GROUP BY dictionary_entry_id
          HAVING MAX(created_entry) = 1 AND MAX(times) < 2
          """
      ).compactMap { UUID(uuidString: $0).map(DictionaryEntryID.init) })
  }

  /// Words learning made (自动添加), still in the dictionary or not.
  static func learnedDictionaryEntryIDs(_ db: Database) throws -> Set<DictionaryEntryID> {
    Set(
      try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT dictionary_entry_id FROM learned_corrections
          WHERE created_entry = 1 AND dismissed_at IS NULL
          """
      ).compactMap { UUID(uuidString: $0).map(DictionaryEntryID.init) })
  }

  /// The forms corrections added to words, by word (the word's own forms are
  /// not here). The projection replaces these only as whole words.
  static func learnedForms(_ db: Database) throws -> [DictionaryEntryID: [String]] {
    var result: [DictionaryEntryID: [String]] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT dictionary_entry_id, heard FROM learned_corrections
        WHERE dismissed_at IS NULL ORDER BY first_at, id
        """)
    {
      guard let value: String = row["dictionary_entry_id"], let uuid = UUID(uuidString: value),
        let heard: String = row["heard"]
      else { continue }
      result[DictionaryEntryID(uuid), default: []].append(heard)
    }
    return result
  }

  /// Corrections are matched without regard to case or full/half width.
  static func correctionKey(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.lowercased()
  }
}
