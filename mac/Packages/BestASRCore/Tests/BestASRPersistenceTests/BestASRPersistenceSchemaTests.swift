import BestASRPersistence
import BestASRPersistenceProbe
import Foundation
import GRDB
import XCTest

final class TypelessDictationMigrationTests: XCTestCase {
  func testFreshDatabaseHasAdditiveV1ThroughCurrentSchemaAndWAL() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("store.sqlite")
    )
    let inspection = try await store.inspection()

    XCTAssertEqual(inspection.userVersion, BestASRPersistenceSchema.currentUserVersion)
    XCTAssertEqual(
      inspection.appliedMigrations,
      [
        BestASRPersistenceSchema.foundationMigrationID,
        BestASRPersistenceSchema.syncIdentityMigrationID,
        BestASRPersistenceSchema.dictationAlphaMigrationID,
        BestASRPersistenceSchema.transcriptProvenanceMigrationID,
        BestASRPersistenceSchema.dictationHistoryMigrationID,
        BestASRPersistenceSchema.speakerPipelineMigrationID,
        BestASRPersistenceSchema.sourceAssetsMigrationID,
        BestASRPersistenceSchema.localTextDocumentsMigrationID,
        BestASRPersistenceSchema.personEditingMigrationID,
        BestASRPersistenceSchema.rejectedPersonMatchesMigrationID,
        BestASRPersistenceSchema.sessionMetadataMigrationID,
        BestASRPersistenceSchema.trackDeviceMetadataMigrationID,
        BestASRPersistenceSchema.sourceContextMigrationID,
        BestASRPersistenceSchema.speakerNameEvidenceMigrationID,
        BestASRPersistenceSchema.durableJobForeignKeyRepairMigrationID,
        BestASRPersistenceSchema.speakerMemoryQueryRepairMigrationID,
        BestASRPersistenceSchema.localTextFailureClassificationRepairMigrationID,
        BestASRPersistenceSchema.eventMemoryMigrationID,
        BestASRPersistenceSchema.retainedSourceDurationMigrationID,
        BestASRPersistenceSchema.spokenModeMigrationID,
        BestASRPersistenceSchema.remoteOrganizerMigrationID,
        BestASRPersistenceSchema.remoteOrganizerRevisionOutboxMigrationID,
        BestASRPersistenceSchema.remoteOrganizerEligibilityMigrationID,
        BestASRPersistenceSchema.userItemsMigrationID,
        BestASRPersistenceSchema.userItemFilesMigrationID,
      ]
    )
    XCTAssertEqual(inspection.journalMode, "wal")
    XCTAssertTrue(inspection.foreignKeysEnabled)
    for table in [
      "sessions", "tracks", "audio_chunks", "timeline_events",
      "transcript_revisions", "durable_jobs", "session_speakers", "persons",
      "speaker_occurrences", "speaker_occurrence_tracks", "change_log",
      "tombstones", "dictation_snapshots", "insertion_outcomes",
      "derived_text_revisions", "dictionary_entries", "dictation_job_sessions",
      "transcript_segments", "transcript_audio_ranges",
      "speaker_job_inputs", "session_speaker_embeddings",
      "person_embeddings", "session_source_assets", "local_text_documents",
      "person_edit_operations", "rejected_person_matches", "session_metadata",
      "source_context_events", "speaker_name_evidence",
      "events", "event_sessions", "event_link_rejections", "event_people",
      "event_candidates",
      "event_text_documents", "event_edit_operations",
      "remote_organizer_decisions", "remote_organizer_item_jobs",
      "remote_organizer_decision_jobs", "remote_organizer_events", "remote_organizer_persons",
      "remote_organizer_questions", "remote_organizer_meta", "remote_organizer_eligible",
      "user_item_details",
    ] {
      XCTAssertTrue(inspection.tableNames.contains(table), table)
    }
    try await store.checkpointAndClose()
  }

  func testExistingFoundationV2MigratesForwardWithoutLosingSession() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("foundation.sqlite")
    let probe = PersistenceMigrationProbe()
    try probe.createNMinusOneFixture(at: databaseURL)
    let prior = try probe.migrateToCurrent(at: databaseURL)
    XCTAssertEqual(prior.inspection.schemaVersion, 2)
    XCTAssertEqual(prior.inspection.sessionCount, 1)

    let store = try GRDBDictationStore(databaseURL: databaseURL)
    let inspection = try await store.inspection()
    XCTAssertEqual(inspection.userVersion, BestASRPersistenceSchema.currentUserVersion)
    XCTAssertTrue(inspection.tableNames.contains("dictation_snapshots"))
    XCTAssertTrue(inspection.tableNames.contains("persons"))
    XCTAssertTrue(inspection.tableNames.contains("speaker_name_evidence"))
    try await store.checkpointAndClose()
  }

  func testExistingV5WithDurableJobMappingMigratesWithoutDanglingForeignKey()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("v5-with-job.sqlite")
    let legacy = try DatabaseQueue(path: databaseURL.path)
    try BestASRPersistenceSchema.migrator().migrate(
      legacy,
      upTo: BestASRPersistenceSchema.dictationHistoryMigrationID
    )
    try await legacy.write { database in
      try database.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention,
            created_at, updated_at
          ) VALUES (?, 1, 'dictation', 'completed', 'retained', 1, 1)
          """,
        arguments: ["00000000-0000-0000-0000-000000000001"]
      )
      try database.execute(
        sql: """
          INSERT INTO durable_jobs (
            id, revision, kind, state, input_revision, model_artifact_id,
            config_hash, retry_count, error_category, lease_owner,
            lease_expires_at
          ) VALUES (?, 1, 'speakerFinal', 'queued', 1, NULL, ?, 0,
                    'none', NULL, NULL)
          """,
        arguments: [
          "00000000-0000-0000-0000-000000000002",
          String(repeating: "0", count: 64),
        ]
      )
      try database.execute(
        sql: """
          INSERT INTO dictation_job_sessions (job_id, session_id)
          VALUES (?, ?)
          """,
        arguments: [
          "00000000-0000-0000-0000-000000000002",
          "00000000-0000-0000-0000-000000000001",
        ]
      )
    }
    try legacy.close()

    let store = try GRDBDictationStore(databaseURL: databaseURL)
    let inspection = try await store.inspection()
    XCTAssertEqual(inspection.userVersion, BestASRPersistenceSchema.currentUserVersion)
    try await store.checkpointAndClose()

    let migrated = try DatabaseQueue(path: databaseURL.path)
    let mappingCount = try await migrated.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT COUNT(*) FROM dictation_job_sessions"
      )
    }
    let violations = try await migrated.read { database in
      try Row.fetchAll(database, sql: "PRAGMA foreign_key_check").count
    }
    let relationshipSQL = try await migrated.read { database in
      try String.fetchOne(
        database,
        sql:
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'dictation_job_sessions'"
      )
    }
    XCTAssertEqual(mappingCount, 1)
    XCTAssertEqual(violations, 0)
    XCTAssertFalse(relationshipSQL?.contains("durable_jobs_v6") == true)
    try migrated.close()
  }

  func testSpeakerMemoryQueryRepairRequeuesOnlyStructurallyValidTransientJobs()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("speaker-repair.sqlite")
    let legacy = try DatabaseQueue(path: databaseURL.path)
    try BestASRPersistenceSchema.migrator().migrate(
      legacy,
      upTo: BestASRPersistenceSchema.durableJobForeignKeyRepairMigrationID
    )
    let sessionID = "00000000-0000-0000-0000-000000000101"
    let validJobID = "00000000-0000-0000-0000-000000000102"
    let orphanJobID = "00000000-0000-0000-0000-000000000103"
    try await legacy.write { database in
      try database.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention,
            created_at, updated_at
          ) VALUES (?, 1, 'dictation', 'completed', 'retained', 1, 1)
          """,
        arguments: [sessionID]
      )
      for jobID in [validJobID, orphanJobID] {
        try database.execute(
          sql: """
            INSERT INTO durable_jobs (
              id, revision, kind, state, input_revision, model_artifact_id,
              config_hash, retry_count, error_category, lease_owner,
              lease_expires_at
            ) VALUES (?, 1, 'speakerFinal', 'permanentFailed', 1, NULL, ?, 3,
                      'transientWorker', NULL, NULL)
            """,
          arguments: [jobID, String(repeating: "0", count: 64)]
        )
      }
      try database.execute(
        sql: "INSERT INTO dictation_job_sessions (job_id, session_id) VALUES (?, ?)",
        arguments: [validJobID, sessionID]
      )
      try database.execute(
        sql: """
          INSERT INTO speaker_job_inputs (
            job_id, session_id, audio_ranges_json, model_artifact_key,
            embedding_space_id, created_at
          ) VALUES (?, ?, '[]', 'speaker-v1', 'space-v1', 1)
          """,
        arguments: [validJobID, sessionID]
      )
    }
    try legacy.close()

    let store = try GRDBDictationStore(databaseURL: databaseURL)
    try await store.checkpointAndClose()
    let repaired = try DatabaseQueue(path: databaseURL.path)
    let rows = try await durableJobSnapshots(in: repaired)
    XCTAssertEqual(rows[0].id, validJobID)
    XCTAssertEqual(rows[0].state, "queued")
    XCTAssertEqual(rows[0].retryCount, 0)
    XCTAssertEqual(rows[0].errorCategory, "none")
    XCTAssertEqual(rows[1].id, orphanJobID)
    XCTAssertEqual(rows[1].state, "permanentFailed")
    XCTAssertEqual(rows[1].retryCount, 3)
    XCTAssertEqual(rows[1].errorCategory, "transientWorker")
    try repaired.close()
  }

  func testLocalTextFailureClassificationRepairRequeuesLinkedWorkOnce()
    async throws
  {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("local-text-repair.sqlite")
    let legacy = try DatabaseQueue(path: databaseURL.path)
    try BestASRPersistenceSchema.migrator().migrate(
      legacy,
      upTo: BestASRPersistenceSchema.speakerMemoryQueryRepairMigrationID
    )
    let sessionID = "00000000-0000-0000-0000-000000000111"
    let validJobID = "00000000-0000-0000-0000-000000000112"
    let orphanJobID = "00000000-0000-0000-0000-000000000113"
    try await legacy.write { database in
      try database.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention,
            created_at, updated_at
          ) VALUES (?, 1, 'roomMicrophone', 'completed', 'retained', 1, 1)
          """,
        arguments: [sessionID]
      )
      for jobID in [validJobID, orphanJobID] {
        try database.execute(
          sql: """
            INSERT INTO durable_jobs (
              id, revision, kind, state, input_revision, model_artifact_id,
              config_hash, retry_count, error_category, lease_owner,
              lease_expires_at
            ) VALUES (?, 1, 'localText', 'permanentFailed', 1, NULL, ?, 4,
                      'transientWorker', NULL, NULL)
            """,
          arguments: [jobID, String(repeating: "0", count: 64)]
        )
      }
      try database.execute(
        sql: "INSERT INTO dictation_job_sessions (job_id, session_id) VALUES (?, ?)",
        arguments: [validJobID, sessionID]
      )
    }
    try legacy.close()

    let store = try GRDBDictationStore(databaseURL: databaseURL)
    try await store.checkpointAndClose()
    let repaired = try DatabaseQueue(path: databaseURL.path)
    let rows = try await durableJobSnapshots(in: repaired)
    XCTAssertEqual(rows[0].id, validJobID)
    XCTAssertEqual(rows[0].state, "queued")
    XCTAssertEqual(rows[0].retryCount, 0)
    XCTAssertEqual(rows[0].errorCategory, "none")
    XCTAssertEqual(rows[1].id, orphanJobID)
    XCTAssertEqual(rows[1].state, "permanentFailed")
    XCTAssertEqual(rows[1].retryCount, 4)
    XCTAssertEqual(rows[1].errorCategory, "transientWorker")
    try repaired.close()
  }

  /// Builds each prior archive from a database really migrated up to that
  /// version, so its column lists are the historical ones (v16 has no
  /// `duration_ns`, v17 has no `spoken_mode`, v21 has no `user_item_details`),
  /// and imports it into a current store.
  func testPortableSchema12Through21UpgradeFromHistoricalColumns() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("source.sqlite")
    )
    let current = try await source.exportPortablePersistenceState()
    try await source.checkpointAndClose()
    XCTAssertEqual(current.schemaVersion, BestASRPersistenceSchema.currentUserVersion)
    let currentOrder = current.tables.map(\.name)
    XCTAssertEqual(
      Array(currentOrder.suffix(11)),
      [
        "source_context_events", "speaker_name_evidence", "events",
        "event_sessions", "event_link_rejections", "event_people",
        "event_candidates",
        "event_text_documents", "event_edit_operations",
        "remote_organizer_decisions", "user_item_details",
      ])
    let priorMigrations: [(version: Int, migrationID: String)] = [
      (12, BestASRPersistenceSchema.trackDeviceMetadataMigrationID),
      (13, BestASRPersistenceSchema.sourceContextMigrationID),
      (14, BestASRPersistenceSchema.speakerNameEvidenceMigrationID),
      (15, BestASRPersistenceSchema.localTextFailureClassificationRepairMigrationID),
      (16, BestASRPersistenceSchema.eventMemoryMigrationID),
      (17, BestASRPersistenceSchema.retainedSourceDurationMigrationID),
      (18, BestASRPersistenceSchema.spokenModeMigrationID),
      (19, BestASRPersistenceSchema.remoteOrganizerMigrationID),
      (20, BestASRPersistenceSchema.remoteOrganizerRevisionOutboxMigrationID),
      (21, BestASRPersistenceSchema.remoteOrganizerEligibilityMigrationID),
      (22, BestASRPersistenceSchema.userItemsMigrationID),
    ]
    for (version, migrationID) in priorMigrations {
      let sessionID = UUID().uuidString
      let oldURL = root.appendingPathComponent("historical-v\(version).sqlite")
      let old = try DatabaseQueue(path: oldURL.path)
      try BestASRPersistenceSchema.migrator().migrate(old, upTo: migrationID)
      let prior = try await old.write { db -> PortablePersistenceState in
        let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        XCTAssertEqual(userVersion, version)
        try db.execute(
          sql: """
            INSERT INTO sessions (
              id, revision, input_mode, state, source_audio_retention,
              created_at, updated_at
            ) VALUES (?, 1, 'dictation', 'completed', 'retained', 1000, 1001)
            """,
          arguments: [sessionID]
        )
        var tables: [PortableDatabaseTable] = []
        for name in currentOrder {
          guard try db.tableExists(name) else { continue }
          let columns = try db.columns(in: name).map(\.name)
          let rows = try Row.fetchAll(
            db, sql: "SELECT * FROM \(name.quotedDatabaseIdentifier) ORDER BY rowid"
          )
          tables.append(
            PortableDatabaseTable(
              name: name, columns: columns,
              rows: rows.map { row in row.databaseValues.map(portableValue) }
            )
          )
        }
        return PortablePersistenceState(schemaVersion: userVersion, tables: tables)
      }
      try old.close()
      let detailColumns = prior.tables.first { $0.name == "user_item_details" }?.columns ?? []
      XCTAssertFalse(detailColumns.contains("frame_ms"), "v\(version)")
      let sessionColumns = prior.tables.first { $0.name == "sessions" }?.columns ?? []
      XCTAssertEqual(sessionColumns.contains("spoken_mode"), version >= 18, "v\(version)")
      let assetColumns =
        prior.tables.first { $0.name == "session_source_assets" }?.columns ?? []
      XCTAssertEqual(assetColumns.contains("duration_ns"), version >= 17, "v\(version)")

      let destination = try GRDBDictationStore(
        databaseURL: root.appendingPathComponent("imported-v\(version).sqlite")
      )
      try await destination.importPortablePersistenceState(prior)
      let upgraded = try await destination.exportPortablePersistenceState()
      XCTAssertEqual(upgraded.schemaVersion, BestASRPersistenceSchema.currentUserVersion)
      XCTAssertEqual(upgraded.tables.map(\.name), currentOrder, "v\(version)")
      XCTAssertEqual(
        upgraded.tables.map(\.columns), current.tables.map(\.columns), "v\(version)"
      )
      let sessions = try XCTUnwrap(upgraded.tables.first { $0.name == "sessions" })
      XCTAssertEqual(sessions.rows.count, 1, "v\(version)")
      let idIndex = try XCTUnwrap(sessions.columns.firstIndex(of: "id"))
      XCTAssertEqual(sessions.rows.first?[idIndex], .text(sessionID))
      let modeIndex = try XCTUnwrap(sessions.columns.firstIndex(of: "spoken_mode"))
      XCTAssertEqual(sessions.rows.first?[modeIndex], .null)
      XCTAssertTrue(upgraded.tables.suffix(11).allSatisfy { $0.rows.isEmpty })
      try await destination.checkpointAndClose()
    }
  }

}

private func portableValue(_ value: DatabaseValue) -> PortableSQLiteValue {
  switch value.storage {
  case .blob(let data): .blob(data)
  case .double(let number): .double(number)
  case .int64(let number): .integer(number)
  case .null: .null
  case .string(let text): .text(text)
  }
}

/// One `durable_jobs` row as Sendable values, so an async GRDB read can
/// return it (`Row` itself is not Sendable).
private struct DurableJobSnapshot: Sendable {
  let id: String
  let state: String
  let retryCount: Int
  let errorCategory: String
}

private func durableJobSnapshots(
  in queue: DatabaseQueue
) async throws -> [DurableJobSnapshot] {
  try await queue.read { database in
    try Row.fetchAll(
      database,
      sql: """
        SELECT id, state, retry_count, error_category
        FROM durable_jobs ORDER BY id
        """
    ).map { row in
      DurableJobSnapshot(
        id: row["id"],
        state: row["state"],
        retryCount: row["retry_count"],
        errorCategory: row["error_category"]
      )
    }
  }
}
