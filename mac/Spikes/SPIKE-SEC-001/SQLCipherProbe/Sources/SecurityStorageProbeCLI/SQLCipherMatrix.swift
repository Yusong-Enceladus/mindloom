import BestASRSecurityEnvelopeProbe
import Foundation

struct SQLCipherMatrix {
  let root: URL
  let key: Data
  let backupKey: Data
  let databaseURL: URL
  let backupURL: URL

  init(root: URL) {
    self.root = root
    key = EnvelopeCrypto.keyData(EnvelopeCrypto.makeMasterKey())
    backupKey = EnvelopeCrypto.keyData(EnvelopeCrypto.makeMasterKey())
    databaseURL = root.appendingPathComponent("store.sqlite")
    backupURL = root.appendingPathComponent("store-backup.sqlite")
  }

  func run() -> [ProbeScenarioDetail] {
    [
      runScenario("sqlcipher-encryption-at-rest", createEncryptedDatabase),
      runScenario("sqlcipher-correct-and-wrong-key", verifyKeys),
      runScenario("sqlcipher-online-backup-roundtrip", verifyBackup),
      runScenario("sqlcipher-migration-rollback", verifyMigration),
      runScenario("sqlcipher-corruption-detection", verifyCorruption),
      runScenario("sqlcipher-crash-recovery", verifyCrashRecovery),
    ]
  }

  private func createEncryptedDatabase() throws -> [String: String] {
    let database = try SQLCipherDatabase(url: databaseURL, key: key)
    let journalMode = try database.scalarText("PRAGMA journal_mode = WAL")
    try database.execute(
      """
      CREATE TABLE records (
        id INTEGER PRIMARY KEY,
        label TEXT NOT NULL,
        payload BLOB NOT NULL
      );
      PRAGMA user_version = 1;
      WITH RECURSIVE sequence(value) AS (
        SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 256
      )
      INSERT INTO records(label, payload)
      SELECT printf('probe_row_%04d', value), randomblob(2048) FROM sequence;
      INSERT INTO records(label, payload)
      VALUES ('probe_at_rest_marker_7f31', randomblob(2048));
      """
    )
    let cipherVersion = try database.scalarText("PRAGMA cipher_version")
    try require(try database.cipherIntegrityIsClean(), "initial-integrity")
    try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    try database.close()

    let bytes = try Data(contentsOf: databaseURL)
    try require(
      !bytes.starts(with: Data("SQLite format 3\0".utf8)),
      "plaintext-header"
    )
    try require(
      bytes.range(of: Data("probe_at_rest_marker_7f31".utf8)) == nil,
      "plaintext-marker"
    )
    return [
      "cipherVersion": cipherVersion,
      "databaseBytes": String(bytes.count),
      "journalMode": journalMode.lowercased(),
      "plaintextHeaderVisible": "false",
      "plaintextMarkerVisible": "false",
    ]
  }

  private func verifyKeys() throws -> [String: String] {
    let database = try SQLCipherDatabase(
      url: databaseURL,
      key: key,
      create: false
    )
    try require(
      try database.scalarInt("SELECT count(*) FROM records") == 257,
      "correct-key-row-count"
    )
    try database.close()

    var wrongKeyRejected = false
    do {
      let wrong = try SQLCipherDatabase(
        url: databaseURL,
        key: EnvelopeCrypto.keyData(EnvelopeCrypto.makeMasterKey()),
        create: false
      )
      try wrong.close()
    } catch {
      wrongKeyRejected = true
    }
    try require(wrongKeyRejected, "wrong-key-accepted")
    return [
      "correctKey": "pass",
      "wrongKeyRejected": "true",
    ]
  }

  private func verifyBackup() throws -> [String: String] {
    let source = try SQLCipherDatabase(
      url: databaseURL,
      key: key,
      create: false
    )
    let destination = try SQLCipherDatabase(url: backupURL, key: backupKey)
    try source.backup(to: destination)
    try require(
      try destination.scalarInt("SELECT count(*) FROM records") == 257,
      "backup-row-count"
    )
    try require(try destination.cipherIntegrityIsClean(), "backup-integrity")
    try source.close()
    try destination.close()

    let bytes = try Data(contentsOf: backupURL)
    try require(
      !bytes.starts(with: Data("SQLite format 3\0".utf8)),
      "backup-plaintext-header"
    )
    try require(
      bytes.range(of: Data("probe_at_rest_marker_7f31".utf8)) == nil,
      "backup-plaintext-marker"
    )
    return [
      "backupBytes": String(bytes.count),
      "byteMarkerVisible": "false",
      "roundTrip": "pass",
    ]
  }

  private func verifyMigration() throws -> [String: String] {
    let database = try SQLCipherDatabase(
      url: databaseURL,
      key: key,
      create: false
    )
    try database.execute(
      """
      BEGIN IMMEDIATE;
      ALTER TABLE records ADD COLUMN note TEXT;
      PRAGMA user_version = 2;
      INSERT INTO records(label, payload, note)
      VALUES ('rolled_back_probe', randomblob(32), 'rollback');
      ROLLBACK;
      """
    )
    try require(
      try database.scalarInt("PRAGMA user_version") == 1,
      "rollback-version"
    )
    try require(
      try database.scalarInt(
        "SELECT count(*) FROM pragma_table_info('records') WHERE name = 'note'"
      ) == 0,
      "rollback-column"
    )
    try require(
      try database.scalarInt(
        "SELECT count(*) FROM records WHERE label = 'rolled_back_probe'"
      ) == 0,
      "rollback-row"
    )

    try database.execute(
      """
      BEGIN IMMEDIATE;
      ALTER TABLE records ADD COLUMN note TEXT;
      PRAGMA user_version = 2;
      COMMIT;
      """
    )
    try require(
      try database.scalarInt("PRAGMA user_version") == 2,
      "committed-version"
    )
    try require(try database.cipherIntegrityIsClean(), "migration-integrity")
    try database.close()

    let backup = try SQLCipherDatabase(
      url: backupURL,
      key: backupKey,
      create: false
    )
    try require(
      try backup.scalarInt("PRAGMA user_version") == 1,
      "pre-migration-backup-version"
    )
    try backup.close()
    return [
      "committedVersion": "2",
      "interruptedVersion": "1",
      "preMigrationBackupVersion": "1",
    ]
  }

  private func verifyCorruption() throws -> [String: String] {
    let corruptURL = root.appendingPathComponent("store-corrupt.sqlite")
    try FileManager.default.copyItem(at: databaseURL, to: corruptURL)
    var bytes = try Data(contentsOf: corruptURL)
    let offset = min(4_193, bytes.count / 2)
    try require(offset > 32 && offset < bytes.count, "corruption-offset")
    bytes[offset] ^= 0x01
    try bytes.write(to: corruptURL, options: .atomic)

    var corruptionRejected = false
    do {
      let corrupt = try SQLCipherDatabase(
        url: corruptURL,
        key: key,
        create: false
      )
      corruptionRejected = try !corrupt.cipherIntegrityIsClean()
      try corrupt.close()
    } catch {
      corruptionRejected = true
    }
    try require(corruptionRejected, "corruption-not-detected")
    return [
      "corruptedByteOffset": String(offset),
      "integrityRejected": "true",
    ]
  }

  private func verifyCrashRecovery() throws -> [String: String] {
    guard let executableURL = Bundle.main.executableURL else {
      throw SQLCipherProbeError.crashWorkerFailed(-1)
    }
    let worker = Process()
    worker.executableURL = executableURL
    worker.arguments = ["--crash-worker"]
    var environment = ProcessInfo.processInfo.environment
    environment["BESTASR_SECURITY_PROBE_DATABASE"] = databaseURL.path
    environment["BESTASR_SECURITY_PROBE_KEY"] = key.base64EncodedString()
    worker.environment = environment
    worker.standardOutput = FileHandle.nullDevice
    worker.standardError = FileHandle.nullDevice
    try worker.run()
    worker.waitUntilExit()
    let exitCode = worker.terminationStatus
    try require(exitCode == 91, "crash-worker-setup")

    let recovered = try SQLCipherDatabase(
      url: databaseURL,
      key: key,
      create: false
    )
    try require(
      try recovered.scalarInt(
        "SELECT count(*) FROM records WHERE label = 'uncommitted_crash_probe'"
      ) == 0,
      "uncommitted-row-survived"
    )
    try require(
      try recovered.scalarInt(
        "SELECT count(*) FROM records WHERE label = 'probe_at_rest_marker_7f31'"
      ) == 1,
      "committed-row-missing"
    )
    try require(try recovered.cipherIntegrityIsClean(), "recovered-integrity")
    try recovered.close()
    return [
      "childExitCode": String(exitCode),
      "committedDataReadable": "true",
      "uncommittedDataPresent": "false",
    ]
  }
}

func runSQLCipherCrashWorker() -> Never {
  let environment = ProcessInfo.processInfo.environment
  guard let databasePath = environment["BESTASR_SECURITY_PROBE_DATABASE"],
    let keyString = environment["BESTASR_SECURITY_PROBE_KEY"],
    let key = Data(base64Encoded: keyString)
  else {
    exit(92)
  }
  do {
    let database = try SQLCipherDatabase(
      url: URL(fileURLWithPath: databasePath),
      key: key,
      create: false
    )
    try database.execute(
      """
      BEGIN IMMEDIATE;
      INSERT INTO records(label, payload, note)
      VALUES ('uncommitted_crash_probe', randomblob(32), 'uncommitted');
      """
    )
    exit(91)
  } catch {
    exit(92)
  }
}
