import BestASRDomain
import BestASRInference
import Foundation
import GRDB

public struct EventSummary: Equatable, Identifiable, Sendable {
  public let event: MemoryEvent
  public let sessionIDs: [SessionID]
  public let personIDs: [PersonID]
  public let personDisplayNames: [String]
  public let inputModes: [String]
  public let pendingCandidateCount: Int

  public var id: EventID { event.id }

  public init(
    event: MemoryEvent,
    sessionIDs: [SessionID],
    personIDs: [PersonID],
    personDisplayNames: [String],
    inputModes: [String],
    pendingCandidateCount: Int
  ) {
    self.event = event
    self.sessionIDs = sessionIDs
    self.personIDs = personIDs
    self.personDisplayNames = personDisplayNames
    self.inputModes = inputModes
    self.pendingCandidateCount = pendingCandidateCount
  }
}

public struct EventDetail: Equatable, Sendable {
  public let summary: EventSummary
  public let sessionLinks: [EventSessionLink]
  public let personLinks: [EventPersonLink]
  public let candidates: [EventCandidate]

  public init(
    summary: EventSummary,
    sessionLinks: [EventSessionLink],
    personLinks: [EventPersonLink],
    candidates: [EventCandidate]
  ) {
    self.summary = summary
    self.sessionLinks = sessionLinks
    self.personLinks = personLinks
    self.candidates = candidates
  }
}

public struct EventTextSourceReference: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let transcriptRevisionID: TranscriptRevisionID
  public let sourceRevision: Revision
  public let segmentIDs: [UUID]

  public init(
    sessionID: SessionID,
    transcriptRevisionID: TranscriptRevisionID,
    sourceRevision: Revision,
    segmentIDs: [UUID]
  ) {
    self.sessionID = sessionID
    self.transcriptRevisionID = transcriptRevisionID
    self.sourceRevision = sourceRevision
    self.segmentIDs = segmentIDs
  }
}

public struct EventTextDocumentRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let eventID: EventID
  public let eventRevision: Revision
  public let taskID: LocalTextTaskID
  public let modelArtifactID: String
  public let configHash: SHA256Digest
  public let sourceReferences: [EventTextSourceReference]
  public let result: LocalTextResult
  public let state: DictationDerivedTextState
  public let createdAt: Date

  public init(
    id: UUID,
    eventID: EventID,
    eventRevision: Revision,
    taskID: LocalTextTaskID,
    modelArtifactID: String,
    configHash: SHA256Digest,
    sourceReferences: [EventTextSourceReference],
    result: LocalTextResult,
    state: DictationDerivedTextState = .current,
    createdAt: Date
  ) {
    self.id = id
    self.eventID = eventID
    self.eventRevision = eventRevision
    self.taskID = taskID
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
    self.sourceReferences = sourceReferences
    self.result = result
    self.state = state
    self.createdAt = createdAt
  }
}

private struct EventUndoSnapshot: Codable, Sendable {
  let events: [MemoryEvent]
  let sessionLinks: [EventSessionLink]
  let rejections: [EventLinkRejection]
  let personLinks: [EventPersonLink]
  let candidates: [EventCandidate]
  let documents: [EventTextDocumentRecord]
}

private enum EventEditInverse: Codable, Sendable {
  case restore(snapshot: EventUndoSnapshot, deleteEventIDs: [EventID])
}

extension GRDBDictationStore {
  /// Detaches a session only as part of an already-authorized session
  /// deletion transaction. Event metadata remains available and is recomputed
  /// from its surviving source sessions; pending proposals that cite the
  /// deleted source are removed with it.
  static func detachSessionFromEventMemory(
    value: String,
    at: Date,
    in db: Database
  ) throws {
    let rawEventIDs = try String.fetchAll(
      db,
      sql: "SELECT event_id FROM event_sessions WHERE session_id = ?",
      arguments: [value]
    )
    let eventIDs = Set(
      try rawEventIDs.map { rawValue -> EventID in
        guard let uuid = UUID(uuidString: rawValue) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        return EventID(uuid)
      })
    for eventID in eventIDs {
      // Once a source record is explicitly deleted, a cross-record result
      // that cited it can no longer satisfy provenance. It is reproducible,
      // so remove it instead of retaining an unverifiable summary.
      try db.execute(
        sql: "DELETE FROM event_text_documents WHERE event_id = ?",
        arguments: [eventID.rawValue.uuidString]
      )
    }
    try db.execute(
      sql: "DELETE FROM event_candidates WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM event_sessions WHERE session_id = ?",
      arguments: [value]
    )
    try refreshEventAggregates(eventIDs: eventIDs, at: at, in: db)
  }

  public func eventSummaries(query: String = "") async throws -> [EventSummary] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let database = try requirePool()
    return try await database.read { db in
      var arguments = StatementArguments()
      let predicate: String
      if normalized.isEmpty {
        predicate = "e.retired_at IS NULL"
      } else {
        let pattern = "%\(normalized)%"
        predicate = """
          e.retired_at IS NULL AND (
            e.title LIKE ? OR e.notes LIKE ? OR
            EXISTS (
              SELECT 1 FROM event_people ep
              JOIN persons p ON p.id = ep.person_id
              WHERE ep.event_id = e.id AND p.retired_at IS NULL AND
                (COALESCE(p.display_name, '') LIKE ? OR
                 CAST(p.aliases_json AS TEXT) LIKE ?)
            ) OR EXISTS (
              SELECT 1 FROM event_sessions es
              JOIN session_metadata sm ON sm.session_id = es.session_id
              WHERE es.event_id = e.id AND
                (sm.title LIKE ? OR COALESCE(sm.source_display_name, '') LIKE ?)
            ) OR EXISTS (
              SELECT 1 FROM event_text_documents etd
              WHERE etd.event_id = e.id AND etd.state = 'current'
                AND CAST(etd.result_json AS TEXT) LIKE ?
            )
          )
          """
        arguments += StatementArguments(Array(repeating: pattern, count: 7))
      }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT e.* FROM events e
          WHERE \(predicate)
          ORDER BY e.start_at DESC, e.updated_at DESC, e.id
          """,
        arguments: arguments
      )
      return try rows.map { row in
        let event = try Self.memoryEvent(row)
        return try Self.eventSummary(event: event, in: db)
      }
    }
  }

  public func eventDetail(id: EventID) async throws -> EventDetail? {
    let database = try requirePool()
    return try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM events WHERE id = ? AND retired_at IS NULL",
          arguments: [id.rawValue.uuidString]
        )
      else { return nil }
      let event = try Self.memoryEvent(row)
      let summary = try Self.eventSummary(event: event, in: db)
      let links = try Self.sessionLinks(eventIDs: Set([id]), in: db)
      let people = try Self.personLinks(eventIDs: Set([id]), in: db)
      let candidates = try Self.eventCandidates(eventID: id, in: db)
      return EventDetail(
        summary: summary,
        sessionLinks: links,
        personLinks: people,
        candidates: candidates
      )
    }
  }

  public func saveEventTextDocument(
    _ document: EventTextDocumentRecord
  ) async throws {
    let allSourceSegmentIDs = Set(document.sourceReferences.flatMap(\.segmentIDs))
    guard document.result.taskID == document.taskID,
      document.result.modelArtifactID == document.modelArtifactID,
      document.state == .current,
      !document.modelArtifactID.isEmpty,
      !document.result.outputText.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty,
      !document.sourceReferences.isEmpty,
      !allSourceSegmentIDs.isEmpty,
      document.result.claims.allSatisfy({
        Set($0.sourceSegmentIDs).isSubset(of: allSourceSegmentIDs)
      }),
      document.result.structuredItems.allSatisfy({
        Set($0.sourceSegmentIDs).isSubset(of: allSourceSegmentIDs)
      })
    else { throw BestASRPersistenceError.invalidSnapshot }
    let referencesData = try Self.encode(document.sourceReferences)
    let resultData = try Self.encode(document.result)
    guard let storedEventRevision = Int64(exactly: document.eventRevision.value)
    else { throw BestASRPersistenceError.numericOverflow }
    let database = try requirePool()
    try await database.write { db in
      guard let event = try Self.loadEvent(id: document.eventID, in: db),
        event.retiredAt == nil,
        event.revision == document.eventRevision
      else { throw BestASRPersistenceError.invalidSnapshot }
      for reference in document.sourceReferences {
        guard !reference.segmentIDs.isEmpty else {
          throw BestASRPersistenceError.invalidSnapshot
        }
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT source.session_id, source.revision,
              (SELECT current.id FROM transcript_revisions current
               WHERE current.session_id = source.session_id
               ORDER BY CASE WHEN current.kind IN ('final', 'userEdit') THEN 1 ELSE 0 END DESC,
                        current.created_at DESC, current.revision DESC, current.id DESC
               LIMIT 1) AS current_transcript_id
            FROM transcript_revisions source WHERE source.id = ?
            """,
          arguments: [reference.transcriptRevisionID.rawValue.uuidString]
        )
        guard let row,
          let storedSourceRevision = Int64(exactly: reference.sourceRevision.value)
        else { throw BestASRPersistenceError.invalidSnapshot }
        let storedSessionID: String = row["session_id"]
        let storedTranscriptRevision: Int64 = row["revision"]
        guard storedSessionID == reference.sessionID.rawValue.uuidString,
          storedTranscriptRevision == storedSourceRevision
        else { throw BestASRPersistenceError.invalidSnapshot }
        guard
          row["current_transcript_id"] as String?
            == reference.transcriptRevisionID.rawValue.uuidString
        else { throw BestASRPersistenceError.processingCommitConflict }
        let linkedToEvent =
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS(
                SELECT 1 FROM event_sessions
                WHERE event_id = ? AND session_id = ?
              )
              """,
            arguments: [
              document.eventID.rawValue.uuidString,
              reference.sessionID.rawValue.uuidString,
            ]
          ) == true
        guard linkedToEvent else {
          throw BestASRPersistenceError.invalidSnapshot
        }
        let storedSegmentIDs = Set(
          try String.fetchAll(
            db,
            sql: "SELECT segment_id FROM transcript_segments WHERE transcript_id = ?",
            arguments: [reference.transcriptRevisionID.rawValue.uuidString]
          )
        )
        let referencedSegmentIDs = Set(
          reference.segmentIDs.map(\.uuidString)
        )
        let syntheticWholeTranscriptReference =
          storedSegmentIDs.isEmpty
          && referencedSegmentIDs
            == Set([reference.transcriptRevisionID.rawValue.uuidString])
        guard
          syntheticWholeTranscriptReference
            || referencedSegmentIDs.isSubset(of: storedSegmentIDs)
        else { throw BestASRPersistenceError.invalidSnapshot }
      }
      if let existingRow = try Row.fetchOne(
        db,
        sql: "SELECT * FROM event_text_documents WHERE id = ?",
        arguments: [document.id.uuidString]
      ) {
        let existing = try Self.eventTextDocument(existingRow)
        guard existing.eventID == document.eventID,
          existing.eventRevision == document.eventRevision,
          existing.taskID == document.taskID,
          existing.modelArtifactID == document.modelArtifactID,
          existing.configHash == document.configHash,
          existing.sourceReferences == document.sourceReferences,
          existing.result == document.result,
          existing.state == .current
        else { throw BestASRPersistenceError.processingCommitConflict }
        // A retry may acknowledge the same result, but cannot rewrite an old
        // result or revive a stale document under its previous identity.
        return
      }
      try db.execute(
        sql: """
          UPDATE event_text_documents SET state = 'stale'
          WHERE event_id = ? AND task_id = ? AND state = 'current' AND id <> ?
          """,
        arguments: [
          document.eventID.rawValue.uuidString,
          document.taskID.rawValue,
          document.id.uuidString,
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO event_text_documents(
            id, event_id, event_revision, task_id, model_artifact_id,
            config_hash, source_references_json, result_json, state, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          document.id.uuidString,
          document.eventID.rawValue.uuidString,
          storedEventRevision,
          document.taskID.rawValue,
          document.modelArtifactID,
          document.configHash.value,
          referencesData,
          resultData,
          document.state.rawValue,
          document.createdAt.timeIntervalSince1970,
        ]
      )
    }
  }

  public func eventTextDocuments(
    eventID: EventID
  ) async throws -> [EventTextDocumentRecord] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM event_text_documents
          WHERE event_id = ? ORDER BY created_at DESC, id DESC
          """,
        arguments: [eventID.rawValue.uuidString]
      ).map(Self.eventTextDocument)
    }
  }

  public func createEvent(
    title: String,
    notes: String,
    sessionIDs: [SessionID]
  ) async throws -> MemoryEvent {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let uniqueSessionIDs = Array(Set(sessionIDs)).sorted {
      $0.rawValue.uuidString < $1.rawValue.uuidString
    }
    let now = Date()
    let database = try requirePool()
    return try await database.write { db in
      try Self.requireSessions(uniqueSessionIDs, in: db)
      let snapshot = try Self.captureEventSnapshot(eventIDs: [], in: db)
      let bounds = try Self.sessionBounds(uniqueSessionIDs, fallback: now, in: db)
      let event = MemoryEvent(
        revision: try Revision(1),
        title: normalizedTitle,
        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
        startAt: bounds.start,
        endAt: bounds.end,
        titleIsUserEdited: true,
        createdAt: now,
        updatedAt: now
      )
      try Self.upsert(event: event, in: db)
      try Self.assignSessions(
        uniqueSessionIDs,
        to: event.id,
        source: .manual,
        evidence: .manual(at: now),
        at: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: Set([event.id]),
        at: now,
        in: db
      )
      try Self.saveEventUndo(
        kind: "create",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: [event.id]),
        at: now,
        in: db
      )
      guard let stored = try Self.loadEvent(id: event.id, in: db) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return stored
    }
  }

  public func updateEvent(
    id: EventID,
    title: String,
    notes: String
  ) async throws -> MemoryEvent {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let now = Date()
    let database = try requirePool()
    return try await database.write { db in
      guard let current = try Self.loadEvent(id: id, in: db),
        current.retiredAt == nil,
        current.revision.value < UInt64.max
      else { throw BestASRPersistenceError.missingSession }
      let snapshot = try Self.captureEventSnapshot(eventIDs: Set([id]), in: db)
      let updated = MemoryEvent(
        id: current.id,
        revision: try Revision(current.revision.value + 1),
        title: normalizedTitle,
        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
        startAt: current.startAt,
        endAt: current.endAt,
        titleIsUserEdited: true,
        confirmationState: current.confirmationState,
        createdAt: current.createdAt,
        updatedAt: now,
        retiredAt: current.retiredAt,
        mergedIntoEventID: current.mergedIntoEventID
      )
      try Self.upsert(event: updated, in: db)
      try db.execute(
        sql: """
          UPDATE event_text_documents SET state = 'stale'
          WHERE event_id = ? AND state = 'current'
          """,
        arguments: [id.rawValue.uuidString]
      )
      try Self.saveEventUndo(
        kind: "update",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: []),
        at: now,
        in: db
      )
      return updated
    }
  }

  public func linkSessions(
    _ sessionIDs: [SessionID],
    to eventID: EventID,
    source: EventMembershipSource,
    evidence: EventLinkEvidence
  ) async throws {
    let unique = Array(Set(sessionIDs))
    guard !unique.isEmpty, Self.valid(evidence: evidence) else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let now = Date()
    let database = try requirePool()
    try await database.write { db in
      try Self.requireActiveEvent(eventID, in: db)
      try Self.requireSessions(unique, in: db)
      let snapshot =
        source == .automatic
        ? nil
        : try Self.captureEventSnapshot(eventIDs: Set([eventID]), in: db)
      try Self.assignSessions(
        unique,
        to: eventID,
        source: source,
        evidence: evidence,
        at: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: Set([eventID]),
        at: now,
        in: db
      )
      if let snapshot {
        try Self.saveEventUndo(
          kind: "link-sessions",
          inverse: .restore(snapshot: snapshot, deleteEventIDs: []),
          at: now,
          in: db
        )
      }
    }
  }

  public func moveSessions(
    _ sessionIDs: [SessionID],
    from sourceEventID: EventID,
    to targetEventID: EventID,
    evidence: EventLinkEvidence
  ) async throws {
    let unique = Array(Set(sessionIDs))
    guard sourceEventID != targetEventID, !unique.isEmpty,
      Self.valid(evidence: evidence)
    else { throw BestASRPersistenceError.invalidSnapshot }
    let now = Date()
    let database = try requirePool()
    try await database.write { db in
      try Self.requireActiveEvent(sourceEventID, in: db)
      try Self.requireActiveEvent(targetEventID, in: db)
      try Self.requireSessions(unique, in: db)
      let linked =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM event_sessions
            WHERE event_id = ? AND session_id IN (SELECT value FROM json_each(?))
            """,
          arguments: [
            sourceEventID.rawValue.uuidString,
            try Self.jsonString(unique.map { $0.rawValue.uuidString }),
          ]
        ) ?? 0
      guard linked == unique.count else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      let affected = Set([sourceEventID, targetEventID])
      let snapshot = try Self.captureEventSnapshot(eventIDs: affected, in: db)
      try db.execute(
        sql: """
          DELETE FROM event_sessions
          WHERE event_id = ? AND session_id IN (SELECT value FROM json_each(?))
          """,
        arguments: [
          sourceEventID.rawValue.uuidString,
          try Self.jsonString(unique.map { $0.rawValue.uuidString }),
        ]
      )
      try Self.rejectSessions(
        unique,
        from: sourceEventID,
        reason: .manualMove,
        at: now,
        in: db
      )
      try Self.assignSessions(
        unique,
        to: targetEventID,
        source: .manual,
        evidence: evidence,
        at: now,
        in: db
      )
      try Self.refreshEventAggregates(eventIDs: affected, at: now, in: db)
      try Self.saveEventUndo(
        kind: "move-sessions",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: []),
        at: now,
        in: db
      )
    }
  }

  public func removeSessions(
    _ sessionIDs: [SessionID],
    from eventID: EventID
  ) async throws {
    let unique = Array(Set(sessionIDs))
    guard !unique.isEmpty else { return }
    let now = Date()
    let database = try requirePool()
    try await database.write { db in
      try Self.requireActiveEvent(eventID, in: db)
      try Self.requireSessions(unique, in: db)
      let linkedCount =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM event_sessions
            WHERE event_id = ? AND session_id IN (SELECT value FROM json_each(?))
            """,
          arguments: [
            eventID.rawValue.uuidString,
            try Self.jsonString(unique.map { $0.rawValue.uuidString }),
          ]
        ) ?? 0
      guard linkedCount == unique.count else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      let snapshot = try Self.captureEventSnapshot(eventIDs: Set([eventID]), in: db)
      let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
      try db.execute(
        sql: "DELETE FROM event_sessions WHERE event_id = ? AND session_id IN (\(placeholders))",
        arguments: StatementArguments(
          [eventID.rawValue.uuidString] + unique.map { $0.rawValue.uuidString }
        )
      )
      try Self.rejectSessions(
        unique,
        from: eventID,
        reason: .manualRemoval,
        at: now,
        in: db
      )
      try Self.refreshEventAggregates(eventIDs: Set([eventID]), at: now, in: db)
      try Self.saveEventUndo(
        kind: "remove-sessions",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: []),
        at: now,
        in: db
      )
    }
  }

  public func mergeEvents(primaryID: EventID, mergedID: EventID) async throws {
    guard primaryID != mergedID else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let now = Date()
    let database = try requirePool()
    try await database.write { db in
      try Self.requireActiveEvent(primaryID, in: db)
      try Self.requireActiveEvent(mergedID, in: db)
      let snapshot = try Self.captureEventSnapshot(
        eventIDs: Set([primaryID, mergedID]),
        in: db
      )
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO event_sessions(
            event_id, session_id, source, confidence, evidence_json,
            created_at, updated_at
          )
          SELECT ?, session_id, source, confidence, evidence_json,
            created_at, ? FROM event_sessions WHERE event_id = ?
          """,
        arguments: [
          primaryID.rawValue.uuidString,
          now.timeIntervalSince1970,
          mergedID.rawValue.uuidString,
        ]
      )
      try db.execute(
        sql: "DELETE FROM event_sessions WHERE event_id = ?",
        arguments: [mergedID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO event_link_rejections(
            event_id, session_id, reason, created_at
          )
          SELECT ?, rejected.session_id, rejected.reason, rejected.created_at
          FROM event_link_rejections rejected
          WHERE rejected.event_id = ? AND NOT EXISTS (
            SELECT 1 FROM event_sessions linked
            WHERE linked.event_id = ? AND linked.session_id = rejected.session_id
          )
          """,
        arguments: [
          primaryID.rawValue.uuidString,
          mergedID.rawValue.uuidString,
          primaryID.rawValue.uuidString,
        ]
      )
      try db.execute(
        sql: "DELETE FROM event_link_rejections WHERE event_id = ?",
        arguments: [mergedID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          UPDATE event_candidates SET candidate_event_id = ?, updated_at = ?
          WHERE candidate_event_id = ? AND state = 'pending'
          """,
        arguments: [
          primaryID.rawValue.uuidString,
          now.timeIntervalSince1970,
          mergedID.rawValue.uuidString,
        ]
      )
      try db.execute(
        sql: """
          UPDATE events
          SET revision = revision + 1, retired_at = ?,
              merged_into_event_id = ?, updated_at = ?
          WHERE id = ?
          """,
        arguments: [
          now.timeIntervalSince1970,
          primaryID.rawValue.uuidString,
          now.timeIntervalSince1970,
          mergedID.rawValue.uuidString,
        ]
      )
      try Self.refreshEventAggregates(
        eventIDs: Set([primaryID, mergedID]),
        at: now,
        in: db
      )
      try Self.saveEventUndo(
        kind: "merge",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: []),
        at: now,
        in: db
      )
    }
  }

  public func splitEvent(
    sourceID: EventID,
    sessionIDs: [SessionID],
    newTitle: String
  ) async throws -> MemoryEvent {
    let normalized = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let unique = Array(Set(sessionIDs))
    guard !normalized.isEmpty, !unique.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let now = Date()
    let database = try requirePool()
    return try await database.write { db in
      try Self.requireActiveEvent(sourceID, in: db)
      let linkedCount =
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM event_sessions
            WHERE event_id = ? AND session_id IN (
              SELECT value FROM json_each(?)
            )
            """,
          arguments: [
            sourceID.rawValue.uuidString,
            try Self.jsonString(unique.map { $0.rawValue.uuidString }),
          ]
        ) ?? 0
      guard linkedCount == unique.count else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      let snapshot = try Self.captureEventSnapshot(eventIDs: Set([sourceID]), in: db)
      let bounds = try Self.sessionBounds(unique, fallback: now, in: db)
      let created = MemoryEvent(
        revision: try Revision(1),
        title: normalized,
        startAt: bounds.start,
        endAt: bounds.end,
        titleIsUserEdited: true,
        createdAt: now,
        updatedAt: now
      )
      try Self.upsert(event: created, in: db)
      try db.execute(
        sql: """
          DELETE FROM event_sessions
          WHERE event_id = ? AND session_id IN (SELECT value FROM json_each(?))
          """,
        arguments: [
          sourceID.rawValue.uuidString,
          try Self.jsonString(unique.map { $0.rawValue.uuidString }),
        ]
      )
      try Self.rejectSessions(
        unique,
        from: sourceID,
        reason: .manualSplit,
        at: now,
        in: db
      )
      try Self.assignSessions(
        unique,
        to: created.id,
        source: .manual,
        evidence: .manual(at: now),
        at: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: Set([sourceID, created.id]),
        at: now,
        in: db
      )
      try Self.saveEventUndo(
        kind: "split",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: [created.id]),
        at: now,
        in: db
      )
      return created
    }
  }

  public func retireEvent(id: EventID) async throws {
    let now = Date()
    let database = try requirePool()
    try await database.write { db in
      try Self.requireActiveEvent(id, in: db)
      let snapshot = try Self.captureEventSnapshot(eventIDs: Set([id]), in: db)
      try db.execute(
        sql: "DELETE FROM event_sessions WHERE event_id = ?",
        arguments: [id.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          UPDATE events SET revision = revision + 1, retired_at = ?,
            updated_at = ? WHERE id = ?
          """,
        arguments: [
          now.timeIntervalSince1970,
          now.timeIntervalSince1970,
          id.rawValue.uuidString,
        ]
      )
      try db.execute(
        sql: "DELETE FROM event_people WHERE event_id = ?",
        arguments: [id.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          UPDATE event_candidates SET state = 'superseded', updated_at = ?
          WHERE candidate_event_id = ? AND state = 'pending'
          """,
        arguments: [now.timeIntervalSince1970, id.rawValue.uuidString]
      )
      try Self.saveEventUndo(
        kind: "retire",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: []),
        at: now,
        in: db
      )
    }
  }

  public func undoLastEventEdit() async throws -> Bool {
    let database = try requirePool()
    return try await database.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT id, inverse_json FROM event_edit_operations
            WHERE reversed_at IS NULL
            ORDER BY occurred_at DESC, id DESC LIMIT 1
            """
        )
      else { return false }
      let operationID: String = row["id"]
      let data: Data = row["inverse_json"]
      let inverse = try Self.decode(EventEditInverse.self, from: data)
      switch inverse {
      case .restore(let snapshot, let deleteEventIDs):
        try Self.restoreEventSnapshot(
          snapshot,
          deleting: deleteEventIDs,
          in: db
        )
      }
      try db.execute(
        sql: "UPDATE event_edit_operations SET reversed_at = ? WHERE id = ?",
        arguments: [Date().timeIntervalSince1970, operationID]
      )
      return true
    }
  }

  public func eventCandidates() async throws -> [EventCandidate] {
    let database = try requirePool()
    return try await database.read { db in
      try Self.eventCandidates(eventID: nil, in: db)
    }
  }

  public func replacePendingEventCandidates(
    _ candidates: [EventCandidate]
  ) async throws {
    guard
      candidates.allSatisfy({
        $0.state == .pending
          && !$0.proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && Self.valid(evidence: $0.evidence)
      })
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    try await database.write { db in
      try db.execute(sql: "DELETE FROM event_candidates WHERE state = 'pending'")
      for candidate in candidates {
        let sessionExists =
          try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
            arguments: [candidate.sessionID.rawValue.uuidString]
          ) == true
        guard sessionExists else { throw BestASRPersistenceError.missingSession }
        if let eventID = candidate.candidateEventID {
          try Self.requireActiveEvent(eventID, in: db)
        }
        // A dismissal is a durable user decision. The organizer deliberately
        // reuses a deterministic candidate id, so ignore an already accepted,
        // dismissed, or superseded proposal instead of resurrecting it on the
        // next history refresh.
        try Self.insert(candidate: candidate, ignoringExisting: true, in: db)
      }
    }
  }

  public func acceptEventCandidate(id: EventCandidateID) async throws -> EventID {
    let now = Date()
    let database = try requirePool()
    return try await database.write { db in
      guard let candidate = try Self.loadCandidate(id: id, in: db),
        candidate.state == .pending
      else { throw BestASRPersistenceError.invalidSnapshot }
      var capturedIDs = Set<EventID>()
      let eventID: EventID
      var deleteIDs: [EventID] = []
      if let candidateEventID = candidate.candidateEventID {
        try Self.requireActiveEvent(candidateEventID, in: db)
        eventID = candidateEventID
        capturedIDs.insert(candidateEventID)
      } else {
        let bounds = try Self.sessionBounds(
          [candidate.sessionID],
          fallback: now,
          in: db
        )
        let event = MemoryEvent(
          revision: try Revision(1),
          title: candidate.proposedTitle,
          startAt: bounds.start,
          endAt: bounds.end,
          titleIsUserEdited: false,
          createdAt: now,
          updatedAt: now
        )
        try Self.upsert(event: event, in: db)
        eventID = event.id
        deleteIDs = [event.id]
      }
      let snapshot = try Self.captureEventSnapshot(
        eventIDs: capturedIDs,
        candidateIDs: Set([id]),
        in: db
      )
      try Self.assignSessions(
        [candidate.sessionID],
        to: eventID,
        source: .candidateAccepted,
        evidence: candidate.evidence,
        at: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: capturedIDs.union([eventID]),
        at: now,
        in: db
      )
      try db.execute(
        sql: "UPDATE event_candidates SET state = 'accepted', updated_at = ? WHERE id = ?",
        arguments: [now.timeIntervalSince1970, id.rawValue.uuidString]
      )
      try Self.saveEventUndo(
        kind: "accept-candidate",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: deleteIDs),
        at: now,
        in: db
      )
      return eventID
    }
  }

  public func dismissEventCandidate(id: EventCandidateID) async throws {
    let now = Date()
    let database = try requirePool()
    try await database.write { db in
      guard let candidate = try Self.loadCandidate(id: id, in: db),
        candidate.state == .pending
      else { throw BestASRPersistenceError.invalidSnapshot }
      let snapshot = try Self.captureEventSnapshot(
        eventIDs: [],
        candidateIDs: Set([id]),
        in: db
      )
      try db.execute(
        sql: """
          UPDATE event_candidates SET state = 'dismissed', updated_at = ?
          WHERE id = ? AND state = 'pending'
          """,
        arguments: [now.timeIntervalSince1970, id.rawValue.uuidString]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      try Self.saveEventUndo(
        kind: "dismiss-candidate",
        inverse: .restore(snapshot: snapshot, deleteEventIDs: []),
        at: now,
        in: db
      )
    }
  }

  public func eventOrganizationSessions() async throws
    -> [EventOrganizationSession]
  {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT s.id, s.input_mode, s.created_at, s.updated_at,
            sm.title, sm.source_identifier, sm.source_bundle_id,
            trim(
              CASE WHEN sm.title_is_user_edited = 1 THEN sm.title ELSE '' END || ' ' ||
              COALESCE(
                (SELECT GROUP_CONCAT(dt.output_text, ' ')
                 FROM derived_text_revisions dt
                 WHERE dt.session_id = s.id AND dt.state = 'current'
                   AND dt.source_transcript_id = current_tr.id),
                ''
              ) || ' ' ||
              COALESCE(current_tr.content, '')
            ) AS semantic_text,
            (SELECT GROUP_CONCAT(DISTINCT o.person_id)
             FROM speaker_occurrences o
             JOIN persons p ON p.id = o.person_id
             WHERE o.session_id = s.id
               AND o.person_id IS NOT NULL
               AND p.retired_at IS NULL
               AND o.association_status IN (
                 'anonymousIdentity', 'automaticMatch', 'userConfirmed'
               )) AS person_ids,
            (SELECT GROUP_CONCAT(es.event_id) FROM event_sessions es
             JOIN events e ON e.id = es.event_id
             WHERE es.session_id = s.id AND e.retired_at IS NULL) AS event_ids,
            (SELECT GROUP_CONCAT(rejected.event_id)
              FROM event_link_rejections rejected
              JOIN events e ON e.id = rejected.event_id
              WHERE rejected.session_id = s.id AND e.retired_at IS NULL)
              AS rejected_event_ids
          FROM sessions s
          JOIN session_metadata sm ON sm.session_id = s.id
          JOIN dictation_snapshots ds ON ds.session_id = s.id
          LEFT JOIN transcript_revisions current_tr ON current_tr.id = (
            SELECT tr.id FROM transcript_revisions tr
            WHERE tr.session_id = s.id
            ORDER BY CASE WHEN tr.kind IN ('final', 'userEdit') THEN 1 ELSE 0 END DESC,
                     tr.created_at DESC, tr.revision DESC, tr.id DESC
            LIMIT 1
          )
          WHERE ds.phase <> 'cancelled'
          ORDER BY s.created_at, s.id
          """
      )
      return try rows.map { row in
        guard let sessionUUID = UUID(uuidString: row["id"] as String) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let personText: String? = row["person_ids"]
        let eventText: String? = row["event_ids"]
        let rejectedEventText: String? = row["rejected_event_ids"]
        let text: String = row["semantic_text"]
        return EventOrganizationSession(
          sessionID: SessionID(sessionUUID),
          title: row["title"],
          semanticText: text,
          createdAt: Date(timeIntervalSince1970: row["created_at"]),
          updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
          inputMode: row["input_mode"],
          sourceIdentifier: row["source_identifier"],
          sourceBundleIdentifier: row["source_bundle_id"],
          personIDs: Set(
            personText?.split(separator: ",").compactMap {
              UUID(uuidString: String($0)).map(PersonID.init)
            } ?? []
          ),
          currentEventIDs: Set(
            eventText?.split(separator: ",").compactMap {
              UUID(uuidString: String($0)).map(EventID.init)
            } ?? []
          ),
          rejectedEventIDs: Set(
            rejectedEventText?.split(separator: ",").compactMap {
              UUID(uuidString: String($0)).map(EventID.init)
            } ?? []
          )
        )
      }
    }
  }

  private nonisolated static func eventSummary(
    event: MemoryEvent,
    in db: Database
  ) throws -> EventSummary {
    let sessionRows = try Row.fetchAll(
      db,
      sql: """
        SELECT es.session_id, s.input_mode
        FROM event_sessions es JOIN sessions s ON s.id = es.session_id
        WHERE es.event_id = ? ORDER BY s.created_at, s.id
        """,
      arguments: [event.id.rawValue.uuidString]
    )
    let peopleRows = try Row.fetchAll(
      db,
      sql: """
        SELECT ep.person_id, p.display_name, p.created_at
        FROM event_people ep JOIN persons p ON p.id = ep.person_id
        WHERE ep.event_id = ? AND p.retired_at IS NULL
        ORDER BY COALESCE(p.display_name, p.id), p.id
        """,
      arguments: [event.id.rawValue.uuidString]
    )
    let sessionIDs = try sessionRows.map { row -> SessionID in
      guard let value = UUID(uuidString: row["session_id"] as String) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return SessionID(value)
    }
    let personIDs = try peopleRows.map { row -> PersonID in
      guard let value = UUID(uuidString: row["person_id"] as String) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return PersonID(value)
    }
    let names = peopleRows.map { row -> String in
      let displayName: String? = row["display_name"]
      return PersonDisplayTitle.formatted(
        displayName: displayName,
        createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
      )
    }
    let candidateCount =
      try Int.fetchOne(
        db,
        sql:
          "SELECT COUNT(*) FROM event_candidates WHERE candidate_event_id = ? AND state = 'pending'",
        arguments: [event.id.rawValue.uuidString]
      ) ?? 0
    return EventSummary(
      event: event,
      sessionIDs: sessionIDs,
      personIDs: personIDs,
      personDisplayNames: names,
      inputModes: Array(Set(sessionRows.map { $0["input_mode"] as String })).sorted(),
      pendingCandidateCount: candidateCount
    )
  }

  private nonisolated static func memoryEvent(_ row: Row) throws -> MemoryEvent {
    guard let id = UUID(uuidString: row["id"] as String) else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    guard
      let confirmationState = EventConfirmationState(
        rawValue: row["confirmation_state"] as String
      )
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let revision: Int64 = row["revision"]
    guard revision > 0 else { throw BestASRPersistenceError.storedDataCorrupt }
    let merged: String? = row["merged_into_event_id"]
    return MemoryEvent(
      id: EventID(id),
      revision: try Revision(UInt64(revision)),
      title: row["title"],
      notes: row["notes"],
      startAt: Date(timeIntervalSince1970: row["start_at"]),
      endAt: Date(timeIntervalSince1970: row["end_at"]),
      titleIsUserEdited: row["title_is_user_edited"] as Bool,
      confirmationState: confirmationState,
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
      retiredAt: (row["retired_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
      mergedIntoEventID: merged.flatMap(UUID.init(uuidString:)).map(EventID.init)
    )
  }

  private nonisolated static func eventTextDocument(
    _ row: Row
  ) throws -> EventTextDocumentRecord {
    guard let id = UUID(uuidString: row["id"] as String),
      let eventID = UUID(uuidString: row["event_id"] as String),
      let state = DictationDerivedTextState(rawValue: row["state"] as String)
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let revision: Int64 = row["event_revision"]
    let referenceData: Data = row["source_references_json"]
    let resultData: Data = row["result_json"]
    guard revision > 0 else { throw BestASRPersistenceError.storedDataCorrupt }
    return EventTextDocumentRecord(
      id: id,
      eventID: EventID(eventID),
      eventRevision: try Revision(UInt64(revision)),
      taskID: LocalTextTaskID(row["task_id"] as String),
      modelArtifactID: row["model_artifact_id"] as String,
      configHash: try SHA256Digest(row["config_hash"] as String),
      sourceReferences: try decode(
        [EventTextSourceReference].self,
        from: referenceData
      ),
      result: try decode(LocalTextResult.self, from: resultData),
      state: state,
      createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
    )
  }

  private nonisolated static func loadEvent(id: EventID, in db: Database) throws
    -> MemoryEvent?
  {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM events WHERE id = ?",
      arguments: [id.rawValue.uuidString]
    ).map(memoryEvent)
  }

  private nonisolated static func upsert(event: MemoryEvent, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO events (
          id, revision, title, notes, start_at, end_at,
          title_is_user_edited, confirmation_state, created_at, updated_at,
          retired_at, merged_into_event_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          revision = excluded.revision, title = excluded.title,
          notes = excluded.notes, start_at = excluded.start_at,
          end_at = excluded.end_at,
          title_is_user_edited = excluded.title_is_user_edited,
          confirmation_state = excluded.confirmation_state,
          created_at = excluded.created_at, updated_at = excluded.updated_at,
          retired_at = excluded.retired_at,
          merged_into_event_id = excluded.merged_into_event_id
        """,
      arguments: [
        event.id.rawValue.uuidString,
        Int64(event.revision.value),
        event.title,
        event.notes,
        event.startAt.timeIntervalSince1970,
        event.endAt.timeIntervalSince1970,
        event.titleIsUserEdited,
        event.confirmationState.rawValue,
        event.createdAt.timeIntervalSince1970,
        event.updatedAt.timeIntervalSince1970,
        event.retiredAt?.timeIntervalSince1970,
        event.mergedIntoEventID?.rawValue.uuidString,
      ]
    )
  }

  private nonisolated static func sessionLinks(
    eventIDs: Set<EventID>,
    in db: Database
  ) throws -> [EventSessionLink] {
    guard !eventIDs.isEmpty else { return [] }
    let values = eventIDs.map { $0.rawValue.uuidString }.sorted()
    let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
    return try Row.fetchAll(
      db,
      sql:
        "SELECT * FROM event_sessions WHERE event_id IN (\(placeholders)) ORDER BY event_id, session_id",
      arguments: StatementArguments(values)
    ).map { row in
      guard
        let eventUUID = UUID(uuidString: row["event_id"] as String),
        let sessionUUID = UUID(uuidString: row["session_id"] as String),
        let source = EventMembershipSource(rawValue: row["source"] as String)
      else { throw BestASRPersistenceError.storedDataCorrupt }
      let confidence: Double = row["confidence"]
      let evidenceData: Data = row["evidence_json"]
      return EventSessionLink(
        eventID: EventID(eventUUID),
        sessionID: SessionID(sessionUUID),
        source: source,
        confidence: try Confidence(confidence),
        evidence: try decode(EventLinkEvidence.self, from: evidenceData),
        createdAt: Date(timeIntervalSince1970: row["created_at"]),
        updatedAt: Date(timeIntervalSince1970: row["updated_at"])
      )
    }
  }

  private nonisolated static func rejections(
    eventIDs: Set<EventID>,
    in db: Database
  ) throws -> [EventLinkRejection] {
    guard !eventIDs.isEmpty else { return [] }
    let values = eventIDs.map { $0.rawValue.uuidString }.sorted()
    let placeholders = Array(repeating: "?", count: values.count)
      .joined(separator: ",")
    return try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM event_link_rejections
        WHERE event_id IN (\(placeholders)) ORDER BY event_id, session_id
        """,
      arguments: StatementArguments(values)
    ).map { row in
      guard let eventUUID = UUID(uuidString: row["event_id"] as String),
        let sessionUUID = UUID(uuidString: row["session_id"] as String),
        let reason = EventLinkRejectionReason(
          rawValue: row["reason"] as String
        )
      else { throw BestASRPersistenceError.storedDataCorrupt }
      return EventLinkRejection(
        eventID: EventID(eventUUID),
        sessionID: SessionID(sessionUUID),
        reason: reason,
        createdAt: Date(timeIntervalSince1970: row["created_at"] as Double)
      )
    }
  }

  private nonisolated static func personLinks(
    eventIDs: Set<EventID>,
    in db: Database
  ) throws -> [EventPersonLink] {
    guard !eventIDs.isEmpty else { return [] }
    let values = eventIDs.map { $0.rawValue.uuidString }.sorted()
    let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
    return try Row.fetchAll(
      db,
      sql:
        "SELECT * FROM event_people WHERE event_id IN (\(placeholders)) ORDER BY event_id, person_id",
      arguments: StatementArguments(values)
    ).map { row in
      guard
        let eventUUID = UUID(uuidString: row["event_id"] as String),
        let personUUID = UUID(uuidString: row["person_id"] as String)
      else { throw BestASRPersistenceError.storedDataCorrupt }
      let duration: Int64 = row["speech_duration_ns"]
      let count: Int = row["occurrence_count"]
      guard duration >= 0, count > 0 else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return EventPersonLink(
        eventID: EventID(eventUUID),
        personID: PersonID(personUUID),
        occurrenceCount: count,
        speechDurationNanoseconds: UInt64(duration)
      )
    }
  }

  private nonisolated static func captureEventSnapshot(
    eventIDs: Set<EventID>,
    candidateIDs: Set<EventCandidateID> = [],
    in db: Database
  ) throws -> EventUndoSnapshot {
    guard !eventIDs.isEmpty || !candidateIDs.isEmpty else {
      return EventUndoSnapshot(
        events: [],
        sessionLinks: [],
        rejections: [],
        personLinks: [],
        candidates: [],
        documents: []
      )
    }
    let values = eventIDs.map { $0.rawValue.uuidString }.sorted()
    let events: [MemoryEvent]
    if values.isEmpty {
      events = []
    } else {
      let placeholders = Array(repeating: "?", count: values.count)
        .joined(separator: ",")
      events = try Row.fetchAll(
        db,
        sql: "SELECT * FROM events WHERE id IN (\(placeholders)) ORDER BY id",
        arguments: StatementArguments(values)
      ).map(memoryEvent)
    }
    let explicitCandidateValues = candidateIDs.map { $0.rawValue.uuidString }.sorted()
    var candidatePredicates: [String] = []
    var candidateArguments = StatementArguments()
    if !values.isEmpty {
      candidatePredicates.append(
        "candidate_event_id IN (\(Array(repeating: "?", count: values.count).joined(separator: ",")))"
      )
      candidateArguments += StatementArguments(values)
    }
    if !explicitCandidateValues.isEmpty {
      candidatePredicates.append(
        "id IN (\(Array(repeating: "?", count: explicitCandidateValues.count).joined(separator: ",")))"
      )
      candidateArguments += StatementArguments(explicitCandidateValues)
    }
    let candidates = try Row.fetchAll(
      db,
      sql:
        "SELECT * FROM event_candidates WHERE \(candidatePredicates.joined(separator: " OR ")) ORDER BY id",
      arguments: candidateArguments
    ).map(candidate)
    let documents: [EventTextDocumentRecord]
    if values.isEmpty {
      documents = []
    } else {
      let placeholders = Array(repeating: "?", count: values.count)
        .joined(separator: ",")
      documents = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM event_text_documents
          WHERE event_id IN (\(placeholders)) ORDER BY event_id, created_at, id
          """,
        arguments: StatementArguments(values)
      ).map(eventTextDocument)
    }
    return EventUndoSnapshot(
      events: events,
      sessionLinks: try sessionLinks(eventIDs: eventIDs, in: db),
      rejections: try rejections(eventIDs: eventIDs, in: db),
      personLinks: try personLinks(eventIDs: eventIDs, in: db),
      candidates: candidates,
      documents: documents
    )
  }

  private nonisolated static func restoreEventSnapshot(
    _ snapshot: EventUndoSnapshot,
    deleting eventIDs: [EventID],
    in db: Database
  ) throws {
    for id in eventIDs {
      try db.execute(
        sql: "DELETE FROM events WHERE id = ?",
        arguments: [id.rawValue.uuidString]
      )
    }
    for event in snapshot.events {
      let safe = MemoryEvent(
        id: event.id,
        revision: event.revision,
        title: event.title,
        notes: event.notes,
        startAt: event.startAt,
        endAt: event.endAt,
        titleIsUserEdited: event.titleIsUserEdited,
        confirmationState: event.confirmationState,
        createdAt: event.createdAt,
        updatedAt: event.updatedAt,
        retiredAt: event.retiredAt,
        mergedIntoEventID: nil
      )
      try upsert(event: safe, in: db)
    }
    for event in snapshot.events where event.mergedIntoEventID != nil {
      try upsert(event: event, in: db)
    }
    let restoredIDs = snapshot.events.map(\.id)
    for id in restoredIDs {
      try db.execute(
        sql: "DELETE FROM event_sessions WHERE event_id = ?",
        arguments: [id.rawValue.uuidString]
      )
      try db.execute(
        sql: "DELETE FROM event_link_rejections WHERE event_id = ?",
        arguments: [id.rawValue.uuidString]
      )
      try db.execute(
        sql: "DELETE FROM event_people WHERE event_id = ?",
        arguments: [id.rawValue.uuidString]
      )
      try db.execute(
        sql: "DELETE FROM event_text_documents WHERE event_id = ?",
        arguments: [id.rawValue.uuidString]
      )
    }
    for link in snapshot.sessionLinks {
      try insert(link: link, in: db)
    }
    for rejection in snapshot.rejections {
      try insert(rejection: rejection, in: db)
    }
    for link in snapshot.personLinks {
      try db.execute(
        sql: """
          INSERT INTO event_people(
            event_id, person_id, occurrence_count, speech_duration_ns
          ) VALUES (?, ?, ?, ?)
          """,
        arguments: [
          link.eventID.rawValue.uuidString,
          link.personID.rawValue.uuidString,
          link.occurrenceCount,
          Int64(link.speechDurationNanoseconds),
        ]
      )
    }
    for candidate in snapshot.candidates {
      try db.execute(
        sql: "DELETE FROM event_candidates WHERE id = ?",
        arguments: [candidate.id.rawValue.uuidString]
      )
      try insert(candidate: candidate, in: db)
    }
    for document in snapshot.documents {
      try insert(document: document, in: db)
    }
  }

  private nonisolated static func insert(link: EventSessionLink, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO event_sessions(
          event_id, session_id, source, confidence, evidence_json,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        link.eventID.rawValue.uuidString,
        link.sessionID.rawValue.uuidString,
        link.source.rawValue,
        link.confidence.value,
        try encode(link.evidence),
        link.createdAt.timeIntervalSince1970,
        link.updatedAt.timeIntervalSince1970,
      ]
    )
  }

  private nonisolated static func insert(
    rejection: EventLinkRejection,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO event_link_rejections(
          event_id, session_id, reason, created_at
        ) VALUES (?, ?, ?, ?)
        """,
      arguments: [
        rejection.eventID.rawValue.uuidString,
        rejection.sessionID.rawValue.uuidString,
        rejection.reason.rawValue,
        rejection.createdAt.timeIntervalSince1970,
      ]
    )
  }

  private nonisolated static func rejectSessions(
    _ sessionIDs: [SessionID],
    from eventID: EventID,
    reason: EventLinkRejectionReason,
    at date: Date,
    in db: Database
  ) throws {
    for sessionID in sessionIDs {
      try db.execute(
        sql: """
          INSERT INTO event_link_rejections(
            event_id, session_id, reason, created_at
          ) VALUES (?, ?, ?, ?)
          ON CONFLICT(event_id, session_id) DO UPDATE SET
            reason = excluded.reason, created_at = excluded.created_at
          """,
        arguments: [
          eventID.rawValue.uuidString,
          sessionID.rawValue.uuidString,
          reason.rawValue,
          date.timeIntervalSince1970,
        ]
      )
    }
  }

  private nonisolated static func assignSessions(
    _ sessionIDs: [SessionID],
    to eventID: EventID,
    source: EventMembershipSource,
    evidence: EventLinkEvidence,
    at date: Date,
    in db: Database
  ) throws {
    let confidence = try Confidence(evidence.aggregateScore)
    for sessionID in sessionIDs {
      if source == .automatic {
        let rejected =
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS(
                SELECT 1 FROM event_link_rejections
                WHERE event_id = ? AND session_id = ?
              )
              """,
            arguments: [eventID.rawValue.uuidString, sessionID.rawValue.uuidString]
          ) == true
        guard !rejected else {
          throw BestASRPersistenceError.invalidSnapshot
        }
      } else {
        try db.execute(
          sql: "DELETE FROM event_link_rejections WHERE event_id = ? AND session_id = ?",
          arguments: [eventID.rawValue.uuidString, sessionID.rawValue.uuidString]
        )
      }
      let existingCreatedAt = try Double.fetchOne(
        db,
        sql: "SELECT created_at FROM event_sessions WHERE event_id = ? AND session_id = ?",
        arguments: [eventID.rawValue.uuidString, sessionID.rawValue.uuidString]
      )
      let link = EventSessionLink(
        eventID: eventID,
        sessionID: sessionID,
        source: source,
        confidence: confidence,
        evidence: evidence,
        createdAt: existingCreatedAt.map(Date.init(timeIntervalSince1970:)) ?? date,
        updatedAt: date
      )
      try db.execute(
        sql: "DELETE FROM event_sessions WHERE event_id = ? AND session_id = ?",
        arguments: [eventID.rawValue.uuidString, sessionID.rawValue.uuidString]
      )
      try insert(link: link, in: db)
    }
  }

  /// Resolves affected events before a speaker-identity mutation. The
  /// `personValues` path deliberately consults the pre-mutation aggregate so a
  /// merge, split, unlink, or retirement cannot leave stale event relationships.
  nonisolated static func eventIDsAffectedByIdentityChange(
    sessionValues: Set<String> = [],
    personValues: Set<String> = [],
    in db: Database
  ) throws -> Set<EventID> {
    var rawValues = Set<String>()
    if !sessionValues.isEmpty {
      let placeholders = Array(repeating: "?", count: sessionValues.count)
        .joined(separator: ",")
      rawValues.formUnion(
        try String.fetchAll(
          db,
          sql: "SELECT DISTINCT event_id FROM event_sessions WHERE session_id IN (\(placeholders))",
          arguments: StatementArguments(sessionValues.sorted())
        )
      )
    }
    if !personValues.isEmpty {
      let placeholders = Array(repeating: "?", count: personValues.count)
        .joined(separator: ",")
      rawValues.formUnion(
        try String.fetchAll(
          db,
          sql: "SELECT DISTINCT event_id FROM event_people WHERE person_id IN (\(placeholders))",
          arguments: StatementArguments(personValues.sorted())
        )
      )
    }
    return Set(
      try rawValues.map { rawValue -> EventID in
        guard let uuid = UUID(uuidString: rawValue) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        return EventID(uuid)
      })
  }

  nonisolated static func refreshEventAggregates(
    eventIDs: Set<EventID>,
    at date: Date,
    in db: Database
  ) throws {
    for eventID in eventIDs {
      guard try loadEvent(id: eventID, in: db) != nil else { continue }
      try db.execute(
        sql: """
          UPDATE event_text_documents SET state = 'stale'
          WHERE event_id = ? AND state = 'current'
          """,
        arguments: [eventID.rawValue.uuidString]
      )
      try db.execute(
        sql: "DELETE FROM event_people WHERE event_id = ?",
        arguments: [eventID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          INSERT INTO event_people(
            event_id, person_id, occurrence_count, speech_duration_ns
          )
          SELECT ?, o.person_id, COUNT(*),
            SUM(o.monotonic_end_ns - o.monotonic_start_ns)
          FROM event_sessions es
          JOIN speaker_occurrences o ON o.session_id = es.session_id
          JOIN persons p ON p.id = o.person_id
          WHERE es.event_id = ? AND o.person_id IS NOT NULL
            AND p.retired_at IS NULL
            AND o.association_status IN (?, ?, ?)
          GROUP BY o.person_id
          """,
        arguments: [
          eventID.rawValue.uuidString,
          eventID.rawValue.uuidString,
          PersonAssociationStatus.anonymousIdentity.rawValue,
          PersonAssociationStatus.automaticMatch.rawValue,
          PersonAssociationStatus.userConfirmed.rawValue,
        ]
      )
      if let row = try Row.fetchOne(
        db,
        sql: """
          SELECT MIN(s.created_at) AS start_at, MAX(s.updated_at) AS end_at
          FROM event_sessions es JOIN sessions s ON s.id = es.session_id
          WHERE es.event_id = ?
          HAVING COUNT(*) > 0
          """,
        arguments: [eventID.rawValue.uuidString]
      ) {
        let start: Double = row["start_at"]
        let end: Double = row["end_at"]
        try db.execute(
          sql: """
            UPDATE events SET revision = revision + 1, start_at = ?, end_at = ?,
              updated_at = ? WHERE id = ?
            """,
          arguments: [
            start,
            max(start, end),
            date.timeIntervalSince1970,
            eventID.rawValue.uuidString,
          ]
        )
      } else {
        try db.execute(
          sql: "UPDATE events SET revision = revision + 1, updated_at = ? WHERE id = ?",
          arguments: [date.timeIntervalSince1970, eventID.rawValue.uuidString]
        )
      }
    }
  }

  private nonisolated static func requireActiveEvent(
    _ id: EventID,
    in db: Database
  ) throws {
    let exists =
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM events WHERE id = ? AND retired_at IS NULL)",
        arguments: [id.rawValue.uuidString]
      ) == true
    guard exists else { throw BestASRPersistenceError.missingSession }
  }

  private nonisolated static func requireSessions(
    _ ids: [SessionID],
    in db: Database
  ) throws {
    guard !ids.isEmpty else { return }
    let count =
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM sessions WHERE id IN (SELECT value FROM json_each(?))",
        arguments: [try jsonString(ids.map { $0.rawValue.uuidString })]
      ) ?? 0
    guard count == ids.count else { throw BestASRPersistenceError.missingSession }
  }

  private nonisolated static func sessionBounds(
    _ ids: [SessionID],
    fallback: Date,
    in db: Database
  ) throws -> (start: Date, end: Date) {
    guard !ids.isEmpty else { return (fallback, fallback) }
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT MIN(created_at) AS start_at, MAX(updated_at) AS end_at
          FROM sessions WHERE id IN (SELECT value FROM json_each(?))
          """,
        arguments: [try jsonString(ids.map { $0.rawValue.uuidString })]
      )
    else { return (fallback, fallback) }
    let start: Double? = row["start_at"]
    let end: Double? = row["end_at"]
    guard let start, let end else { return (fallback, fallback) }
    return (
      Date(timeIntervalSince1970: start),
      Date(timeIntervalSince1970: max(start, end))
    )
  }

  private nonisolated static func saveEventUndo(
    kind: String,
    inverse: EventEditInverse,
    at date: Date,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO event_edit_operations(
          id, kind, inverse_json, occurred_at, reversed_at
        ) VALUES (?, ?, ?, ?, NULL)
        """,
      arguments: [
        EventEditOperationID().rawValue.uuidString,
        kind,
        try encode(inverse),
        date.timeIntervalSince1970,
      ]
    )
  }

  private nonisolated static func eventCandidates(
    eventID: EventID?,
    in db: Database
  ) throws -> [EventCandidate] {
    var arguments = StatementArguments()
    var predicate = "state = 'pending'"
    if let eventID {
      predicate += " AND candidate_event_id = ?"
      arguments += [eventID.rawValue.uuidString]
    }
    return try Row.fetchAll(
      db,
      sql: "SELECT * FROM event_candidates WHERE \(predicate) ORDER BY updated_at DESC, id",
      arguments: arguments
    ).map(candidate)
  }

  private nonisolated static func candidate(_ row: Row) throws -> EventCandidate {
    guard
      let id = UUID(uuidString: row["id"] as String),
      let sessionID = UUID(uuidString: row["session_id"] as String),
      let state = EventCandidateState(rawValue: row["state"] as String)
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let eventText: String? = row["candidate_event_id"]
    let evidenceData: Data = row["evidence_json"]
    return EventCandidate(
      id: EventCandidateID(id),
      sessionID: SessionID(sessionID),
      candidateEventID: eventText.flatMap(UUID.init(uuidString:)).map(EventID.init),
      proposedTitle: row["proposed_title"],
      evidence: try decode(EventLinkEvidence.self, from: evidenceData),
      state: state,
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"])
    )
  }

  private nonisolated static func loadCandidate(
    id: EventCandidateID,
    in db: Database
  ) throws -> EventCandidate? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM event_candidates WHERE id = ?",
      arguments: [id.rawValue.uuidString]
    ).map(candidate)
  }

  private nonisolated static func insert(
    candidate: EventCandidate,
    ignoringExisting: Bool = false,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT \(ignoringExisting ? "OR IGNORE " : "")INTO event_candidates(
          id, session_id, candidate_event_id, proposed_title, evidence_json,
          state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        candidate.id.rawValue.uuidString,
        candidate.sessionID.rawValue.uuidString,
        candidate.candidateEventID?.rawValue.uuidString,
        candidate.proposedTitle,
        try encode(candidate.evidence),
        candidate.state.rawValue,
        candidate.createdAt.timeIntervalSince1970,
        candidate.updatedAt.timeIntervalSince1970,
      ]
    )
  }

  private nonisolated static func insert(
    document: EventTextDocumentRecord,
    in db: Database
  ) throws {
    guard let revision = Int64(exactly: document.eventRevision.value) else {
      throw BestASRPersistenceError.numericOverflow
    }
    try db.execute(
      sql: """
        INSERT INTO event_text_documents(
          id, event_id, event_revision, task_id, model_artifact_id,
          config_hash, source_references_json, result_json, state, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        document.id.uuidString,
        document.eventID.rawValue.uuidString,
        revision,
        document.taskID.rawValue,
        document.modelArtifactID,
        document.configHash.value,
        try encode(document.sourceReferences),
        try encode(document.result),
        document.state.rawValue,
        document.createdAt.timeIntervalSince1970,
      ]
    )
  }

  private nonisolated static func valid(evidence: EventLinkEvidence) -> Bool {
    let values = [
      evidence.semanticScore,
      evidence.temporalScore,
      evidence.peopleScore,
      evidence.sourceScore,
      evidence.aggregateScore,
    ]
    return !evidence.modelIdentifier.isEmpty
      && values.allSatisfy { $0.isFinite && (0...1).contains($0) }
  }

  private nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private nonisolated static func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data
  ) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    do { return try decoder.decode(type, from: data) } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
  }

  private nonisolated static func jsonString<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    return string
  }
}
