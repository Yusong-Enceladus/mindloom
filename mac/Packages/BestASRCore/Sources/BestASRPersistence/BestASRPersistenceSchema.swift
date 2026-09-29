import GRDB

public enum BestASRPersistenceSchema {
  public static let foundationMigrationID = "v1-foundation"
  public static let syncIdentityMigrationID = "v2-sync-identity"
  public static let dictationAlphaMigrationID = "v3-local-dictation-alpha"
  public static let transcriptProvenanceMigrationID = "v4-transcript-provenance"
  public static let dictationHistoryMigrationID = "v5-dictation-history-recovery"
  public static let speakerPipelineMigrationID = "v6-production-speaker-pipeline"
  public static let sourceAssetsMigrationID = "v7-retained-source-assets"
  public static let localTextDocumentsMigrationID = "v8-local-text-documents"
  public static let personEditingMigrationID = "v9-person-editing"
  public static let rejectedPersonMatchesMigrationID = "v10-rejected-person-matches"
  public static let sessionMetadataMigrationID = "v11-session-metadata"
  public static let trackDeviceMetadataMigrationID = "v12-track-device-metadata"
  public static let sourceContextMigrationID = "v13-local-source-context"
  public static let speakerNameEvidenceMigrationID =
    "v14-platform-speaker-name-evidence"
  public static let durableJobForeignKeyRepairMigrationID =
    "v15-durable-job-foreign-key-repair"
  public static let speakerMemoryQueryRepairMigrationID =
    "v15.1-speaker-memory-query-repair"
  public static let localTextFailureClassificationRepairMigrationID =
    "v15.2-local-text-failure-classification-repair"
  public static let eventMemoryMigrationID = "v16-event-memory"
  public static let retainedSourceDurationMigrationID = "v17-retained-source-duration"
  public static let spokenModeMigrationID = "v18-spoken-mode"
  public static let remoteOrganizerMigrationID = "v19-remote-organizer"
  public static let remoteOrganizerRevisionOutboxMigrationID =
    "v20-remote-organizer-revision-outbox"
  public static let remoteOrganizerEligibilityMigrationID =
    "v21-remote-organizer-eligibility"
  public static let userItemsMigrationID = "v22-user-items"
  public static let userItemFilesMigrationID = "v23-user-item-files"
  public static let currentUserVersion = 23
  public static let minimumPortableImportUserVersion = 12

  public static func supportsPortableImport(userVersion: Int) -> Bool {
    (minimumPortableImportUserVersion...currentUserVersion).contains(userVersion)
  }

  public static func migrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(foundationMigrationID) { database in
      try database.execute(sql: foundationSQL)
    }
    migrator.registerMigration(syncIdentityMigrationID) { database in
      try database.execute(sql: syncIdentitySQL)
    }
    migrator.registerMigration(dictationAlphaMigrationID) { database in
      try database.execute(sql: dictationAlphaSQL)
    }
    migrator.registerMigration(transcriptProvenanceMigrationID) { database in
      try database.execute(sql: transcriptProvenanceSQL)
    }
    migrator.registerMigration(dictationHistoryMigrationID) { database in
      try database.execute(sql: dictationHistorySQL)
    }
    migrator.registerMigration(speakerPipelineMigrationID) { database in
      try database.execute(sql: speakerPipelineSQL)
    }
    migrator.registerMigration(sourceAssetsMigrationID) { database in
      try database.execute(sql: sourceAssetsSQL)
    }
    migrator.registerMigration(localTextDocumentsMigrationID) { database in
      try database.execute(sql: localTextDocumentsSQL)
    }
    migrator.registerMigration(personEditingMigrationID) { database in
      try database.execute(sql: personEditingSQL)
    }
    migrator.registerMigration(rejectedPersonMatchesMigrationID) { database in
      try database.execute(sql: rejectedPersonMatchesSQL)
    }
    migrator.registerMigration(sessionMetadataMigrationID) { database in
      try database.execute(sql: sessionMetadataSQL)
    }
    migrator.registerMigration(trackDeviceMetadataMigrationID) { database in
      try database.execute(sql: trackDeviceMetadataSQL)
    }
    migrator.registerMigration(sourceContextMigrationID) { database in
      try database.execute(sql: sourceContextSQL)
    }
    migrator.registerMigration(speakerNameEvidenceMigrationID) { database in
      try database.execute(sql: speakerNameEvidenceSQL)
    }
    migrator.registerMigration(durableJobForeignKeyRepairMigrationID) { database in
      try database.execute(sql: durableJobForeignKeyRepairSQL)
    }
    migrator.registerMigration(speakerMemoryQueryRepairMigrationID) { database in
      try database.execute(sql: speakerMemoryQueryRepairSQL)
    }
    migrator.registerMigration(localTextFailureClassificationRepairMigrationID) {
      database in
      try database.execute(sql: localTextFailureClassificationRepairSQL)
    }
    migrator.registerMigration(eventMemoryMigrationID) { database in
      try database.execute(sql: eventMemorySQL)
    }
    migrator.registerMigration(retainedSourceDurationMigrationID) { database in
      try database.execute(sql: retainedSourceDurationSQL)
    }
    migrator.registerMigration(spokenModeMigrationID) { database in
      try database.execute(sql: spokenModeSQL)
    }
    migrator.registerMigration(remoteOrganizerMigrationID) { database in
      try database.execute(sql: remoteOrganizerSQL)
    }
    migrator.registerMigration(remoteOrganizerRevisionOutboxMigrationID) { database in
      try database.execute(sql: remoteOrganizerRevisionOutboxSQL)
    }
    migrator.registerMigration(remoteOrganizerEligibilityMigrationID) { database in
      try database.execute(sql: remoteOrganizerEligibilitySQL)
    }
    migrator.registerMigration(userItemsMigrationID) { database in
      try database.execute(sql: userItemsSQL)
    }
    migrator.registerMigration(userItemFilesMigrationID) { database in
      try database.execute(sql: userItemFilesSQL)
    }
    return migrator
  }

  /// A pasted or dragged item (PRD §0.3.2) is a `sessions` row with input mode
  /// `userItem`; its body text is a `final` transcript revision and its files
  /// are `session_source_assets`. This table holds only what a recording does
  /// not have: the item kind, when it was captured, how its source App label
  /// was decided, the extractor, and image/page facts. Portable user data.
  public static let userItemsSQL = """
    CREATE TABLE user_item_details (
      session_id TEXT PRIMARY KEY NOT NULL
        REFERENCES sessions(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      item_kind TEXT NOT NULL CHECK (item_kind IN ('text', 'image', 'document')),
      captured_at REAL NOT NULL,
      source_origin TEXT NOT NULL CHECK (
        source_origin IN ('previousFrontmost', 'dragSource', 'finder', 'user', 'unknown')
      ),
      extractor TEXT NOT NULL CHECK (length(extractor) BETWEEN 1 AND 128),
      page_count INTEGER CHECK (page_count IS NULL OR page_count >= 0),
      pixel_width INTEGER CHECK (pixel_width IS NULL OR pixel_width > 0),
      pixel_height INTEGER CHECK (pixel_height IS NULL OR pixel_height > 0),
      original_asset_id TEXT,
      normalized_asset_id TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX user_item_details_kind_index
      ON user_item_details(item_kind, captured_at);
    PRAGMA user_version = 22;
    """

  /// Any file may now be taken in (files contract): item kind `file` keeps
  /// the file byte for byte with whatever text this Mac read. New trailing
  /// columns: the file's Uniform Type Identifier, and for a video keyframe
  /// its recording (`parent_session_id`, no foreign key: deleting the
  /// recording never fails because of a frame) and position (`frame_ms`).
  /// SQLite cannot widen a CHECK, so the table is rebuilt with every row.
  public static let userItemFilesSQL = """
    CREATE TABLE user_item_details_v23 (
      session_id TEXT PRIMARY KEY NOT NULL
        REFERENCES sessions(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      item_kind TEXT NOT NULL CHECK (item_kind IN ('text', 'image', 'document', 'file')),
      captured_at REAL NOT NULL,
      source_origin TEXT NOT NULL CHECK (
        source_origin IN ('previousFrontmost', 'dragSource', 'finder', 'user', 'unknown')
      ),
      extractor TEXT NOT NULL CHECK (length(extractor) BETWEEN 1 AND 128),
      page_count INTEGER CHECK (page_count IS NULL OR page_count >= 0),
      pixel_width INTEGER CHECK (pixel_width IS NULL OR pixel_width > 0),
      pixel_height INTEGER CHECK (pixel_height IS NULL OR pixel_height > 0),
      original_asset_id TEXT,
      normalized_asset_id TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      uniform_type TEXT CHECK (
        uniform_type IS NULL OR length(uniform_type) BETWEEN 1 AND 256
      ),
      parent_session_id TEXT CHECK (
        parent_session_id IS NULL OR length(parent_session_id) = 36
      ),
      frame_ms INTEGER CHECK (frame_ms IS NULL OR frame_ms >= 0)
    );
    INSERT INTO user_item_details_v23 (
      session_id, revision, item_kind, captured_at, source_origin, extractor,
      page_count, pixel_width, pixel_height, original_asset_id, normalized_asset_id,
      created_at, updated_at
    )
    SELECT session_id, revision, item_kind, captured_at, source_origin, extractor,
      page_count, pixel_width, pixel_height, original_asset_id, normalized_asset_id,
      created_at, updated_at
    FROM user_item_details;
    DROP TABLE user_item_details;
    ALTER TABLE user_item_details_v23 RENAME TO user_item_details;
    CREATE INDEX user_item_details_kind_index
      ON user_item_details(item_kind, captured_at);
    CREATE INDEX user_item_details_parent_index
      ON user_item_details(parent_session_id) WHERE parent_session_id IS NOT NULL;
    PRAGMA user_version = 23;
    """

  /// Which sessions may ever be sent automatically is recorded explicitly when
  /// a capture starts while the link is enabled (`remote_organizer_eligible`),
  /// never inferred from `created_at`, so rows restored by a portable-archive
  /// import or recorded while the link was off never qualify. Decision jobs
  /// remember the Spark store they were made against. A library whose link is
  /// off (every v19 library: its switch was an app preference) keeps no pending
  /// work, exactly as after a revoke: never-delivered item jobs are dropped,
  /// pending updates of delivered items are cancelled, and pending decisions
  /// are cancelled (an attempted one is marked delivery-unknown).
  public static let remoteOrganizerEligibilitySQL = """
    CREATE TABLE remote_organizer_eligible (
      session_id TEXT PRIMARY KEY NOT NULL,
      eligible_at REAL NOT NULL
    );
    INSERT INTO remote_organizer_eligible (session_id, eligible_at)
    SELECT item_id, created_at FROM remote_organizer_item_jobs;
    ALTER TABLE remote_organizer_decision_jobs ADD COLUMN store_id TEXT;
    DELETE FROM remote_organizer_item_jobs
    WHERE delivered_revision IS NULL
      AND NOT EXISTS (SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at');
    UPDATE remote_organizer_item_jobs
    SET state = 'delivered', lease_expires_at = NULL, not_before = 0, error_category = 'none'
    WHERE state <> 'delivered'
      AND NOT EXISTS (SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at');
    DELETE FROM remote_organizer_eligible
    WHERE NOT EXISTS (SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at')
      AND session_id NOT IN (
        SELECT item_id FROM remote_organizer_item_jobs WHERE delivered_revision IS NOT NULL
      );
    UPDATE remote_organizer_decision_jobs
    SET error_category = CASE
          WHEN state = 'running' OR retry_count > 0 THEN 'in_flight' ELSE 'revoked'
        END,
        state = 'cancelled', lease_expires_at = NULL, error_reason = NULL
    WHERE state IN ('queued', 'running')
      AND NOT EXISTS (SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at');
    PRAGMA user_version = 21;
    """

  /// The item outbox tracks one row per session and a monotonic target
  /// revision; the payload is built from the session's current content when a
  /// send is claimed, never frozen at enqueue time. Triggers mark a tracked
  /// item as changed in the same transaction as every transcript, speaker, or
  /// person-name commit, but only while the link is enabled. Decision jobs
  /// reference the immutable decision rows and add a visible `cancelled` state.
  public static let remoteOrganizerRevisionOutboxSQL = """
    CREATE TABLE remote_organizer_item_jobs (
      item_id TEXT PRIMARY KEY NOT NULL,
      target_revision INTEGER NOT NULL CHECK (target_revision >= 0),
      state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'delivered', 'failed')),
      change_seq INTEGER NOT NULL DEFAULT 0,
      claimed_change_seq INTEGER,
      attempted_revision INTEGER,
      attempted_sha256 TEXT,
      delivered_revision INTEGER,
      delivered_sha256 TEXT,
      retry_count INTEGER NOT NULL DEFAULT 0,
      error_category TEXT NOT NULL DEFAULT 'none',
      not_before REAL NOT NULL DEFAULT 0,
      lease_expires_at REAL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      delivered_at REAL
    );
    CREATE INDEX remote_organizer_item_jobs_claim
      ON remote_organizer_item_jobs(state, not_before, created_at);
    CREATE TABLE remote_organizer_decision_jobs (
      decision_id TEXT PRIMARY KEY NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('decision', 'question')),
      state TEXT NOT NULL CHECK (
        state IN ('queued', 'running', 'delivered', 'failed', 'cancelled')
      ),
      retry_count INTEGER NOT NULL DEFAULT 0,
      error_category TEXT NOT NULL DEFAULT 'none',
      error_reason TEXT,
      not_before REAL NOT NULL DEFAULT 0,
      lease_expires_at REAL,
      created_at REAL NOT NULL,
      delivered_at REAL
    );
    CREATE INDEX remote_organizer_decision_jobs_order
      ON remote_organizer_decision_jobs(created_at, decision_id);
    INSERT INTO remote_organizer_item_jobs (
      item_id, target_revision, state, attempted_revision, attempted_sha256,
      delivered_revision, retry_count, error_category, created_at, updated_at,
      delivered_at
    )
    SELECT item_id,
           MAX(item_revision),
           CASE
             WHEN SUM(state IN ('queued', 'running')) > 0 THEN 'queued'
             WHEN SUM(state = 'delivered') > 0 THEN 'delivered'
             ELSE 'failed'
           END,
           MAX(CASE WHEN state <> 'queued' OR retry_count > 0 THEN item_revision END),
           CASE
             WHEN MAX(CASE WHEN state <> 'queued' OR retry_count > 0 THEN 1 END) = 1
             THEN 'unknown'
           END,
           MAX(CASE WHEN state = 'delivered' THEN item_revision END),
           0, 'none', MIN(created_at), MAX(created_at), MAX(delivered_at)
    FROM remote_organizer_outbox
    WHERE kind = 'item' AND item_id IS NOT NULL AND item_revision IS NOT NULL
    GROUP BY item_id;
    INSERT INTO remote_organizer_decision_jobs (
      decision_id, kind, state, retry_count, error_category, not_before,
      created_at, delivered_at
    )
    SELECT o.id, o.kind,
           CASE o.state WHEN 'running' THEN 'queued' ELSE o.state END,
           o.retry_count, o.error_category, o.not_before,
           COALESCE(d.created_at, o.created_at), o.delivered_at
    FROM remote_organizer_outbox o
    LEFT JOIN remote_organizer_decisions d ON d.id = o.id
    WHERE o.kind IN ('decision', 'question');
    DROP TABLE remote_organizer_outbox;
    CREATE TRIGGER remote_organizer_item_transcript_inserted
    AFTER INSERT ON transcript_revisions
    WHEN NEW.kind IN ('final', 'userEdit')
    BEGIN
      UPDATE remote_organizer_item_jobs SET
        change_seq = change_seq + 1,
        state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
        retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
        not_before = 0,
        updated_at = (julianday('now') - 2440587.5) * 86400.0
      WHERE item_id = NEW.session_id
        AND EXISTS (
          SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
        );
    END;
    CREATE TRIGGER remote_organizer_item_transcript_deleted
    AFTER DELETE ON transcript_revisions
    WHEN OLD.kind IN ('final', 'userEdit')
    BEGIN
      UPDATE remote_organizer_item_jobs SET
        change_seq = change_seq + 1,
        state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
        retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
        not_before = 0,
        updated_at = (julianday('now') - 2440587.5) * 86400.0
      WHERE item_id = OLD.session_id
        AND EXISTS (
          SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
        );
    END;
    CREATE TRIGGER remote_organizer_item_occurrence_inserted
    AFTER INSERT ON speaker_occurrences
    BEGIN
      UPDATE remote_organizer_item_jobs SET
        change_seq = change_seq + 1,
        state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
        retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
        not_before = 0,
        updated_at = (julianday('now') - 2440587.5) * 86400.0
      WHERE item_id = NEW.session_id
        AND EXISTS (
          SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
        );
    END;
    CREATE TRIGGER remote_organizer_item_occurrence_deleted
    AFTER DELETE ON speaker_occurrences
    BEGIN
      UPDATE remote_organizer_item_jobs SET
        change_seq = change_seq + 1,
        state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
        retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
        not_before = 0,
        updated_at = (julianday('now') - 2440587.5) * 86400.0
      WHERE item_id = OLD.session_id
        AND EXISTS (
          SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
        );
    END;
    CREATE TRIGGER remote_organizer_item_occurrence_updated
    AFTER UPDATE OF person_id, association_status, monotonic_start_ns, monotonic_end_ns ON speaker_occurrences
    BEGIN
      UPDATE remote_organizer_item_jobs SET
        change_seq = change_seq + 1,
        state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
        retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
        not_before = 0,
        updated_at = (julianday('now') - 2440587.5) * 86400.0
      WHERE item_id IN (NEW.session_id, OLD.session_id)
        AND EXISTS (
          SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
        );
    END;
    CREATE TRIGGER remote_organizer_item_person_updated
    AFTER UPDATE OF display_name, retired_at ON persons
    BEGIN
      UPDATE remote_organizer_item_jobs SET
        change_seq = change_seq + 1,
        state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
        retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
        not_before = 0,
        updated_at = (julianday('now') - 2440587.5) * 86400.0
      WHERE item_id IN (
          SELECT session_id FROM speaker_occurrences WHERE person_id = NEW.id
        )
        AND EXISTS (
          SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
        );
    END;
    CREATE TRIGGER remote_organizer_item_source_updated
    AFTER UPDATE OF source_display_name, source_bundle_id ON session_metadata
    BEGIN
      UPDATE remote_organizer_item_jobs SET
        change_seq = change_seq + 1,
        state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
        retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
        not_before = 0,
        updated_at = (julianday('now') - 2440587.5) * 86400.0
      WHERE item_id = NEW.session_id
        AND EXISTS (
          SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at'
        );
    END;
    PRAGMA user_version = 20;
    """

  /// Outbox and projections are local and rebuildable. Explicit user decisions
  /// are portable source data and remain separate from remote model results.
  public static let remoteOrganizerSQL = """
    CREATE TABLE remote_organizer_decisions (
      id TEXT PRIMARY KEY NOT NULL,
      payload_json BLOB NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE TABLE remote_organizer_outbox (
      id TEXT PRIMARY KEY NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('item', 'decision', 'question')),
      item_id TEXT,
      item_revision INTEGER,
      payload_json BLOB NOT NULL,
      payload_sha256 TEXT NOT NULL CHECK (length(payload_sha256) = 64),
      state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'delivered', 'failed')),
      retry_count INTEGER NOT NULL DEFAULT 0,
      error_category TEXT NOT NULL DEFAULT 'none',
      not_before REAL NOT NULL DEFAULT 0,
      lease_expires_at REAL,
      created_at REAL NOT NULL,
      delivered_at REAL,
      UNIQUE (kind, item_id, item_revision)
    );
    CREATE INDEX remote_organizer_outbox_claim
      ON remote_organizer_outbox(state, not_before, created_at);
    CREATE TABLE remote_organizer_events (
      event_id TEXT PRIMARY KEY NOT NULL,
      payload_json BLOB NOT NULL
    );
    CREATE TABLE remote_organizer_persons (
      person_id TEXT PRIMARY KEY NOT NULL,
      payload_json BLOB NOT NULL
    );
    CREATE TABLE remote_organizer_questions (
      question_id TEXT PRIMARY KEY NOT NULL,
      payload_json BLOB NOT NULL
    );
    CREATE TABLE remote_organizer_meta (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    );
    INSERT INTO remote_organizer_meta(key, value) VALUES ('cursor', '0');
    PRAGMA user_version = 19;
    """

  /// Which spoken mode a dictation was delivered in — 翻译 or 指令 — so history
  /// can say so and delivery health can be attributed. NULL for a plain
  /// dictation and for every session written before this column existed.
  public static let spokenModeSQL = """
    ALTER TABLE sessions ADD COLUMN spoken_mode TEXT;
    PRAGMA user_version = 18;
    """

  /// One-time recovery for speaker jobs exhausted by the v15 person-memory
  /// query that used an ambiguous unqualified `revision` ordering column.
  /// Structurally incomplete legacy jobs remain quarantined.
  public static let speakerMemoryQueryRepairSQL = """
    UPDATE durable_jobs
    SET revision = revision + 1,
        state = 'queued',
        retry_count = 0,
        error_category = 'none',
        lease_owner = NULL,
        lease_expires_at = NULL
    WHERE kind = 'speakerFinal'
      AND state IN ('retryableFailed', 'permanentFailed')
      AND error_category = 'transientWorker'
      AND EXISTS (
        SELECT 1 FROM speaker_job_inputs input WHERE input.job_id = durable_jobs.id
      )
      AND EXISTS (
        SELECT 1 FROM dictation_job_sessions mapping
        WHERE mapping.job_id = durable_jobs.id
      );
    """

  /// Older workers collapsed every local-text error into transient failure.
  /// Give structurally linked work one attempt under the category-aware worker;
  /// the migration is recorded, so deterministic failures do not loop on launch.
  public static let localTextFailureClassificationRepairSQL = """
    UPDATE durable_jobs
    SET revision = revision + 1,
        state = 'queued',
        retry_count = 0,
        error_category = 'none',
        lease_owner = NULL,
        lease_expires_at = NULL
    WHERE kind = 'localText'
      AND state IN ('retryableFailed', 'permanentFailed')
      AND error_category = 'transientWorker'
      AND EXISTS (
        SELECT 1 FROM dictation_job_sessions mapping
        WHERE mapping.job_id = durable_jobs.id
      );
    """

  /// Installs a rebuildable full-text index without changing the portable
  /// user-data schema. The FTS rows and triggers are derived exclusively from
  /// portable tables, are intentionally excluded from `.bestasrarchive`, and
  /// can be dropped and reconstructed at any time.
  public static func installHistorySearchIndex(in database: Database) throws {
    let revision = "5"
    try database.execute(
      sql: """
        CREATE TABLE IF NOT EXISTS bestasr_derived_index_metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        );
        """)
    let installedRevision = try String.fetchOne(
      database,
      sql: "SELECT value FROM bestasr_derived_index_metadata WHERE key = 'history-search'"
    )
    let triggerNames = [
      "history_search_session_metadata_insert",
      "history_search_session_metadata_update",
      "history_search_session_metadata_delete",
      "history_search_transcript_insert",
      "history_search_transcript_update",
      "history_search_transcript_delete",
      "history_search_derived_text_insert",
      "history_search_derived_text_update",
      "history_search_derived_text_delete",
      "history_search_local_text_insert",
      "history_search_local_text_update",
      "history_search_local_text_delete",
      "history_search_source_asset_insert",
      "history_search_source_asset_update",
      "history_search_source_asset_delete",
      "history_search_person_insert",
      "history_search_person_update",
      "history_search_person_delete",
      "history_search_source_context_insert",
      "history_search_source_context_update",
      "history_search_source_context_delete",
      "history_search_event_insert",
      "history_search_event_update",
      "history_search_event_delete",
      "history_search_event_text_insert",
      "history_search_event_text_update",
      "history_search_event_text_delete",
    ]
    for name in triggerNames {
      try database.execute(
        sql: "DROP TRIGGER IF EXISTS \(name.quotedDatabaseIdentifier)"
      )
    }
    if installedRevision != revision {
      try database.execute(sql: "DROP TABLE IF EXISTS history_search_fts")
    }
    try database.execute(
      sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS history_search_fts USING fts5(
          session_id UNINDEXED,
          person_id UNINDEXED,
          source_kind UNINDEXED,
          source_id UNINDEXED,
          content,
          tokenize = 'trigram'
        );

        CREATE TRIGGER history_search_session_metadata_insert
        AFTER INSERT ON session_metadata BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (
            NEW.session_id, NULL, 'session_metadata', NEW.session_id,
            NEW.title || ' ' || COALESCE(NEW.source_display_name, '') || ' ' ||
            COALESCE(NEW.source_identifier, '') || ' ' ||
            COALESCE(NEW.source_bundle_id, '')
          );
        END;
        CREATE TRIGGER history_search_session_metadata_update
        AFTER UPDATE ON session_metadata BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'session_metadata' AND source_id = OLD.session_id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (
            NEW.session_id, NULL, 'session_metadata', NEW.session_id,
            NEW.title || ' ' || COALESCE(NEW.source_display_name, '') || ' ' ||
            COALESCE(NEW.source_identifier, '') || ' ' ||
            COALESCE(NEW.source_bundle_id, '')
          );
        END;
        CREATE TRIGGER history_search_session_metadata_delete
        AFTER DELETE ON session_metadata BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'session_metadata' AND source_id = OLD.session_id;
        END;

        CREATE TRIGGER history_search_transcript_insert
        AFTER INSERT ON transcript_revisions BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (NEW.session_id, NULL, 'transcript', NEW.id, NEW.content);
        END;
        CREATE TRIGGER history_search_transcript_update
        AFTER UPDATE ON transcript_revisions BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'transcript' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (NEW.session_id, NULL, 'transcript', NEW.id, NEW.content);
        END;
        CREATE TRIGGER history_search_transcript_delete
        AFTER DELETE ON transcript_revisions BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'transcript' AND source_id = OLD.id;
        END;

        CREATE TRIGGER history_search_derived_text_insert
        AFTER INSERT ON derived_text_revisions BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NEW.session_id, NULL, 'derived_text', NEW.id, NEW.output_text
            WHERE NEW.state = 'current';
        END;
        CREATE TRIGGER history_search_derived_text_update
        AFTER UPDATE ON derived_text_revisions BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'derived_text' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NEW.session_id, NULL, 'derived_text', NEW.id, NEW.output_text
            WHERE NEW.state = 'current';
        END;
        CREATE TRIGGER history_search_derived_text_delete
        AFTER DELETE ON derived_text_revisions BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'derived_text' AND source_id = OLD.id;
        END;

        CREATE TRIGGER history_search_local_text_insert
        AFTER INSERT ON local_text_documents BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NEW.session_id, NULL, 'local_text', NEW.id,
            CAST(NEW.result_json AS TEXT) WHERE NEW.state = 'current';
        END;
        CREATE TRIGGER history_search_local_text_update
        AFTER UPDATE ON local_text_documents BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'local_text' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NEW.session_id, NULL, 'local_text', NEW.id,
            CAST(NEW.result_json AS TEXT) WHERE NEW.state = 'current';
        END;
        CREATE TRIGGER history_search_local_text_delete
        AFTER DELETE ON local_text_documents BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'local_text' AND source_id = OLD.id;
        END;

        CREATE TRIGGER history_search_source_asset_insert
        AFTER INSERT ON session_source_assets BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (
            NEW.session_id, NULL, 'source_asset', NEW.id, NEW.original_filename
          );
        END;
        CREATE TRIGGER history_search_source_asset_update
        AFTER UPDATE ON session_source_assets BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'source_asset' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (
            NEW.session_id, NULL, 'source_asset', NEW.id, NEW.original_filename
          );
        END;
        CREATE TRIGGER history_search_source_asset_delete
        AFTER DELETE ON session_source_assets BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'source_asset' AND source_id = OLD.id;
        END;

        CREATE TRIGGER history_search_person_insert
        AFTER INSERT ON persons BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NULL, NEW.id, 'person', NEW.id,
            CASE WHEN trim(COALESCE(NEW.display_name, '')) = ''
              THEN '待命名 未知人物 ' ELSE '' END ||
            COALESCE(NEW.display_name, '') || ' ' || CAST(NEW.aliases_json AS TEXT)
            WHERE NEW.retired_at IS NULL;
        END;
        CREATE TRIGGER history_search_person_update
        AFTER UPDATE ON persons BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'person' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NULL, NEW.id, 'person', NEW.id,
            CASE WHEN trim(COALESCE(NEW.display_name, '')) = ''
              THEN '待命名 未知人物 ' ELSE '' END ||
            COALESCE(NEW.display_name, '') || ' ' || CAST(NEW.aliases_json AS TEXT)
            WHERE NEW.retired_at IS NULL;
        END;
        CREATE TRIGGER history_search_person_delete
        AFTER DELETE ON persons BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'person' AND source_id = OLD.id;
        END;

        CREATE TRIGGER history_search_source_context_insert
        AFTER INSERT ON source_context_events BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (
            NEW.session_id, NULL, 'source_context', NEW.id,
            COALESCE(NEW.meeting_title, '') || ' ' ||
            COALESCE(NEW.window_title, '') || ' ' ||
            CAST(NEW.participant_names_json AS TEXT) || ' ' ||
            COALESCE(NEW.active_speaker_name, '')
          );
        END;
        CREATE TRIGGER history_search_source_context_update
        AFTER UPDATE ON source_context_events BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'source_context' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) VALUES (
            NEW.session_id, NULL, 'source_context', NEW.id,
            COALESCE(NEW.meeting_title, '') || ' ' ||
            COALESCE(NEW.window_title, '') || ' ' ||
            CAST(NEW.participant_names_json AS TEXT) || ' ' ||
            COALESCE(NEW.active_speaker_name, '')
          );
        END;
        CREATE TRIGGER history_search_source_context_delete
        AFTER DELETE ON source_context_events BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'source_context' AND source_id = OLD.id;
        END;

        CREATE TRIGGER history_search_event_insert
        AFTER INSERT ON events BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NULL, NULL, 'event', NEW.id, NEW.title || ' ' || NEW.notes
            WHERE NEW.retired_at IS NULL;
        END;
        CREATE TRIGGER history_search_event_update
        AFTER UPDATE ON events BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'event' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NULL, NULL, 'event', NEW.id, NEW.title || ' ' || NEW.notes
            WHERE NEW.retired_at IS NULL;
        END;
        CREATE TRIGGER history_search_event_delete
        AFTER DELETE ON events BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'event' AND source_id = OLD.id;
        END;

        CREATE TRIGGER history_search_event_text_insert
        AFTER INSERT ON event_text_documents BEGIN
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NULL, NULL, 'event_text', NEW.id,
            CAST(NEW.result_json AS TEXT) WHERE NEW.state = 'current';
        END;
        CREATE TRIGGER history_search_event_text_update
        AFTER UPDATE ON event_text_documents BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'event_text' AND source_id = OLD.id;
          INSERT INTO history_search_fts(
            session_id, person_id, source_kind, source_id, content
          ) SELECT NULL, NULL, 'event_text', NEW.id,
            CAST(NEW.result_json AS TEXT) WHERE NEW.state = 'current';
        END;
        CREATE TRIGGER history_search_event_text_delete
        AFTER DELETE ON event_text_documents BEGIN
          DELETE FROM history_search_fts
            WHERE source_kind = 'event_text' AND source_id = OLD.id;
        END;
        """)
    guard installedRevision != revision else { return }
    try database.execute(
      sql: """
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        )
        SELECT session_id, NULL, 'session_metadata', session_id,
          title || ' ' || COALESCE(source_display_name, '') || ' ' ||
          COALESCE(source_identifier, '') || ' ' || COALESCE(source_bundle_id, '')
        FROM session_metadata;
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT session_id, NULL, 'transcript', id, content
          FROM transcript_revisions;
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT session_id, NULL, 'derived_text', id, output_text
          FROM derived_text_revisions WHERE state = 'current';
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT session_id, NULL, 'local_text', id, CAST(result_json AS TEXT)
          FROM local_text_documents WHERE state = 'current';
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT session_id, NULL, 'source_asset', id, original_filename
          FROM session_source_assets;
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT NULL, id, 'person', id,
          CASE WHEN trim(COALESCE(display_name, '')) = ''
            THEN '待命名 未知人物 ' ELSE '' END ||
          COALESCE(display_name, '') || ' ' || CAST(aliases_json AS TEXT)
          FROM persons WHERE retired_at IS NULL;
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT session_id, NULL, 'source_context', id,
          COALESCE(meeting_title, '') || ' ' ||
          COALESCE(window_title, '') || ' ' ||
          CAST(participant_names_json AS TEXT) || ' ' ||
          COALESCE(active_speaker_name, '')
          FROM source_context_events;
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT NULL, NULL, 'event', id, title || ' ' || notes
          FROM events WHERE retired_at IS NULL;
        INSERT INTO history_search_fts(
          session_id, person_id, source_kind, source_id, content
        ) SELECT NULL, NULL, 'event_text', id, CAST(result_json AS TEXT)
          FROM event_text_documents WHERE state = 'current';
        INSERT INTO bestasr_derived_index_metadata(key, value)
          VALUES ('history-search', ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """, arguments: [revision])
  }

  public static let foundationSQL = """
    PRAGMA user_version = 1;
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      input_mode TEXT NOT NULL,
      state TEXT NOT NULL,
      source_audio_retention TEXT NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE TABLE tracks (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      role TEXT NOT NULL,
      asset_reference TEXT NOT NULL CHECK (
        asset_reference NOT LIKE '/%' AND
        asset_reference NOT LIKE '%..%' AND
        asset_reference NOT LIKE '%://%'
      ),
      sample_rate_hz INTEGER NOT NULL CHECK (sample_rate_hz > 0),
      channel_count INTEGER NOT NULL CHECK (channel_count > 0)
    );
    CREATE TABLE audio_chunks (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      sequence INTEGER NOT NULL CHECK (sequence >= 0),
      monotonic_start_ns INTEGER NOT NULL CHECK (monotonic_start_ns >= 0),
      frame_count INTEGER NOT NULL CHECK (frame_count > 0),
      digest TEXT NOT NULL CHECK (length(digest) = 64),
      asset_reference TEXT NOT NULL CHECK (
        asset_reference NOT LIKE '/%' AND
        asset_reference NOT LIKE '%..%' AND
        asset_reference NOT LIKE '%://%'
      ),
      UNIQUE (track_id, sequence)
    );
    CREATE TABLE timeline_events (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      kind TEXT NOT NULL,
      monotonic_ns INTEGER NOT NULL CHECK (monotonic_ns >= 0),
      duration_ns INTEGER
    );
    CREATE TABLE transcript_revisions (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      parent_id TEXT REFERENCES transcript_revisions(id) ON DELETE RESTRICT,
      kind TEXT NOT NULL,
      content TEXT NOT NULL,
      model_artifact_id TEXT,
      config_hash TEXT,
      created_at REAL NOT NULL
    );
    CREATE TABLE durable_jobs (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      kind TEXT NOT NULL,
      state TEXT NOT NULL,
      input_revision INTEGER NOT NULL CHECK (input_revision > 0),
      model_artifact_id TEXT,
      config_hash TEXT NOT NULL CHECK (length(config_hash) = 64),
      retry_count INTEGER NOT NULL CHECK (retry_count >= 0),
      error_category TEXT NOT NULL,
      lease_owner TEXT,
      lease_expires_at REAL,
      UNIQUE (kind, input_revision, model_artifact_id, config_hash)
    );
    CREATE TABLE model_artifacts (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      registry_key TEXT NOT NULL,
      version TEXT NOT NULL,
      capability TEXT NOT NULL,
      digest TEXT NOT NULL CHECK (length(digest) = 64),
      directory_reference TEXT NOT NULL CHECK (
        directory_reference NOT LIKE '/%' AND
        directory_reference NOT LIKE '%..%' AND
        directory_reference NOT LIKE '%://%'
      ),
      license_identifier TEXT NOT NULL,
      state TEXT NOT NULL,
      UNIQUE (registry_key, version)
    );
    CREATE TABLE session_speakers (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      stable_ordinal INTEGER NOT NULL CHECK (stable_ordinal > 0),
      UNIQUE (session_id, stable_ordinal)
    );
    CREATE TABLE persons (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      display_name TEXT,
      aliases_json TEXT NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    """

  public static let syncIdentitySQL = """
    CREATE TABLE speaker_occurrences (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      session_speaker_id TEXT NOT NULL REFERENCES session_speakers(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      monotonic_start_ns INTEGER NOT NULL CHECK (monotonic_start_ns >= 0),
      monotonic_end_ns INTEGER NOT NULL CHECK (monotonic_end_ns >= monotonic_start_ns),
      overlaps_another_speaker INTEGER NOT NULL CHECK (overlaps_another_speaker IN (0, 1)),
      association_status TEXT NOT NULL,
      person_id TEXT REFERENCES persons(id) ON DELETE RESTRICT,
      confidence REAL CHECK (confidence >= 0 AND confidence <= 1),
      evidence_revision INTEGER NOT NULL CHECK (evidence_revision > 0)
    );
    CREATE TABLE speaker_occurrence_tracks (
      occurrence_id TEXT NOT NULL REFERENCES speaker_occurrences(id) ON DELETE CASCADE,
      track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE RESTRICT,
      PRIMARY KEY (occurrence_id, track_id)
    );
    CREATE TABLE person_corrections (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      occurred_at REAL NOT NULL,
      actor TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      reverses_operation_id TEXT REFERENCES person_corrections(id) ON DELETE RESTRICT
    );
    CREATE TABLE change_log (
      id TEXT PRIMARY KEY NOT NULL,
      entity_kind TEXT NOT NULL,
      entity_stable_id TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      occurred_at REAL NOT NULL,
      origin_device_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
      person_correction_id TEXT REFERENCES person_corrections(id) ON DELETE RESTRICT
    );
    CREATE TABLE tombstones (
      id TEXT PRIMARY KEY NOT NULL,
      entity_kind TEXT NOT NULL,
      entity_stable_id TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      deleted_at REAL NOT NULL,
      deletion_scope TEXT NOT NULL,
      change_id TEXT NOT NULL REFERENCES change_log(id) ON DELETE RESTRICT
    );
    CREATE INDEX speaker_occurrences_session_index
      ON speaker_occurrences(session_id, monotonic_start_ns);
    CREATE INDEX speaker_occurrences_person_index
      ON speaker_occurrences(person_id);
    CREATE INDEX change_log_revision_index
      ON change_log(revision, id);
    PRAGMA user_version = 2;
    """

  public static let dictationAlphaSQL = """
    CREATE TABLE dictation_snapshots (
      session_id TEXT PRIMARY KEY NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      control_revision INTEGER NOT NULL CHECK (control_revision > 0),
      phase TEXT NOT NULL,
      snapshot_json BLOB NOT NULL,
      is_ephemeral INTEGER NOT NULL CHECK (is_ephemeral IN (0, 1)),
      updated_at REAL NOT NULL
    );
    CREATE TABLE insertion_outcomes (
      session_id TEXT PRIMARY KEY NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      idempotency_key TEXT NOT NULL UNIQUE,
      state TEXT NOT NULL CHECK (state IN ('reserved', 'completed')),
      result_json BLOB,
      updated_at REAL NOT NULL
    );
    CREATE TABLE derived_text_revisions (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      source_transcript_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE RESTRICT,
      source_revision INTEGER NOT NULL CHECK (source_revision > 0),
      output_text TEXT NOT NULL,
      model_artifact_id TEXT,
      config_hash TEXT NOT NULL CHECK (length(config_hash) = 64),
      state TEXT NOT NULL CHECK (state IN ('current', 'stale')),
      created_at REAL NOT NULL
    );
    CREATE TABLE dictionary_entries (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      canonical_form TEXT NOT NULL,
      spoken_forms_json TEXT NOT NULL,
      enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      tombstoned_at REAL
    );
    CREATE TABLE dictation_job_sessions (
      job_id TEXT PRIMARY KEY NOT NULL REFERENCES durable_jobs(id) ON DELETE RESTRICT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT
    );
    CREATE INDEX dictation_snapshots_phase_index
      ON dictation_snapshots(phase, updated_at);
    CREATE INDEX derived_text_session_index
      ON derived_text_revisions(session_id, source_revision, state);
    CREATE INDEX dictionary_enabled_index
      ON dictionary_entries(enabled, tombstoned_at, canonical_form);
    CREATE INDEX dictation_job_session_index
      ON dictation_job_sessions(session_id, job_id);
    PRAGMA user_version = 3;
    """

  public static let transcriptProvenanceSQL = """
    ALTER TABLE transcript_revisions
      ADD COLUMN language_hints_json BLOB NOT NULL DEFAULT X'5B5D';
    CREATE TABLE transcript_segments (
      transcript_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE CASCADE,
      segment_id TEXT NOT NULL,
      ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
      monotonic_start_ns INTEGER NOT NULL CHECK (monotonic_start_ns >= 0),
      monotonic_end_ns INTEGER NOT NULL CHECK (monotonic_end_ns > monotonic_start_ns),
      text TEXT NOT NULL,
      confidence REAL CHECK (confidence >= 0 AND confidence <= 1),
      PRIMARY KEY (transcript_id, segment_id),
      UNIQUE (transcript_id, ordinal)
    );
    CREATE TABLE transcript_audio_ranges (
      transcript_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE CASCADE,
      ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
      source_id TEXT NOT NULL,
      track_id TEXT NOT NULL,
      asset_reference TEXT NOT NULL CHECK (
        asset_reference NOT LIKE '/%' AND
        asset_reference NOT LIKE '%..%' AND
        asset_reference NOT LIKE '%://%'
      ),
      digest TEXT NOT NULL CHECK (length(digest) = 64),
      monotonic_start_ns INTEGER NOT NULL CHECK (monotonic_start_ns >= 0),
      monotonic_end_ns INTEGER NOT NULL CHECK (monotonic_end_ns > monotonic_start_ns),
      sample_rate_hz INTEGER NOT NULL CHECK (sample_rate_hz > 0),
      channel_count INTEGER NOT NULL CHECK (channel_count > 0),
      PRIMARY KEY (transcript_id, ordinal)
    );
    CREATE INDEX transcript_segments_timeline_index
      ON transcript_segments(transcript_id, monotonic_start_ns, ordinal);
    CREATE INDEX transcript_audio_ranges_timeline_index
      ON transcript_audio_ranges(transcript_id, monotonic_start_ns, ordinal);
    PRAGMA user_version = 4;
    """

  public static let dictationHistorySQL = """
    ALTER TABLE dictation_snapshots ADD COLUMN recovered_at REAL;
    CREATE INDEX dictation_snapshots_history_index
      ON dictation_snapshots(updated_at DESC, session_id);
    PRAGMA user_version = 5;
    """

  /// Rebuilds the durable-job tables because the original global uniqueness
  /// constraint omitted session identity and incorrectly collided whenever two
  /// sessions used the same job kind, input revision, model, and config.
  public static let speakerPipelineSQL = """
    CREATE TABLE durable_jobs_v6 (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      kind TEXT NOT NULL,
      state TEXT NOT NULL,
      input_revision INTEGER NOT NULL CHECK (input_revision > 0),
      model_artifact_id TEXT,
      config_hash TEXT NOT NULL CHECK (length(config_hash) = 64),
      retry_count INTEGER NOT NULL CHECK (retry_count >= 0),
      error_category TEXT NOT NULL,
      lease_owner TEXT,
      lease_expires_at REAL
    );
    INSERT INTO durable_jobs_v6 (
      id, revision, kind, state, input_revision, model_artifact_id,
      config_hash, retry_count, error_category, lease_owner, lease_expires_at
    ) SELECT
      id, revision, kind, state, input_revision, model_artifact_id,
      config_hash, retry_count, error_category, lease_owner, lease_expires_at
    FROM durable_jobs;

    CREATE TABLE dictation_job_sessions_v6 (
      job_id TEXT PRIMARY KEY NOT NULL REFERENCES durable_jobs_v6(id) ON DELETE RESTRICT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      UNIQUE (session_id, job_id)
    );
    INSERT INTO dictation_job_sessions_v6 (job_id, session_id)
      SELECT job_id, session_id FROM dictation_job_sessions;
    DROP TABLE dictation_job_sessions;
    DROP TABLE durable_jobs;

    CREATE TABLE durable_jobs (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      kind TEXT NOT NULL,
      state TEXT NOT NULL,
      input_revision INTEGER NOT NULL CHECK (input_revision > 0),
      model_artifact_id TEXT,
      config_hash TEXT NOT NULL CHECK (length(config_hash) = 64),
      retry_count INTEGER NOT NULL CHECK (retry_count >= 0),
      error_category TEXT NOT NULL,
      lease_owner TEXT,
      lease_expires_at REAL
    );
    INSERT INTO durable_jobs (
      id, revision, kind, state, input_revision, model_artifact_id,
      config_hash, retry_count, error_category, lease_owner, lease_expires_at
    ) SELECT
      id, revision, kind, state, input_revision, model_artifact_id,
      config_hash, retry_count, error_category, lease_owner, lease_expires_at
    FROM durable_jobs_v6;

    CREATE TABLE dictation_job_sessions (
      job_id TEXT PRIMARY KEY NOT NULL REFERENCES durable_jobs(id) ON DELETE RESTRICT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      UNIQUE (session_id, job_id)
    );
    INSERT INTO dictation_job_sessions (job_id, session_id)
      SELECT job_id, session_id FROM dictation_job_sessions_v6;
    DROP TABLE dictation_job_sessions_v6;
    DROP TABLE durable_jobs_v6;
    CREATE INDEX dictation_job_session_index
      ON dictation_job_sessions(session_id, job_id);
    CREATE INDEX durable_jobs_claim_index
      ON durable_jobs(kind, state, lease_expires_at, revision);

    CREATE TABLE speaker_job_inputs (
      job_id TEXT PRIMARY KEY NOT NULL REFERENCES durable_jobs(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      audio_ranges_json BLOB NOT NULL,
      model_artifact_key TEXT NOT NULL,
      embedding_space_id TEXT NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE INDEX speaker_job_inputs_session_index
      ON speaker_job_inputs(session_id, job_id);

    CREATE TABLE session_speaker_embeddings (
      session_speaker_id TEXT NOT NULL REFERENCES session_speakers(id) ON DELETE CASCADE,
      revision INTEGER NOT NULL CHECK (revision > 0),
      embedding_space_id TEXT NOT NULL,
      vector_json BLOB NOT NULL,
      speech_duration_ns INTEGER NOT NULL CHECK (speech_duration_ns > 0),
      signal_quality REAL NOT NULL CHECK (signal_quality >= 0 AND signal_quality <= 1),
      model_artifact_key TEXT NOT NULL,
      created_at REAL NOT NULL,
      PRIMARY KEY (session_speaker_id, revision, embedding_space_id)
    );

    CREATE TABLE person_embeddings (
      id TEXT PRIMARY KEY NOT NULL,
      person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      embedding_space_id TEXT NOT NULL,
      vector_json BLOB NOT NULL,
      speech_duration_ns INTEGER NOT NULL CHECK (speech_duration_ns > 0),
      signal_quality REAL NOT NULL CHECK (signal_quality >= 0 AND signal_quality <= 1),
      source_occurrence_id TEXT REFERENCES speaker_occurrences(id) ON DELETE SET NULL,
      created_at REAL NOT NULL,
      retired_at REAL
    );
    CREATE INDEX person_embeddings_match_index
      ON person_embeddings(embedding_space_id, retired_at, person_id);
    PRAGMA user_version = 6;
    """

  public static let sourceAssetsSQL = """
    CREATE TABLE session_source_assets (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      revision INTEGER NOT NULL CHECK (revision > 0),
      kind TEXT NOT NULL,
      original_filename TEXT NOT NULL,
      media_type TEXT NOT NULL,
      asset_reference TEXT NOT NULL CHECK (
        asset_reference NOT LIKE '/%' AND
        asset_reference NOT LIKE '%..%' AND
        asset_reference NOT LIKE '%://%'
      ),
      digest TEXT NOT NULL CHECK (length(digest) = 64),
      size_bytes INTEGER NOT NULL CHECK (size_bytes > 0),
      created_at REAL NOT NULL,
      UNIQUE (session_id, revision, kind)
    );
    CREATE INDEX session_source_assets_session_index
      ON session_source_assets(session_id, revision, kind);
    PRAGMA user_version = 7;
    """

  public static let localTextDocumentsSQL = """
    CREATE TABLE local_text_documents (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      source_transcript_id TEXT NOT NULL REFERENCES transcript_revisions(id) ON DELETE RESTRICT,
      source_revision INTEGER NOT NULL CHECK (source_revision > 0),
      task_id TEXT NOT NULL,
      model_artifact_id TEXT NOT NULL,
      config_hash TEXT NOT NULL CHECK (length(config_hash) = 64),
      result_json BLOB NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('current', 'stale')),
      created_at REAL NOT NULL
    );
    CREATE INDEX local_text_documents_session_index
      ON local_text_documents(session_id, task_id, state, created_at DESC);
    PRAGMA user_version = 8;
    """

  public static let personEditingSQL = """
    ALTER TABLE persons ADD COLUMN retired_at REAL;
    ALTER TABLE persons ADD COLUMN merged_into_person_id TEXT REFERENCES persons(id) ON DELETE RESTRICT;
    CREATE TABLE person_edit_operations (
      id TEXT PRIMARY KEY NOT NULL,
      correction_id TEXT NOT NULL REFERENCES person_corrections(id) ON DELETE RESTRICT,
      kind TEXT NOT NULL,
      inverse_json BLOB NOT NULL,
      occurred_at REAL NOT NULL,
      reversed_at REAL
    );
    CREATE INDEX person_edit_operations_undo_index
      ON person_edit_operations(reversed_at, occurred_at DESC, id DESC);
    PRAGMA user_version = 9;
    """

  public static let rejectedPersonMatchesSQL = """
    CREATE TABLE rejected_person_matches (
      id TEXT PRIMARY KEY NOT NULL,
      session_speaker_id TEXT NOT NULL
        REFERENCES session_speakers(id) ON DELETE CASCADE,
      candidate_person_id TEXT NOT NULL
        REFERENCES persons(id) ON DELETE RESTRICT,
      embedding_space_id TEXT NOT NULL,
      vector_json BLOB NOT NULL,
      created_at REAL NOT NULL,
      UNIQUE (session_speaker_id, candidate_person_id, embedding_space_id)
    );
    CREATE INDEX rejected_person_matches_lookup_index
      ON rejected_person_matches(candidate_person_id, embedding_space_id);
    PRAGMA user_version = 10;
    """

  public static let sessionMetadataSQL = """
    CREATE TABLE session_metadata (
      session_id TEXT PRIMARY KEY NOT NULL
        REFERENCES sessions(id) ON DELETE CASCADE,
      revision INTEGER NOT NULL CHECK (revision > 0),
      title TEXT NOT NULL,
      title_is_user_edited INTEGER NOT NULL
        CHECK (title_is_user_edited IN (0, 1)),
      source_kind TEXT NOT NULL,
      source_identifier TEXT,
      source_display_name TEXT,
      source_bundle_id TEXT,
      recording_format TEXT NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    INSERT INTO session_metadata (
      session_id, revision, title, title_is_user_edited, source_kind,
      source_identifier, source_display_name, source_bundle_id,
      recording_format, created_at, updated_at
    )
    SELECT id, 1,
      CASE input_mode
        WHEN 'dictation' THEN '口述'
        WHEN 'roomMicrophone' THEN '线下录音'
        WHEN 'systemAudio' THEN '电脑内录'
        WHEN 'importedMedia' THEN '导入文件'
        ELSE '本地录音'
      END,
      0, input_mode, NULL, NULL, NULL, 'float32-pcm-journal',
      created_at, updated_at
    FROM sessions;
    CREATE INDEX session_metadata_source_index
      ON session_metadata(source_kind, source_bundle_id, updated_at DESC);
    PRAGMA user_version = 11;
    """

  public static let trackDeviceMetadataSQL = """
    ALTER TABLE tracks ADD COLUMN device_uid TEXT;
    PRAGMA user_version = 12;
    """

  public static let sourceContextSQL = """
    CREATE TABLE source_context_events (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      revision INTEGER NOT NULL CHECK (revision > 0),
      adapter_id TEXT NOT NULL,
      source_bundle_id TEXT,
      meeting_title TEXT,
      window_title TEXT,
      participant_names_json BLOB NOT NULL,
      active_speaker_name TEXT,
      monotonic_ns INTEGER NOT NULL CHECK (monotonic_ns >= 0),
      reliability TEXT NOT NULL CHECK (reliability IN ('reliable', 'advisory')),
      UNIQUE (session_id, adapter_id, monotonic_ns)
    );
    CREATE INDEX source_context_session_timeline_index
      ON source_context_events(session_id, monotonic_ns, revision);
    PRAGMA user_version = 13;
    """

  public static let speakerNameEvidenceSQL = """
    CREATE TABLE speaker_name_evidence (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      session_speaker_id TEXT NOT NULL
        REFERENCES session_speakers(id) ON DELETE CASCADE,
      person_id TEXT REFERENCES persons(id) ON DELETE SET NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      display_name TEXT NOT NULL,
      source_kind TEXT NOT NULL
        CHECK (source_kind = 'platformActiveSpeaker'),
      source_context_ids_json BLOB NOT NULL,
      occurrence_ids_json BLOB NOT NULL,
      aligned_speech_ns INTEGER NOT NULL CHECK (aligned_speech_ns > 0),
      reliability TEXT NOT NULL CHECK (reliability = 'reliable'),
      created_at REAL NOT NULL,
      UNIQUE (session_speaker_id, revision, source_kind)
    );
    CREATE INDEX speaker_name_evidence_person_index
      ON speaker_name_evidence(person_id, session_id);
    PRAGMA user_version = 14;
    """

  /// Repairs the foreign-key target that SQLite retained as
  /// `durable_jobs_v6` when the v6 parent and child tables were renamed.
  /// Rebuilding only the relationship table preserves every durable job and
  /// its session assignment while making existing installations writable.
  public static let durableJobForeignKeyRepairSQL = """
    CREATE TABLE dictation_job_sessions_v15 (
      job_id TEXT PRIMARY KEY NOT NULL REFERENCES durable_jobs(id) ON DELETE RESTRICT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      UNIQUE (session_id, job_id)
    );
    INSERT INTO dictation_job_sessions_v15 (job_id, session_id)
      SELECT job_id, session_id FROM dictation_job_sessions;
    DROP TABLE dictation_job_sessions;
    ALTER TABLE dictation_job_sessions_v15 RENAME TO dictation_job_sessions;
    CREATE INDEX dictation_job_session_index
      ON dictation_job_sessions(session_id, job_id);
    PRAGMA user_version = 15;
    """

  /// How long a retained original plays for.
  ///
  /// A session whose audio arrived as a file has no chunks in the audio index
  /// — that index describes what capture journaled — so its length has to be
  /// recorded with the file itself, or history shows a dictation that lasted
  /// no time at all.
  public static let retainedSourceDurationSQL = """
    ALTER TABLE session_source_assets ADD COLUMN duration_ns INTEGER
      CHECK (duration_ns IS NULL OR duration_ns > 0);
    PRAGMA user_version = 17;
    """

  public static let eventMemorySQL = """
    CREATE TABLE events (
      id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL CHECK (revision > 0),
      title TEXT NOT NULL CHECK (length(trim(title)) > 0),
      notes TEXT NOT NULL DEFAULT '',
      start_at REAL NOT NULL,
      end_at REAL NOT NULL CHECK (end_at >= start_at),
      title_is_user_edited INTEGER NOT NULL
        CHECK (title_is_user_edited IN (0, 1)),
      confirmation_state TEXT NOT NULL
        CHECK (confirmation_state IN ('automatic', 'userConfirmed')),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      retired_at REAL,
      merged_into_event_id TEXT REFERENCES events(id) ON DELETE RESTRICT
    );
    CREATE TABLE event_sessions (
      event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
      source TEXT NOT NULL
        CHECK (source IN ('automatic', 'candidateAccepted', 'manual')),
      confidence REAL NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
      evidence_json BLOB NOT NULL,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      PRIMARY KEY (event_id, session_id)
    );
    CREATE TABLE event_link_rejections (
      event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      reason TEXT NOT NULL
        CHECK (reason IN ('manualMove', 'manualRemoval', 'manualSplit')),
      created_at REAL NOT NULL,
      PRIMARY KEY (event_id, session_id)
    );
    CREATE TABLE event_people (
      event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
      person_id TEXT NOT NULL REFERENCES persons(id) ON DELETE RESTRICT,
      occurrence_count INTEGER NOT NULL CHECK (occurrence_count > 0),
      speech_duration_ns INTEGER NOT NULL CHECK (speech_duration_ns >= 0),
      PRIMARY KEY (event_id, person_id)
    );
    CREATE TABLE event_candidates (
      id TEXT PRIMARY KEY NOT NULL,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      candidate_event_id TEXT REFERENCES events(id) ON DELETE CASCADE,
      proposed_title TEXT NOT NULL CHECK (length(trim(proposed_title)) > 0),
      evidence_json BLOB NOT NULL,
      state TEXT NOT NULL
        CHECK (state IN ('accepted', 'dismissed', 'pending', 'superseded')),
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE TABLE event_text_documents (
      id TEXT PRIMARY KEY NOT NULL,
      event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
      event_revision INTEGER NOT NULL CHECK (event_revision > 0),
      task_id TEXT NOT NULL,
      model_artifact_id TEXT NOT NULL,
      config_hash TEXT NOT NULL CHECK (length(config_hash) = 64),
      source_references_json BLOB NOT NULL,
      result_json BLOB NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('current', 'stale')),
      created_at REAL NOT NULL
    );
    CREATE TABLE event_edit_operations (
      id TEXT PRIMARY KEY NOT NULL,
      kind TEXT NOT NULL,
      inverse_json BLOB NOT NULL,
      occurred_at REAL NOT NULL,
      reversed_at REAL
    );
    CREATE INDEX events_timeline_index
      ON events(retired_at, start_at DESC, updated_at DESC);
    CREATE INDEX event_sessions_event_index
      ON event_sessions(event_id, updated_at DESC);
    CREATE INDEX event_link_rejections_session_index
      ON event_link_rejections(session_id, event_id);
    CREATE INDEX event_people_person_index
      ON event_people(person_id, event_id);
    CREATE INDEX event_candidates_pending_index
      ON event_candidates(state, updated_at DESC, session_id);
    CREATE INDEX event_text_documents_event_index
      ON event_text_documents(event_id, state, task_id, created_at DESC);
    CREATE INDEX event_edit_operations_undo_index
      ON event_edit_operations(reversed_at, occurred_at DESC, id DESC);
    PRAGMA user_version = 16;
    """
}
