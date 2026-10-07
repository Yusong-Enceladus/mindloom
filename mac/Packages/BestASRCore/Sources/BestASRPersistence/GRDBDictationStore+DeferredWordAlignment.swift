import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation
import GRDB

// Dictation's word timings, later (DICTATION_ARCHITECTURE §15.7): a
// dictation is recognized without them, each recognizer window stored as one
// segment marked `DeferredWordAlignment.isPending`. Once the recognizer has
// left memory the aligner times its sentences and each marked segment is
// replaced by them, in place: the transcript's text, revision, time span and
// every other segment stay as they are, and what referred to the window in
// that revision now refers to its sentences. This in-place change is the one
// exception to "a revision's rows never change" (TECHNICAL_DESIGN, 词级时间
// 后补): the revision's text is the same, only the time of each sentence is
// added; the organizer queue is told as for a new revision.

/// A finished dictation's revision (its final transcript, or the user's edit
/// of it, which copies the window with its ID) that still has windows whose
/// sentences are to be timed.
public struct DeferredWordAlignmentWork: Equatable, Sendable {
  public let transcript: DictationPersistedTranscriptRecord
  /// Its window segments still marked pending, in order.
  public let pendingSegments: [DictationTranscriptSegment]

  public init(
    transcript: DictationPersistedTranscriptRecord,
    pendingSegments: [DictationTranscriptSegment]
  ) {
    self.transcript = transcript
    self.pendingSegments = pendingSegments
  }
}

extension GRDBDictationStore {
  /// Revisions of finished dictations recognized by `modelArtifactID` that
  /// still have windows to time, newest first; only `sessionID` when given.
  /// The user's edits count too: they copy the window segment, ID and all,
  /// and History shows the newest revision (review 2026-10-07: only the
  /// final transcript was timed, and an edited dictation stayed one window
  /// for good). A dictation that has not finished (still being processed,
  /// or failed and open to a retry) is left alone: its processing commit may
  /// be replayed, and a replay must find the rows it wrote.
  public func deferredWordAlignmentWork(
    modelArtifactID: String, sessionID: SessionID? = nil, limit: Int
  ) async throws -> [DeferredWordAlignmentWork] {
    let database = try requirePool()
    let candidates: [(transcript: String, session: String)] = try await database.read { db in
      var arguments: StatementArguments = [modelArtifactID]
      var sessionFilter = ""
      if let sessionID {
        sessionFilter = "AND t.session_id = ?"
        arguments += [sessionID.rawValue.uuidString]
      }
      arguments += [max(0, limit)]
      // Version 8 is the UUID's 13th hex digit: the 15th character of its
      // string form.
      return try Row.fetchAll(
        db,
        sql: """
          SELECT t.id AS transcript_id, t.session_id AS session_id
          FROM transcript_revisions t
          JOIN sessions s ON s.id = t.session_id
          JOIN dictation_snapshots d ON d.session_id = t.session_id
          WHERE t.kind IN ('final', 'userEdit')
            AND s.input_mode = 'dictation' AND d.phase = 'completed'
            AND EXISTS (
              SELECT 1 FROM transcript_revisions f
              WHERE f.session_id = t.session_id AND f.kind = 'final'
                AND f.model_artifact_id = ?)
            AND EXISTS (
              SELECT 1 FROM transcript_segments ts
              WHERE ts.transcript_id = t.id AND substr(ts.segment_id, 15, 1) = '8')
            \(sessionFilter)
          ORDER BY t.created_at DESC, t.id DESC
          LIMIT ?
          """,
        arguments: arguments
      ).map { ($0["transcript_id"], $0["session_id"]) }
    }
    var work: [DeferredWordAlignmentWork] = []
    var loaded: [String: [DictationPersistedTranscriptRecord]] = [:]
    for candidate in candidates {
      guard let sessionUUID = UUID(uuidString: candidate.session) else { continue }
      let records: [DictationPersistedTranscriptRecord]
      if let known = loaded[candidate.session] {
        records = known
      } else {
        records = try await loadTranscripts(sessionID: SessionID(sessionUUID))
        loaded[candidate.session] = records
      }
      guard
        let record = records.first(where: {
          $0.id.rawValue.uuidString == candidate.transcript
        })
      else { continue }
      let pending = record.segments.filter { DeferredWordAlignment.isPending($0.id) }
      guard !pending.isEmpty else { continue }
      work.append(DeferredWordAlignmentWork(transcript: record, pendingSegments: pending))
    }
    return work
  }

  /// Replaces the pending window segment `pending` of `transcriptID` (a
  /// dictation's final transcript or the user's edit of it) with its timed
  /// `sentences`, in one transaction. False, changing nothing, when that
  /// segment is no longer there as it was read (already timed, or the
  /// transcript was removed). Throws, changing nothing, when the sentences
  /// do not hold exactly the window's text, in order, spanning exactly its
  /// time range. Event documents that cited the window in this revision cite
  /// its sentences afterwards; the session's organizer job is marked
  /// changed, as a new revision marks it.
  @discardableResult
  public func replaceDeferredWordAlignmentSegment(
    transcriptID: TranscriptRevisionID,
    pending: DictationTranscriptSegment,
    with sentences: [DictationTranscriptSegment]
  ) async throws -> Bool {
    guard DeferredWordAlignment.isPending(pending.id),
      Self.sentencesCover(pending, sentences)
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    let transcript = transcriptID.rawValue.uuidString
    return try await database.write { db in
      guard
        let session = try String.fetchOne(
          db,
          sql: """
            SELECT session_id FROM transcript_revisions
            WHERE id = ? AND kind IN ('final', 'userEdit')
            """,
          arguments: [transcript])
      else { return false }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT segment_id, monotonic_start_ns, monotonic_end_ns, text, confidence
          FROM transcript_segments WHERE transcript_id = ? ORDER BY ordinal
          """,
        arguments: [transcript])
      guard
        let index = rows.firstIndex(where: {
          ($0["segment_id"] as String) == pending.id.uuidString
        })
      else { return false }
      let current = rows[index]
      guard (current["monotonic_start_ns"] as Int64) == Int64(pending.monotonicStartNanoseconds),
        (current["monotonic_end_ns"] as Int64) == Int64(pending.monotonicEndNanoseconds),
        (current["text"] as String) == pending.text
      else { return false }
      let others = Set(rows.map { $0["segment_id"] as String })
      guard
        sentences.allSatisfy({ !others.contains($0.id.uuidString) }),
        Set(sentences.map(\.id)).count == sentences.count
      else { throw BestASRPersistenceError.invalidSnapshot }

      let before = rows[..<index].map(StoredSegmentRow.init(row:))
      let after = rows[(index + 1)...].map(StoredSegmentRow.init(row:))
      let timed = sentences.map(StoredSegmentRow.init(segment:))
      try db.execute(
        sql: "DELETE FROM transcript_segments WHERE transcript_id = ?", arguments: [transcript])
      for (ordinal, segment) in (before + timed + after).enumerated() {
        try db.execute(
          sql: """
            INSERT INTO transcript_segments (
              transcript_id, segment_id, ordinal, monotonic_start_ns,
              monotonic_end_ns, text, confidence
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            transcript, segment.id, ordinal, segment.start, segment.end, segment.text,
            segment.confidence,
          ])
      }
      try Self.citeSentences(
        insteadOf: pending.id, sentences: sentences.map(\.id), transcriptID: transcriptID,
        in: db)
      try Self.markOrganizerItemChanged(session: session, in: db)
      return true
    }
  }

  /// The sentences lie in order inside the window, the first starting where
  /// it starts and the last ending where it ends (the transcript's time
  /// span, which a shared space's times count from, stays), and hold its
  /// text: the same characters, whitespace aside.
  nonisolated static func sentencesCover(
    _ pending: DictationTranscriptSegment, _ sentences: [DictationTranscriptSegment]
  ) -> Bool {
    guard !sentences.isEmpty, sentences.count <= 4_096,
      sentences.first?.monotonicStartNanoseconds == pending.monotonicStartNanoseconds,
      sentences.last?.monotonicEndNanoseconds == pending.monotonicEndNanoseconds
    else { return false }
    var previousEnd = pending.monotonicStartNanoseconds
    for sentence in sentences {
      guard !DeferredWordAlignment.isPending(sentence.id),
        !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        sentence.monotonicStartNanoseconds >= previousEnd,
        sentence.monotonicStartNanoseconds < sentence.monotonicEndNanoseconds,
        sentence.monotonicEndNanoseconds <= pending.monotonicEndNanoseconds,
        sentence.monotonicEndNanoseconds <= UInt64(Int64.max)
      else { return false }
      previousEnd = sentence.monotonicEndNanoseconds
    }
    func visible(_ text: String) -> String {
      String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    return visible(sentences.map(\.text).joined()) == visible(pending.text)
  }

  /// Event documents written while the window was one segment cite its ID;
  /// those that cite it in `transcriptID` cite every one of its sentences
  /// instead (review 2026-10-07: a document citing another revision, such
  /// as the user's edit that copied the window, keeps its references, which
  /// must be segments of that revision). The IDs only ever appear as
  /// elements of ID lists in the stored JSON (UUIDs encode upper-case). A
  /// document cites one revision of a session, so the window's ID in it
  /// stands for this revision: the element is replaced by the sentences'
  /// IDs in both columns and everything else stays byte for byte. When
  /// another reference of the same document cites the window too, only this
  /// revision's references change and the result keeps citing the window,
  /// which that other reference still holds.
  private nonisolated static func citeSentences(
    insteadOf window: UUID, sentences: [UUID], transcriptID: TranscriptRevisionID,
    in db: Database
  ) throws {
    let old = "\"\(window.uuidString)\""
    let new = sentences.map { "\"\($0.uuidString)\"" }.joined(separator: ",")
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT id, source_references_json, result_json FROM event_text_documents
        WHERE instr(CAST(source_references_json AS TEXT), ?) > 0
        """,
      arguments: [window.uuidString])
    for row in rows {
      let id: String = row["id"]
      let referencesData: Data = row["source_references_json"]
      let resultData: Data = row["result_json"]
      guard
        var references = (try? JSONSerialization.jsonObject(with: referencesData))
          as? [[String: Any]]
      else { continue }
      func cites(_ reference: [String: Any]) -> Bool {
        ((reference["segmentIDs"] as? [String]) ?? []).contains {
          UUID(uuidString: $0) == window
        }
      }
      func isTimed(_ reference: [String: Any]) -> Bool {
        (reference["transcriptRevisionID"] as? String).flatMap(UUID.init(uuidString:))
          == transcriptID.rawValue
      }
      guard references.contains(where: { isTimed($0) && cites($0) }) else { continue }
      let updatedReferences: Data
      let updatedResult: Data
      if references.contains(where: { !isTimed($0) && cites($0) }) {
        for index in references.indices where isTimed(references[index]) {
          let ids = (references[index]["segmentIDs"] as? [String]) ?? []
          references[index]["segmentIDs"] = ids.flatMap {
            UUID(uuidString: $0) == window ? sentences.map(\.uuidString) : [$0]
          }
        }
        updatedReferences = try JSONSerialization.data(
          withJSONObject: references, options: [.sortedKeys, .withoutEscapingSlashes])
        updatedResult = resultData
      } else {
        guard let referencesText = String(data: referencesData, encoding: .utf8),
          let resultText = String(data: resultData, encoding: .utf8)
        else { continue }
        updatedReferences = Data(referencesText.replacingOccurrences(of: old, with: new).utf8)
        updatedResult = Data(resultText.replacingOccurrences(of: old, with: new).utf8)
      }
      // Leave a document alone rather than store one that does not parse.
      guard (try? JSONSerialization.jsonObject(with: updatedReferences)) != nil,
        (try? JSONSerialization.jsonObject(with: updatedResult)) != nil
      else { continue }
      try db.execute(
        sql: """
          UPDATE event_text_documents SET source_references_json = ?, result_json = ?
          WHERE id = ?
          """,
        arguments: [updatedReferences, updatedResult, id])
    }
  }

  /// The organizer queue (DGX Spark) is told the session changed, as the
  /// trigger on a new final or edited revision tells it
  /// (`remote_organizer_item_transcript_inserted`): an item already
  /// delivered with one window is delivered again with its sentences.
  private nonisolated static func markOrganizerItemChanged(
    session: String, in db: Database
  ) throws {
    try db.execute(
      sql: """
        UPDATE remote_organizer_item_jobs SET
          change_seq = change_seq + 1,
          state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
          retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
          not_before = 0,
          updated_at = (julianday('now') - 2440587.5) * 86400.0
        WHERE item_id = ?
          AND EXISTS (
            SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
          )
        """,
      arguments: [session])
  }
}

/// One `transcript_segments` row, as rewritten in order.
private struct StoredSegmentRow {
  let id: String
  let start: Int64
  let end: Int64
  let text: String
  let confidence: Double?

  init(row: Row) {
    id = row["segment_id"]
    start = row["monotonic_start_ns"]
    end = row["monotonic_end_ns"]
    text = row["text"]
    confidence = row["confidence"]
  }

  init(segment: DictationTranscriptSegment) {
    id = segment.id.uuidString
    start = Int64(segment.monotonicStartNanoseconds)
    end = Int64(segment.monotonicEndNanoseconds)
    text = segment.text
    confidence = segment.confidence
  }
}
