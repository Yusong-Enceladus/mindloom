import CryptoKit
import Foundation
import GRDB

public enum PersistenceProbeError: Error, Equatable, Sendable {
  case databaseAlreadyExists
  case injectedInterruption
  case invalidJournalMode
  case missingBackup
}

public enum PersistenceMigrationFault: Sendable {
  case interruptAfterFirstCurrentTable
  case none
}

public enum PersistenceProbeStatus: String, Codable, Sendable {
  case pass
  case fail
}

public struct PersistenceInspection: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let journalMode: String
  public let foreignKeysEnabled: Bool
  public let appliedMigrations: [String]
  public let tableNames: [String]
  public let sessionCount: Int
}

public struct PersistenceMigrationAttempt: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let status: PersistenceProbeStatus
  public let failureCategory: String?
  public let sourceFilePreserved: Bool
  public let backupMatchesPreMigration: Bool
  public let backupFileName: String
  public let recoveryInstructions: String
  public let inspection: PersistenceInspection
}

public enum PersistenceSchema {
  public static let nMinusOneMigrationID = "v1-foundation"
  public static let currentMigrationID = "v2-sync-identity"

  public static let v1SQL = """
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

  public static let v2FirstTableSQL = """
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
    """

  public static let v2RemainingSQL = """
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
}

public enum PersistenceSQLExecutor {
  public static func execute(databaseURL: URL, sql: String) throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let queue = try DatabaseQueue(
      path: databaseURL.path,
      configuration: configuration
    )
    try queue.write { db in
      try db.execute(sql: sql)
    }
    try queue.close()
  }
}

public struct PersistenceMigrationProbe {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func createNMinusOneFixture(at databaseURL: URL) throws {
    guard !fileManager.fileExists(atPath: databaseURL.path) else {
      throw PersistenceProbeError.databaseAlreadyExists
    }
    try fileManager.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let pool = try makePool(at: databaseURL)
    let migrator = makeMigrator(fault: .none)
    try migrator.migrate(pool, upTo: PersistenceSchema.nMinusOneMigrationID)
    try pool.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention, created_at, updated_at
          ) VALUES (?, 1, 'dictation', 'completed', 'retainedUntilExplicitDeletion', 1, 1)
          """,
        arguments: ["00000000-0000-4000-8000-000000000001"]
      )
      try db.execute(
        sql: """
          INSERT INTO persons (
            id, revision, display_name, aliases_json, created_at, updated_at
          ) VALUES (?, 1, NULL, '[]', 1, 1)
          """,
        arguments: ["00000000-0000-4000-8000-000000000042"]
      )
    }
    try checkpointAndClose(pool)
  }

  public func migrateToCurrent(
    at databaseURL: URL,
    fault: PersistenceMigrationFault = .none
  ) throws -> PersistenceMigrationAttempt {
    let backupURL = databaseURL.appendingPathExtension("pre-v2.backup")
    let backupDigestURL = backupURL.appendingPathExtension("sha256")
    let sourceExistsBefore = fileManager.fileExists(atPath: databaseURL.path)
    let preMigrationDigest = try Self.sha256(of: databaseURL)

    if !fileManager.fileExists(atPath: backupURL.path) {
      try fileManager.copyItem(at: databaseURL, to: backupURL)
      try Data((preMigrationDigest + "\n").utf8)
        .write(to: backupDigestURL, options: .atomic)
    }
    let recordedBackupDigest = try String(contentsOf: backupDigestURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let backupMatches = try Self.sha256(of: backupURL) == recordedBackupDigest
    var status = PersistenceProbeStatus.pass
    var failureCategory: String?

    let pool = try makePool(at: databaseURL)
    do {
      let migrator = makeMigrator(fault: fault)
      try migrator.migrate(pool)
    } catch {
      status = .fail
      failureCategory = String(describing: error)
    }
    try checkpointAndClose(pool)

    let inspection = try inspect(databaseURL)
    let sourcePreserved =
      sourceExistsBefore
      && fileManager.fileExists(atPath: databaseURL.path)
      && inspection.sessionCount == 1
    let recoveryInstructions: String
    if status == .fail {
      recoveryInstructions =
        "Keep \(databaseURL.lastPathComponent) unchanged; restore "
        + "\(backupURL.lastPathComponent) to a new file, verify integrity, then retry migration."
    } else {
      recoveryInstructions =
        "Retain \(backupURL.lastPathComponent) until the migrated database passes integrity checks."
    }

    return PersistenceMigrationAttempt(
      schemaVersion: 1,
      status: status,
      failureCategory: failureCategory,
      sourceFilePreserved: sourcePreserved,
      backupMatchesPreMigration: backupMatches,
      backupFileName: backupURL.lastPathComponent,
      recoveryInstructions: recoveryInstructions,
      inspection: inspection
    )
  }

  public func inspect(_ databaseURL: URL) throws -> PersistenceInspection {
    let pool = try makePool(at: databaseURL)
    let migrator = makeMigrator(fault: .none)
    let result = try pool.read { db in
      PersistenceInspection(
        schemaVersion: try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
        journalMode: (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown")
          .lowercased(),
        foreignKeysEnabled: (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) == 1,
        appliedMigrations: try migrator.appliedMigrations(db),
        tableNames: try String.fetchAll(
          db,
          sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        ),
        sessionCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
      )
    }
    try pool.close()
    return result
  }

  public func restoreBackup(_ backupURL: URL, to destinationURL: URL) throws {
    guard fileManager.fileExists(atPath: backupURL.path) else {
      throw PersistenceProbeError.missingBackup
    }
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw PersistenceProbeError.databaseAlreadyExists
    }
    try fileManager.copyItem(at: backupURL, to: destinationURL)
  }

  public static func sha256(of fileURL: URL) throws -> String {
    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func makePool(at databaseURL: URL) throws -> DatabasePool {
    var configuration = Configuration()
    configuration.label = "bestASR.persistence-probe"
    configuration.maximumReaderCount = 2
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      let mode = (try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL") ?? "").lowercased()
      guard mode == "wal" else {
        throw PersistenceProbeError.invalidJournalMode
      }
    }
    return try DatabasePool(path: databaseURL.path, configuration: configuration)
  }

  private func makeMigrator(fault: PersistenceMigrationFault) -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(PersistenceSchema.nMinusOneMigrationID) { db in
      try db.execute(sql: PersistenceSchema.v1SQL)
    }
    migrator.registerMigration(PersistenceSchema.currentMigrationID) { db in
      try db.execute(sql: PersistenceSchema.v2FirstTableSQL)
      if case .interruptAfterFirstCurrentTable = fault {
        throw PersistenceProbeError.injectedInterruption
      }
      try db.execute(sql: PersistenceSchema.v2RemainingSQL)
    }
    return migrator
  }

  private func checkpointAndClose(_ pool: DatabasePool) throws {
    _ = try pool.writeWithoutTransaction { db in
      try db.checkpoint(.truncate)
    }
    try pool.close()
  }
}

public struct PersistenceProbeScenario: Codable, Equatable, Sendable {
  public let name: String
  public let result: PersistenceProbeStatus
  public let attempt: PersistenceMigrationAttempt

  public init(
    name: String,
    result: PersistenceProbeStatus,
    attempt: PersistenceMigrationAttempt
  ) {
    self.name = name
    self.result = result
    self.attempt = attempt
  }
}

public struct PersistenceMigrationReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let runID: UUID
  public let status: PersistenceProbeStatus
  public let scenarios: [PersistenceProbeScenario]

  public init(runID: UUID, scenarios: [PersistenceProbeScenario]) {
    schemaVersion = 1
    kind = "persistence-migration-summary"
    self.runID = runID
    self.scenarios = scenarios
    status = scenarios.allSatisfy { $0.result == .pass } ? .pass : .fail
  }
}
