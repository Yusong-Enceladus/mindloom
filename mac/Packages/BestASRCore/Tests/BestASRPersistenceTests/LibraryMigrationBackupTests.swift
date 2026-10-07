import Darwin
import Foundation
import GRDB
import XCTest

@testable import BestASRPersistence

/// v12 phase B (ROOT R3-1): opening a library from an older schema first
/// clones it into `<library>/backups`, checks the clone and refuses to
/// migrate when that fails; the newest two backups are kept.
final class LibraryMigrationBackupTests: XCTestCase {
  private var library: URL!

  override func setUpWithError() throws {
    library = try persistenceTemporaryDirectory()
  }

  override func tearDownWithError() throws {
    if let library { try? FileManager.default.removeItem(at: library) }
  }

  private var databaseURL: URL { library.appendingPathComponent("history.sqlite") }
  private var backupsFolder: URL { library.appendingPathComponent("backups", isDirectory: true) }

  /// A synthetic v18 library (the version the daily app's library is at),
  /// with one session row and its WAL left in place.
  private func makeOldLibrary(sessionID: String = UUID().uuidString) throws {
    let pool = try DatabasePool(path: databaseURL.path)
    try BestASRPersistenceSchema.migrator().migrate(
      pool, upTo: BestASRPersistenceSchema.spokenModeMigrationID)
    try pool.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention, created_at, updated_at
          ) VALUES (?, 1, 'dictation', 'completed', 'retained', 1000, 1001)
          """,
        arguments: [sessionID])
    }
    try pool.close()
  }

  private func readOnly<T>(_ url: URL, _ read: (Database) throws -> T) throws -> T {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    defer { try? queue.close() }
    return try queue.read(read)
  }

  func testOpeningAnOlderLibraryClonesAndChecksItBeforeMigrating() throws {
    let sessionID = UUID().uuidString
    try makeOldLibrary(sessionID: sessionID)

    let store = try GRDBDictationStore(databaseURL: databaseURL)
    let record = try XCTUnwrap(store.migrationBackup)
    XCTAssertEqual(record.fromUserVersion, 18)

    let backups = LibraryMigrationBackup.backups(in: backupsFolder)
    XCTAssertEqual(backups, [record.folder])
    XCTAssertTrue(record.folder.lastPathComponent.hasPrefix("pre-migration-"))
    let clone = record.folder.appendingPathComponent("history.sqlite")
    XCTAssertTrue(LibraryMigrationBackup.verify(clone))
    // The clone is the library as it was: v18, with its row.
    let (version, count) = try readOnly(clone) { db in
      (
        try Int.fetchOne(db, sql: "PRAGMA user_version"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id = ?", arguments: [sessionID])
      )
    }
    XCTAssertEqual(version, 18)
    XCTAssertEqual(count, 1)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: record.folder.appendingPathComponent(LibraryMigrationBackup.manifestName).path))
    // The library itself is migrated.
    let current = try readOnly(databaseURL) { db in
      try Int.fetchOne(db, sql: "PRAGMA user_version")
    }
    XCTAssertEqual(current, BestASRPersistenceSchema.currentUserVersion)
  }

  /// Regression (review 10-5d R5): the backup before a migration takes the
  /// write lock with BEGIN IMMEDIATE; when another program held it, the
  /// busy error was turned into `cloneFailed`, which the open does not wait
  /// for, so the first open after the switch (it migrates) failed at once.
  /// Busy is thrown as it is, and the open waits and tries again.
  func testABusyBackupIsWaitedForNotFailed() async throws {
    try makeOldLibrary()
    var otherConfiguration = Configuration()
    otherConfiguration.allowsUnsafeTransactions = true
    let other = try DatabaseQueue(path: databaseURL.path, configuration: otherConfiguration)
    try await other.writeWithoutTransaction { db in
      // Its own write stays in the WAL, so that opening the library needs no
      // write lock before the backup does (GRDB writes to an empty WAL).
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
      try db.execute(sql: "CREATE TABLE other_program (x INTEGER)")
      try db.execute(sql: "BEGIN IMMEDIATE")
    }

    // The backup alone, with no wait for the lock: the error is busy.
    var immediate = Configuration()
    immediate.busyMode = .immediateError
    let pool = try DatabasePool(path: databaseURL.path, configuration: immediate)
    XCTAssertThrowsError(
      try LibraryMigrationBackup.backUp(
        pool: pool, databaseURL: databaseURL, migrator: BestASRPersistenceSchema.migrator(),
        into: backupsFolder)
    ) { error in
      XCTAssertTrue(LibraryOpenRetry.isBusy(error), "busy, not \(error)")
    }
    try pool.close()
    XCTAssertEqual(LibraryMigrationBackup.backups(in: backupsFolder), [], "no partial backup")

    // The open: each wait for the lock is shorter than the other program
    // holds it; the open tries again and migrates once it lets go.
    let released = expectation(description: "the other program lets go")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
      try? other.writeWithoutTransaction { db in try db.execute(sql: "COMMIT") }
      released.fulfill()
    }
    let started = Date()
    let store = try GRDBDictationStore.openWaitingWhileBusy(
      databaseURL: databaseURL,
      retry: LibraryOpenRetry(
        delays: [0.1, 0.2, 0.4, 0.8, 1.6], maximumSeconds: 10, busyTimeout: 0.1))
    let waited = Date().timeIntervalSince(started)
    await fulfillment(of: [released], timeout: 5)
    XCTAssertGreaterThanOrEqual(waited, 0.4, "the open waited for the other program")
    let record = try XCTUnwrap(store.migrationBackup)
    XCTAssertEqual(record.fromUserVersion, 18)
    XCTAssertEqual(LibraryMigrationBackup.backups(in: backupsFolder), [record.folder])
    await store.closeForQuit()
    try other.close()
  }

  func testNewAndCurrentLibrariesNeedNoBackup() throws {
    _ = try GRDBDictationStore(databaseURL: databaseURL)
    let again = try GRDBDictationStore(databaseURL: databaseURL)
    XCTAssertNil(again.migrationBackup)
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupsFolder.path))
  }

  func testAFailedBackupLeavesTheLibraryUnmigrated() throws {
    try makeOldLibrary()
    // `backups` is a file: the folder cannot be made.
    try Data("not a folder".utf8).write(to: backupsFolder)

    XCTAssertThrowsError(try GRDBDictationStore(databaseURL: databaseURL)) { error in
      XCTAssertEqual(error as? LibraryMigrationBackupError, .folderUnavailable)
    }
    let version = try readOnly(databaseURL) { db in
      try Int.fetchOne(db, sql: "PRAGMA user_version")
    }
    XCTAssertEqual(version, 18)
  }

  func testAnUnreadableBackupFolderRefusesTheMigration() throws {
    try makeOldLibrary()
    try FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
    chmod(backupsFolder.path, 0o500)
    defer { chmod(backupsFolder.path, 0o700) }

    XCTAssertThrowsError(try GRDBDictationStore(databaseURL: databaseURL)) { error in
      XCTAssertNotNil(error as? LibraryMigrationBackupError)
    }
    let version = try readOnly(databaseURL) { db in
      try Int.fetchOne(db, sql: "PRAGMA user_version")
    }
    XCTAssertEqual(version, 18)
  }

  func testOnlyTheNewestTwoBackupsAreKept() throws {
    try FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
    let older = ["pre-migration-20260101T000000Z", "pre-migration-20260201T000000Z"]
    for name in older {
      try FileManager.default.createDirectory(
        at: backupsFolder.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    // Something else in the folder is never touched.
    let other = backupsFolder.appendingPathComponent("keep-me.txt")
    try Data("x".utf8).write(to: other)
    try makeOldLibrary()

    let store = try GRDBDictationStore(databaseURL: databaseURL)
    let newest = try XCTUnwrap(store.migrationBackup?.folder)
    XCTAssertEqual(
      LibraryMigrationBackup.backups(in: backupsFolder).map(\.lastPathComponent),
      [newest.lastPathComponent, "pre-migration-20260201T000000Z"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
  }

  /// Review v12-B #8 (regression): the copy made before the first
  /// Mindloom schema (from the daily app's v18) survives the migrations
  /// that follow — v28, v29, … each prune to the newest two — for 90 days.
  func testThePreMindloomBackupSurvivesLaterMigrations() throws {
    try makeOldLibrary()
    let store = try GRDBDictationStore(databaseURL: databaseURL)
    let first = try XCTUnwrap(store.migrationBackup)
    XCTAssertEqual(first.fromUserVersion, 18)
    let made = try XCTUnwrap(LibraryMigrationBackup.manifest(first.folder))
    XCTAssertEqual(made.fromUserVersion, 18)

    // Three later schema bumps, each with its own backup and prune.
    for (index, version) in [27, 28, 29].enumerated() {
      let at = made.createdAt.addingTimeInterval(Double(index + 1) * 86_400)
      let folder = backupsFolder.appendingPathComponent(
        LibraryMigrationBackup.folderPrefix + LibraryMigrationBackup.folderStamp(at))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let manifest: [String: Any] = [
        "created_at": ISO8601DateFormatter().string(from: at), "from_user_version": version,
      ]
      try JSONSerialization.data(withJSONObject: manifest).write(
        to: folder.appendingPathComponent(LibraryMigrationBackup.manifestName))
      LibraryMigrationBackup.prune(
        backupsFolder, keep: LibraryMigrationBackupPolicy.defaultKeep, now: at)
    }
    let kept = LibraryMigrationBackup.backups(in: backupsFolder)
    XCTAssertEqual(kept.count, 3)
    XCTAssertTrue(kept.contains(first.folder), "the v18 copy is still there")
    // The pruned v27 copy is gone; the newest two stay.
    XCTAssertEqual(
      kept.compactMap { LibraryMigrationBackup.manifest($0)?.fromUserVersion }.sorted(),
      [18, 28, 29])

    // 90 days on, it goes with the next prune like any other.
    LibraryMigrationBackup.prune(
      backupsFolder, keep: LibraryMigrationBackupPolicy.defaultKeep,
      now: made.createdAt.addingTimeInterval(91 * 86_400))
    XCTAssertFalse(LibraryMigrationBackup.backups(in: backupsFolder).contains(first.folder))
  }

  func testDisabledPolicyMakesNoBackup() throws {
    try makeOldLibrary()
    let store = try GRDBDictationStore(databaseURL: databaseURL, migrationBackup: .disabled)
    XCTAssertNil(store.migrationBackup)
    XCTAssertFalse(FileManager.default.fileExists(atPath: backupsFolder.path))
  }

  func testACorruptCloneFailsTheCheck() throws {
    let garbage = library.appendingPathComponent("garbage.sqlite")
    try Data(repeating: 0x5A, count: 8192).write(to: garbage)
    XCTAssertFalse(LibraryMigrationBackup.verify(garbage))
  }
}
